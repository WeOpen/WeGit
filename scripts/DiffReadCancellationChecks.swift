import AppKit
import Foundation

@testable import WeGit

@main struct DiffReadCancellationChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 4,
            CommandLine.arguments.contains("--uitesting")
        else { throw failure("Expected Git, result and Debug build-source paths with isolated test mode") }
        let git = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let buildSource = URL(fileURLWithPath: CommandLine.arguments[3])
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appending(path: "WeGitDiffCancellation-" + UUID().uuidString)
        try manager.createDirectory(
            at: fixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let domain = "com.willxue.wegit.DiffCancellation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            defaults.synchronize()
            try? manager.removeItem(at: fixture)
        }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        func run(_ arguments: [String]) throws -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = git
            process.arguments = ["-C", fixture.path] + arguments
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw failure(String(decoding: bytes, as: UTF8.self))
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        _ = try run(["init", "-b", "main"])
        _ = try run(["config", "user.name", "Cancellation Fixture"])
        _ = try run(["config", "user.email", "cancellation@example.invalid"])
        _ = try run(["config", "commit.gpgsign", "false"])
        _ = try run(["config", "core.hooksPath", fixture.appending(path: "no-hooks").path])
        let file = fixture.appending(path: "selected.txt")
        try Data("a\nb\nc\nd\n".utf8).write(to: file)
        _ = try run(["add", "selected.txt"])
        _ = try run(["commit", "-m", "Base"])
        let work = Data("a\nB\nC\nd\n".utf8)
        try work.write(to: file)
        _ = try run(["add", "selected.txt"])
        let head = try run(["rev-parse", "HEAD"])
        let index = try Data(contentsOf: fixture.appending(path: ".git/index"))
        defaults.setPersistentDomain(
            [
                "gitExecutable": git.path, "language": "zh-Hans", "appearance": "light",
                "interfaceMotion": false, "restoreRepository": false,
            ], forName: domain)
        _ = NSApplication.shared
        let app = AppState(defaultsOverride: defaults)
        await app.open(fixture)
        guard let session = app.session, session.hasLoaded, !session.isStale else {
            throw failure("Private repository did not become readable")
        }
        defer { session.deactivate() }
        app.workspace.selectedFile = "staged|selected.txt"
        var preserved = 0
        var recovered = 0
        var failures: [String] = []
        for iteration in 0..<32 {
            await app.loadDiff()
            guard let display = app.workspace.diffDisplay else {
                failures.append("No initial Diff in iteration \(iteration)")
                break
            }
            app.workspace.diffOptions.ignoreWhitespace.toggle()
            var enteredCancelled = false
            let cancelled = Task { @MainActor in
                await Task.yield()
                enteredCancelled = Task.isCancelled
                await app.loadDiff()
            }
            cancelled.cancel()
            await cancelled.value
            guard enteredCancelled, app.workspace.diffDisplay === display,
                app.workspace.diff?.path == "selected.txt",
                app.workspace.selectedFile == "staged|selected.txt"
            else {
                failures.append("A cancelled caller changed the current Diff in iteration \(iteration)")
                break
            }
            preserved += 1
            await app.loadDiff()
            guard app.workspace.diff?.options == app.workspace.diffOptions,
                app.workspace.diffDisplay != nil, !app.workspace.loadingDiff
            else {
                failures.append("Following read did not recover in iteration \(iteration)")
                break
            }
            recovered += 1
        }
        let intact =
            try run(["rev-parse", "HEAD"]) == head
            && Data(contentsOf: fixture.appending(path: ".git/index")) == index
            && Data(contentsOf: file) == work
            && !manager.fileExists(atPath: fixture.appending(path: ".git/index.lock").path)
        if !intact { failures.append("A read changed the private HEAD, index or working bytes") }
        let source = try JSONSerialization.jsonObject(with: Data(contentsOf: buildSource))
        let passed = failures.isEmpty && preserved == 32 && recovered == 32
        let report: [String: Any] = [
            "allPassed": passed, "cancelledCallerPreservationChecks": preserved,
            "followingFreshReadChecks": recovered, "fixtureIntegrityPassed": intact,
            "failures": failures, "buildSource": source, "configuration": "actual Debug AppState model",
            "nativeUIAcceptance": false, "xctestExecuted": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .atomic)
        guard passed else { throw failure(failures.joined(separator: "\n")) }
        print(
            "PASS actual AppState cancelled-call preservation and following reads (32 + 32 checks; private fixture intact; no XCTest)"
        )
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "WeGit.DiffReadCancellation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
