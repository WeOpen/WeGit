import AppKit
import CryptoKit
import Foundation
import WeGitCore

@testable import WeGit

@main struct HistoryReadingChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 3, CommandLine.arguments.contains("--uitesting") else {
            throw failure("Expected private result path and isolated test mode")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let manager = FileManager.default
        let root = output.deletingLastPathComponent().appending(path: "repository")
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        let domain = "com.willxue.wegit.UITests.HistoryReading." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let engine = GitEngine(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: environment)
        @discardableResult func git(_ arguments: [String]) async throws -> String {
            try await engine.run(arguments, in: root).text.trimmingCharacters(in: .newlines)
        }
        try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "History Reading"), ("user.email", "history@example.invalid"),
            ("core.hooksPath", root.appending(path: "no-hooks").path), ("commit.gpgsign", "false"),
        ] { try await git(["config", key, value]) }
        let file = root.appending(path: "tracked.txt")
        try Data("original\r\nlast".utf8).write(to: file)
        try await git(["add", "."])
        try await git(["commit", "-m", "Original"])
        let original = try await git(["rev-parse", "HEAD"])
        try Data("later\r\nlast".utf8).write(to: file)
        try await git(["commit", "-am", "Later"])
        let latest = try await git(["rev-parse", "HEAD"])
        let index = try Data(contentsOf: root.appending(path: ".git/index"))
        let work = try Data(contentsOf: file)
        defaults.setPersistentDomain(
            [
                "restoreRepository": false, "restoreWindow": true, "gitExecutable": "/usr/bin/git",
                "language": "zh-Hans", "interfaceMotion": false,
            ], forName: domain)
        _ = NSApplication.shared
        var checks: [String] = []
        var states: [AppState] = []
        func require(_ valid: Bool, _ message: String) throws {
            guard valid else { throw failure(message) }
            checks.append(message)
        }
        func opened() async throws -> AppState {
            let app = AppState(defaultsOverride: defaults)
            states.append(app)
            await app.restore()
            app.mainWorkspaceMounted = true
            await app.open(root)
            guard let session = app.session, app.error == nil, session.hasLoaded else {
                throw failure("Private repository did not open")
            }
            await app.historyState(for: session).synchronize()
            return app
        }
        let first = try await opened()
        let firstSession = first.session!
        first.workspace.route = .history
        try require(first.saveCurrentWorkspace(), "Initial history route persisted")
        first.applyHistorySelection([original], for: firstSession)
        try require(
            first.workspace.selectedCommit?.id == original, "Explicit table input selected original object")
        try require(
            first.runtime.persistence?.snapshot(first.windowID)?.selectedCommit == original,
            "Explicit selection persisted before any quit or close callback")
        first.session?.deactivate(owner: first.windowID)
        let reopened = try await opened()
        try require(
            reopened.windowID == first.windowID && reopened.workspace.route == .history,
            "Second AppState restores same private window and route")
        await reopened.restoreSelectedCommit(for: reopened.session!)
        try require(
            reopened.workspace.selectedCommit?.id == original,
            "Second AppState restores the exact original commit")
        try require(
            reopened.historyState(for: reopened.session!).selectedIDs == [original],
            "Multiple-selection state restores alongside exact detail object")
        reopened.session?.deactivate(owner: reopened.windowID)
        let intervened = try await opened()
        intervened.applyHistorySelection([latest], for: intervened.session!)
        await intervened.restoreSelectedCommit(for: intervened.session!)
        try require(
            intervened.workspace.selectedCommit?.id == latest
                && intervened.runtime.persistence?.snapshot(intervened.windowID)?.selectedCommit == latest,
            "Explicit newer selection cancels older pending restoration")
        intervened.applyHistorySelection([], for: intervened.session!)
        await intervened.restoreSelectedCommit(for: intervened.session!)
        try require(
            intervened.workspace.selectedCommit == nil
                && intervened.runtime.persistence?.snapshot(intervened.windowID)?.selectedCommit == nil,
            "Explicit clear persists and never revives an older pending object")
        intervened.session?.deactivate(owner: intervened.windowID)
        let cleared = try await opened()
        await cleared.restoreSelectedCommit(for: cleared.session!)
        try require(
            cleared.workspace.selectedCommit == nil
                && cleared.historyState(for: cleared.session!).selectedIDs.isEmpty,
            "Another private reopen preserves the cleared selection")
        cleared.applyHistorySelection([original], for: firstSession)
        try require(
            cleared.workspace.selectedCommit == nil, "Stale session selection cannot alter current window")
        for state in states { state.session?.deactivate(owner: state.windowID) }
        try require(
            try await git(["rev-parse", "HEAD"]) == latest
                && Data(contentsOf: root.appending(path: ".git/index")) == index
                && Data(contentsOf: file) == work, "Original HEAD, index and work bytes remain unchanged")
        let result: [String: Any] = [
            "format": 1, "allPassed": true, "checks": checks, "count": checks.count,
            "xctestExecuted": false, "uiAcceptance": false,
            "scope":
                "Actual AppState instances with private defaults and repository; no normal-exit save callback",
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(
            to: output)
        print("\(checks.count) actual history reading controls passed")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "WeGit.HistoryReadingChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
