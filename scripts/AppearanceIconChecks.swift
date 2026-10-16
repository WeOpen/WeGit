import AppKit
import Foundation

@main
struct AppearanceIconChecks {
    @MainActor
    static func main() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let originalAppearance = application.appearance
        let suite = "com.willxue.wegit.AppearanceChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let report = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks: [String] = []
        var samples: [[String: Any]] = []
        defer {
            application.appearance = originalAppearance
            application.applicationIconImage = nil
            defaults.removePersistentDomain(forName: suite)
            defaults.synchronize()
        }

        func record(_ passed: Bool, _ name: String) throws {
            guard passed else {
                let result: [String: Any] = [
                    "passed": false, "failedCheck": name, "checks": checks, "samples": samples,
                ]
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: report)
                throw NSError(
                    domain: "WeGit.AppearanceChecks", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: name])
            }
            checks.append(name)
        }

        func isDark(_ image: NSImage?, label: String) throws -> Bool {
            guard let image,
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                let color = NSBitmapImageRep(cgImage: cgImage)
                    .colorAt(x: cgImage.width / 2, y: cgImage.height / 5)?
                    .usingColorSpace(.sRGB)
            else { throw NSError(domain: "WeGit.AppearanceChecks", code: 2) }
            let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
            samples.append(["label": label, "rgb": rgb])
            return color.blueComponent < 0.3
        }

        func waitForSystem(_ preferences: AppPreferences, dark: Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while preferences.systemUsesDarkAppearance != dark && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try record(
                preferences.systemUsesDarkAppearance == dark,
                "System appearance observation reaches " + (dark ? "Dark" : "Light"))
        }

        func checkDockCanvas(_ image: NSImage?, label: String) throws {
            let cgImage = image!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let width = bitmap.pixelsWide
            let height = bitmap.pixelsHigh
            let xs = (0..<width).filter {
                bitmap.colorAt(x: $0, y: height / 2)!.alphaComponent > 0.5
            }
            let ys = (0..<height).filter {
                bitmap.colorAt(x: width / 2, y: $0)!.alphaComponent > 0.5
            }
            let horizontal = Double(xs.last! - xs.first! + 1) / Double(width)
            let vertical = Double(ys.last! - ys.first! + 1) / Double(height)
            samples.append([
                "label": label + "-canvas", "horizontalExtent": horizontal, "verticalExtent": vertical,
            ])
            try record(
                (0.79...0.82).contains(horizontal) && (0.79...0.82).contains(vertical),
                label + " Dock artwork has the macOS static canvas inset")
        }

        do {
            application.appearance = NSAppearance(named: .aqua)
            application.applicationIconImage = NSImage(
                contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "icns")!)
            defaults.set("dark", forKey: "appearance")
            let preferences = AppPreferences(defaults: defaults)
            preferences.observeSystemAppearance()
            try record(
                try isDark(application.applicationIconImage, label: "restored-dark"),
                "Restored Dark selects the graphite Dock icon")
            try checkDockCanvas(application.applicationIconImage, label: "Dark")

            preferences.appearance = "light"
            try record(
                try !isDark(application.applicationIconImage, label: "explicit-light"),
                "Light switches the running Dock icon to cobalt")
            try checkDockCanvas(application.applicationIconImage, label: "Light")
            preferences.appearance = "dark"
            try record(
                try isDark(application.applicationIconImage, label: "explicit-dark"),
                "Dark switches the running Dock icon without rebuilding a window")
            try record(application.windows.isEmpty, "Theme updates work with no application windows")

            let darkAlert = NSAlert()
            AppPresentation.configure(darkAlert, appearance: AppPresentation.appearance(for: "dark"))
            try record(
                try isDark(darkAlert.icon, label: "dark-alert"),
                "Dark native panels use the same graphite artwork")
            let lightAlert = NSAlert()
            AppPresentation.configure(lightAlert, appearance: AppPresentation.appearance(for: "light"))
            try record(
                try !isDark(lightAlert.icon, label: "light-alert"),
                "Light native panels use the cobalt artwork")

            preferences.appearance = "system"
            try record(
                try !isDark(application.applicationIconImage, label: "system-light"),
                "Returning to System follows the current Light appearance")
            application.appearance = NSAppearance(named: .darkAqua)
            try await waitForSystem(preferences, dark: true)
            try record(
                try isDark(application.applicationIconImage, label: "system-dark"),
                "System Dark updates the Dock icon through the existing observer")
            application.appearance = NSAppearance(named: .aqua)
            try await waitForSystem(preferences, dark: false)
            try record(
                try !isDark(application.applicationIconImage, label: "system-light-again"),
                "System Light restores cobalt in the same process")

            preferences.appearance = "dark"
            try record(
                try isDark(application.applicationIconImage, label: "dark-over-light-system"),
                "Explicit Dark wins over a Light system appearance")
            application.appearance = NSAppearance(named: .darkAqua)
            try await waitForSystem(preferences, dark: true)
            preferences.appearance = "light"
            try record(
                try !isDark(application.applicationIconImage, label: "light-over-dark-system"),
                "Explicit Light wins over a Dark system appearance")
            preferences.resetInterface()
            try record(preferences.appearance == "system", "Reset returns the icon policy to System")
            try record(
                try isDark(application.applicationIconImage, label: "reset-to-system-dark"),
                "Reset immediately selects the current system artwork")

            let result: [String: Any] = [
                "passed": true, "checks": checks, "samples": samples,
                "scope":
                    "Actual AppKit applicationIconImage pixels and preference lifecycle; system appearance changes are process-local",
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: report)
            print("\(checks.count) native appearance icon checks passed.")
        } catch {
            fputs("Appearance icon check failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
