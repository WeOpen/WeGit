import AppKit
import CryptoKit
import Foundation
import WeGitCore

@testable import WeGit

@main struct ThemeImportQueueChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 4, CommandLine.arguments.contains("--uitesting") else {
            throw failure("Expected Git, result and build-source paths with isolated test mode")
        }
        let git = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let source = URL(fileURLWithPath: CommandLine.arguments[3])
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "WeGitThemeQueue-" + UUID().uuidString)
        try manager.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let domain = "com.willxue.wegit.UITests.ThemeQueue." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        var successful = false
        defer {
            defaults.removePersistentDomain(forName: domain)
            defaults.synchronize()
            if successful { try? manager.removeItem(at: root) }
        }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        func run(_ arguments: [String]) throws -> Data {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = git
            process.arguments = ["-C", root.path] + arguments
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw failure(String(decoding: bytes, as: UTF8.self))
            }
            return bytes
        }
        _ = try run(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Theme Queue Fixture"), ("user.email", "queue@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", root.appending(path: "no-hooks").path),
        ] { _ = try run(["config", key, value]) }
        let file = root.appending(path: "selected.txt")
        try Data("original\r\nno-final-newline".utf8).write(to: file)
        _ = try run(["add", "selected.txt"])
        _ = try run(["commit", "-m", "Theme queue base"])
        try Data("stash contents\n".utf8).write(to: file)
        _ = try run(["stash", "push", "-m", "Queue fixture"])
        let work = Data("staged\r\nprivate draft bytes".utf8)
        try work.write(to: file)
        _ = try run(["add", "selected.txt"])
        defaults.setPersistentDomain(
            [
                "gitExecutable": git.path, "restoreRepository": false, "appearance": "light",
                "language": "zh-Hans", "interfaceMotion": false,
            ], forName: domain)
        _ = NSApplication.shared
        let app = AppState(defaultsOverride: defaults)
        let peer = AppState(sharedWith: app)
        await app.restore()
        await peer.restore()
        app.mainWorkspaceMounted = true
        peer.mainWorkspaceMounted = true
        await app.open(root)
        await peer.open(root)
        guard let session = app.session, peer.session === session, session.hasLoaded, !session.isStale else {
            throw failure("Two private windows did not share the actual repository session")
        }
        defer {
            session.deactivate(owner: app.windowID)
            session.deactivate(owner: peer.windowID)
        }
        let draft = "保留两个窗口的草稿 🧭\nsecond line"
        try require(
            session.editDraft(draft, owner: app.windowID, revision: session.draftRevision),
            "Could not initialize the owned private draft")
        let revision = session.draftRevision
        let head = try run(["rev-parse", "HEAD"])
        let index = try Data(contentsOf: root.appending(path: ".git/index"))
        let themes = defaults.data(forKey: CustomThemeLibrary.key)
        let commits = try await session.service.history(limit: 1)
        let stashes = try await session.service.stashes()
        guard let commit = commits.first, let stash = stashes.entries.first else {
            throw failure("Real commit and stash fixtures are missing")
        }
        let signature = SignatureRequest(
            session: session, objectID: commit.id, object: .commit, title: commit.subject)
        let modification = FileModificationRequest(
            session: session,
            source: .history(revision: commit.id, sourcePath: "selected.txt", destinationPath: "selected.txt")
        )
        var checks: [String] = []
        var failureText: String?
        do {
            try require(
                app.canPresentThemeImport && peer.canPresentThemeImport, "Initial windows are blocked")
            let blockers: [(String, @MainActor () -> Void, @MainActor () -> Void)] = [
                (
                    "repository initialization", { app.initializationPresented = true },
                    { app.initializationPresented = false }
                ),
                (
                    "commit queue",
                    {
                        app.commitQueueRequest = .init(
                            session: session, operation: .cherryPick, commits: [commit])
                    }, { app.commitQueueRequest = nil }
                ),
                (
                    "task switch", { app.taskSwitchRequest = .init(session: session) },
                    { app.taskSwitchRequest = nil }
                ),
                (
                    "stash branch",
                    { app.stashBranchRequest = .init(session: session, entry: stash, list: stashes) },
                    { app.stashBranchRequest = nil }
                ),
                ("signature", { app.signatureRequest = signature }, { app.signatureRequest = nil }),
                (
                    "commit message",
                    { app.commitMessageRequest = .init(session: session, source: .history) },
                    { app.commitMessageRequest = nil }
                ),
                (
                    "file modification", { app.fileModificationRequest = modification },
                    { app.fileModificationRequest = nil }
                ),
                (
                    "ignore rule", { app.ignoreRuleRequest = .init(session: session, path: "selected.txt") },
                    { app.ignoreRuleRequest = nil }
                ),
                (
                    "file patch",
                    {
                        app.patchImportRequest = .init(
                            session: session, sourceName: "fixture.patch", patch: Data())
                    }, { app.patchImportRequest = nil }
                ),
                (
                    "mail patch", { app.mailPatchRequest = .init(session: session, sources: []) },
                    { app.mailPatchRequest = nil }
                ),
                (
                    "reference comparison", { app.referenceComparisonRequest = .init(session: session) },
                    { app.referenceComparisonRequest = nil }
                ),
                (
                    "history depth", { app.historyDepthRequest = .init(session: session) },
                    { app.historyDepthRequest = nil }
                ),
            ]
            for (name, enter, leave) in blockers {
                enter()
                let url = try themeURL(name)
                let id = try ThemeImportPayload.parse(url).id
                app.receiveThemeURL(url)
                peer.drainThemeImports()
                try require(
                    app.themeImportRequest == nil && peer.themeImportRequest == nil
                        && app.runtime.pendingThemeImports.count == 1 && !app.canPresentThemeImport,
                    "External theme interrupted " + name)
                leave()
                app.workspaceSheetDidDismiss()
                try require(
                    app.themeImportRequest == nil, "Dismissal continuation ran synchronously: " + name)
                await settle()
                try require(
                    app.themeImportRequest?.id == id, "Dismissed sheet did not deliver theme: " + name)
                app.themeImportRequest = nil
                app.workspaceSheetDidDismiss()
                await settle()
                checks.append("queue waits for " + name)
            }

            app.patchImportRequest = .init(session: session, sourceName: "fixture.patch", patch: Data())
            app.pendingRecoveryAfterPatch = .init(session: session)
            app.receiveThemeURL(try themeURL("follow-up recovery"))
            app.patchImportRequest = nil
            app.workspaceSheetDidDismiss(app.patchImportDidDismiss)
            await settle()
            try require(
                app.recoveryBrowserRequest != nil && app.themeImportRequest == nil
                    && app.runtime.pendingThemeImports.count == 1,
                "Theme displaced the repository recovery continuation")
            app.recoveryBrowserRequest = nil
            app.workspaceSheetDidDismiss()
            await settle()
            try require(app.themeImportRequest != nil, "Recovery dismissal did not resume the queue")
            app.themeImportRequest = nil
            checks.append("repository follow-up keeps priority")

            app.referenceComparisonRequest = .init(session: session)
            app.receiveThemeURL(try themeURL("reader follow-up"))
            app.restoreFileAfterReader(modification)
            try require(!app.canPresentThemeImport, "Reader transition released its pending slot")
            app.workspaceSheetDidDismiss(app.fileReaderDidDismiss)
            await settle()
            try require(
                app.fileModificationRequest != nil && app.themeImportRequest == nil,
                "Reader follow-up was replaced")
            app.fileModificationRequest = nil
            app.workspaceSheetDidDismiss()
            await settle()
            try require(app.themeImportRequest != nil, "Reader follow-up did not resume the queue")
            app.themeImportRequest = nil
            checks.append("reader follow-up keeps priority")

            let sharedURL = try themeURL("shared duplicate")
            app.initializationPresented = true
            app.receiveThemeURL(sharedURL)
            peer.receiveThemeURL(sharedURL)
            try require(
                app.runtime.pendingThemeImports.count == 1,
                "Queued requests were not deduplicated across windows")
            app.initializationPresented = false
            app.workspaceSheetDidDismiss()
            await settle()
            peer.receiveThemeURL(sharedURL)
            try require(
                app.themeImportRequest != nil && peer.themeImportRequest == nil
                    && app.runtime.pendingThemeImports.isEmpty,
                "Presented request was duplicated across windows")
            peer.receiveThemeURL(try themeURL("second distinct request"))
            try require(
                app.runtime.pendingThemeImports.count == 1 && peer.themeImportRequest == nil,
                "Two windows presented themes simultaneously")
            app.themeImportRequest = nil
            app.workspaceSheetDidDismiss()
            await settle()
            try require(
                peer.themeImportRequest != nil && app.themeImportRequest == nil,
                "Distinct request lost its target window")
            peer.themeImportRequest = nil
            checks.append("shared deduplication and single presentation")

            app.initializationPresented = true
            app.receiveThemeURL(try themeURL("closed target fallback"))
            try require(app.windowDidClose(), "Private target window could not close")
            app.runtime.activeWindowID = peer.windowID
            app.drainThemeImports()
            try require(
                peer.themeImportRequest != nil && app.runtime.pendingThemeImports.isEmpty,
                "Closed target stranded its queued request")
            peer.themeImportRequest = nil
            app.initializationPresented = false
            app.mainWorkspaceMounted = true
            session.activate(owner: app.windowID)
            checks.append("closed target falls back to mounted window")

            app.receiveThemeURL(try themeURL("closing presented theme"))
            peer.receiveThemeURL(try themeURL("next after close"))
            try require(
                app.themeImportRequest != nil && peer.themeImportRequest == nil,
                "Close fixture did not own the first theme")
            try require(app.windowDidClose(), "Presented theme window could not close")
            await settle()
            try require(
                app.themeImportRequest == nil && peer.themeImportRequest?.theme.name == "next after close",
                "Closed presented theme blocked the shared queue")
            peer.themeImportRequest = nil
            app.mainWorkspaceMounted = true
            session.activate(owner: app.windowID)
            checks.append("closing presented theme releases the shared slot")

            app.runtime.updateHandoffInProgress = true
            peer.receiveThemeURL(try themeURL("update freeze"))
            try require(
                peer.themeImportRequest == nil && app.runtime.pendingThemeImports.count == 1,
                "Update handoff accepted a theme sheet")
            app.runtime.updateHandoffInProgress = false
            peer.workspaceSheetDidDismiss()
            await settle()
            try require(peer.themeImportRequest != nil, "Unfrozen update did not resume the queue")
            peer.themeImportRequest = nil
            checks.append("update handoff freezes and resumes presentation")

            peer.migrationRestartRequired = true
            peer.receiveThemeURL(try themeURL("migration freeze"))
            try require(
                peer.themeImportRequest == nil && app.runtime.pendingThemeImports.count == 1,
                "Blocked migration accepted a theme sheet")
            peer.migrationRestartRequired = false
            peer.workspaceSheetDidDismiss()
            await settle()
            try require(peer.themeImportRequest != nil, "Migration resume did not deliver the queued theme")
            peer.themeImportRequest = nil
            checks.append("migration block keeps request queued")

            app.initializationPresented = true
            for number in 0..<8 { app.receiveThemeURL(try themeURL("capacity-\(number)")) }
            peer.receiveThemeURL(try themeURL("overflow"))
            try require(
                app.runtime.pendingThemeImports.count == 8 && peer.error != nil,
                "Shared queue did not enforce eight pending requests")
            peer.error = nil
            app.initializationPresented = false
            var presented: [String] = []
            for _ in 0..<8 {
                app.workspaceSheetDidDismiss()
                await settle()
                guard let payload = app.themeImportRequest else {
                    throw failure("Capacity queue lost a request")
                }
                presented.append(payload.theme.name)
                app.themeImportRequest = nil
            }
            try require(
                presented == (0..<8).map { "capacity-\($0)" } && app.runtime.pendingThemeImports.isEmpty,
                "Queue order or bounded request set changed")
            checks.append("eight-request global bound and FIFO")
        } catch { failureText = error.localizedDescription }

        let intact =
            try run(["rev-parse", "HEAD"]) == head
            && Data(contentsOf: root.appending(path: ".git/index")) == index
            && Data(contentsOf: file) == work
            && session.message == draft && session.draftRevision == revision
            && defaults.data(forKey: CustomThemeLibrary.key) == themes
            && !manager.fileExists(atPath: root.appending(path: ".git/index.lock").path)
        if !intact {
            failureText = (failureText.map { $0 + "; " } ?? "") + "Fixture/draft/theme state changed"
        }
        successful = failureText == nil && checks.count == 20
        let report: [String: Any] = [
            "allPassed": successful, "checks": checks, "passedChecks": checks.count, "expectedChecks": 20,
            "fixtureIntegrityPassed": intact, "failure": failureText as Any? ?? NSNull(),
            "configuration": "actual Debug AppState, shared runtime and private Git fixture",
            "xctestExecuted": false, "nativeUIAcceptance": false,
            "buildSource": try JSONSerialization.jsonObject(with: Data(contentsOf: source)),
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output, options: .atomic)
        guard successful else { throw failure(failureText ?? "Incomplete control count") }
        print(
            "PASS 20 actual AppState theme queue controls; private HEAD/index/draft/theme preserved; no XCTest"
        )
    }

    @MainActor private static func settle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func themeURL(_ name: String) throws -> URL {
        var theme = CustomTheme.starter
        theme.name = name
        let data = try theme.normalizedData()
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "wegit://theme/import?v=1&data=" + encoded + "&sha256=" + checksum)!
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "WeGit.ThemeImportQueue", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
