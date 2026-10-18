import CoreGraphics
import Darwin
import Foundation

/// Holds a temporary display mode only while the hosted diagnostic command runs.
/// CGDisplaySetDisplayMode also reverts the mode when this process terminates.
@main struct DisplaySession {
    static func mode(_ value: CGDisplayMode) -> [String: Int] {
        [
            "width": value.width, "height": value.height,
            "pixelWidth": value.pixelWidth, "pixelHeight": value.pixelHeight,
        ]
    }

    static func main() {
        do { exit(try run()) } catch {
            fputs("Display session failed: \(String(reflecting: type(of: error)))\n", stderr)
            exit(1)
        }
    }

    static func run() throws -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let separator = arguments.firstIndex(of: "--")
        let options = Array(arguments.prefix(separator ?? arguments.count))
        let inspect = options.first == "--inspect"
        let flags = inspect ? Array(options.dropFirst()) : options
        guard flags.count == 2, flags.first == "--report",
            inspect ? separator == nil : separator.map({ $0 + 1 < arguments.count }) == true
        else {
            fputs("Usage: display-session [--inspect] --report path [-- command arguments]\n", stderr)
            return 2
        }
        let destination = URL(fileURLWithPath: flags[1])
        let environment = ProcessInfo.processInfo.environment
        let hosted =
            environment["GITHUB_ACTIONS"] == "true" && environment["RUNNER_ENVIRONMENT"] == "github-hosted"
        var report: [String: Any] = [
            "readOnly": inspect, "githubHosted": hosted, "displayChanged": false,
            "osPermissionsChanged": false, "temporaryForProcessLifetime": true,
        ]
        func save() throws {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination, options: .atomic)
        }
        guard inspect || hosted else {
            report["result"] = "refused-outside-github-hosted"
            try save()
            fputs("Display mutation is restricted to a GitHub-hosted diagnostic VM.\n", stderr)
            return 2
        }
        let display = CGMainDisplayID()
        guard let original = CGDisplayCopyDisplayMode(display) else {
            report["result"] = "no-main-display"
            try save()
            return 1
        }
        let modes =
            CGDisplayCopyAllDisplayModes(
                display, [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary)
            as? [CGDisplayMode] ?? []
        report["originalMode"] = mode(original)
        report["availableModes"] = modes.map(mode)
        if inspect {
            report["result"] = "inspected"
            try save()
            return 0
        }
        guard let separator else { return 2 }
        guard let selected = modes.first(where: { $0.width == 1920 && $0.height == 1080 }) else {
            report["result"] = "required-1920x1080-mode-unavailable"
            try save()
            return 1
        }
        report["selectedMode"] = mode(selected)
        try save()
        var restoreRequired = false
        func restore() -> Bool {
            restoreRequired = false
            let error = CGDisplaySetDisplayMode(display, original, nil)
            let restored = CGDisplayCopyDisplayMode(display).map(mode) ?? [:]
            report["restoreError"] = Int(error.rawValue)
            report["restoredMode"] = restored
            let matched = error == .success && restored == mode(original)
            report["restored"] = matched
            return matched
        }
        defer {
            if restoreRequired { _ = restore() }
            try? save()
        }
        restoreRequired = true
        let error = CGDisplaySetDisplayMode(display, selected, nil)
        report["setError"] = Int(error.rawValue)
        let effective = CGDisplayCopyDisplayMode(display).map(mode) ?? [:]
        report["effectiveMode"] = effective
        report["displayChanged"] = effective != mode(original)
        guard error == .success, effective == mode(selected) else {
            report["result"] = "mode-change-failed"
            return 1
        }
        try save()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = Array(arguments.dropFirst(separator + 1))
        try child.run()
        child.waitUntilExit()
        let status =
            child.terminationReason == .exit ? child.terminationStatus : 128 + child.terminationStatus
        report["childExitCode"] = status
        let restored = restore()
        report["result"] = status == 0 && restored ? "passed-and-restored" : "failed"
        try save()
        return status != 0 ? status : (restored ? 0 : 1)
    }
}
