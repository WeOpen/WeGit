import CoreServices
import Foundation
import WeGitCore

private actor WorktreeEvents {
    var scope: RepositoryRefreshScope = []
    func add(_ value: RepositoryRefreshScope) { scope.formUnion(value) }
    func reset() { scope = [] }
}

private actor WorktreeGate {
    var entered = false
    func enter() { entered = true }
}

private func withinTwoSeconds<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws
    -> T
{
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw NSError(
                domain: "WeGit.WorktreeChecks", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "A sibling's shared operation blocked local work"])
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@main struct WorktreeChecks {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("Worktree check failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var checks: [String] = []
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else {
                throw NSError(
                    domain: "WeGit.WorktreeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
            }
            checks.append(name)
            print("PASS: " + name)
        }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitWorktreeChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appending(path: "main")
        let first = root.appending(path: "工作区\none")
        let second = root.appending(path: "detached")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        let engine = GitEngine(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: env)
        @discardableResult func git(_ args: [String], at directory: URL? = nil) async throws -> Data {
            try await engine.run(args, in: directory ?? main).stdout
        }
        func open(_ url: URL) async throws -> RepositoryService {
            print("Opening fixture: " + url.lastPathComponent.debugDescription)
            return try await RepositoryService(
                location: RepositoryService.discover(url, engine: engine), engine: engine)
        }
        try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Worktree Fixture"), ("user.email", "worktree@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", root.appending(path: "no-hooks").path),
        ] {
            try await git(["config", key, value])
        }
        try Data("base\n".utf8).write(to: main.appending(path: "file.txt"))
        try await git(["add", "."])
        try await git(["commit", "-m", "Base"])
        try await git(["worktree", "add", "-b", "topic", first.path])
        try await git(["worktree", "add", "--detach", second.path])
        let primary = try await open(main)
        let a = try await open(first)
        let b = try await open(second)
        let initial = try await primary.head()
        try check(
            "Linked and detached worktrees open with independent identities",
            a.location.isLinkedWorktree && b.location.isLinkedWorktree
                && Set([primary.location.persistenceID, a.location.persistenceID, b.location.persistenceID])
                    .count == 3
        )
        try check(
            "All worktrees share common-directory coordination",
            primary.sharedQueue === a.sharedQueue && a.sharedQueue === b.sharedQueue)
        try check(
            "Each worktree has an independent local queue", primary.queue !== a.queue && a.queue !== b.queue)
        let statusA = try await a.status()
        let statusB = try await b.status()
        try check(
            "Branch and detached HEAD reflect their own worktree",
            statusA.branch == "topic" && statusB.isDetached)
        let alias = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let aliased = try await open(alias)
        try check(
            "Alias reuses identity and queue", aliased.location == a.location && aliased.queue === a.queue)

        let gate = WorktreeGate()
        let owner = Task {
            try await primary.sharedQueue.perform {
                await gate.enter()
                try await Task.sleep(for: .seconds(30))
            }
        }
        defer { owner.cancel() }
        while !(await gate.entered) { await Task.yield() }
        try Data("first\n".utf8).write(to: first.appending(path: "file.txt"))
        let independent = try await withinTwoSeconds {
            try await a.stage(paths: ["file.txt"], expectedHead: initial)
            return try await b.readSnapshot()
        }
        try check(
            "Sibling shared operation permits independent stage and first snapshot",
            independent.status.isDetached && independent.status.head == initial)
        let waiting = Task {
            try await a.commit(message: "Must not commit", amend: false, expectedHead: initial)
        }
        try await Task.sleep(for: .milliseconds(80))
        try check(
            "Another worktree cannot commit during shared ownership",
            try await a.head() == initial)
        waiting.cancel()
        do {
            try await waiting.value
            try check("Queued cancellation must throw", false)
        } catch is CancellationError {}
        owner.cancel()
        do { try await owner.value } catch is CancellationError {}
        try check(
            "Cancelled shared write preserves the staged index",
            try await git(["show", ":file.txt"], at: first) == Data("first\n".utf8))
        try Data("second\n".utf8).write(to: second.appending(path: "file.txt"))
        async let stageA: Void = a.stage(paths: ["file.txt"], expectedHead: initial)
        async let stageB: Void = b.stage(paths: ["file.txt"], expectedHead: initial)
        _ = try await (stageA, stageB)
        let indexA = try await git(["show", ":file.txt"], at: first)
        let indexB = try await git(["show", ":file.txt"], at: second)
        let indexMain = try await git(["show", ":file.txt"])
        try check(
            "Concurrent staging targets each independent index",
            indexA == Data("first\n".utf8) && indexB == Data("second\n".utf8)
                && indexMain == Data("base\n".utf8))
        let committed = try await a.commit(message: "Topic only", amend: false, expectedHead: initial)
        let headMain = try await primary.head()
        let headB = try await b.head()
        let headA = try await a.head()
        try check(
            "Commit advances only the current worktree",
            headMain == initial && headB == initial && headA == committed)
        try check(
            "Commit preserves other worktree files and staged bytes",
            try Data(contentsOf: second.appending(path: "file.txt")) == Data("second\n".utf8)
                && Data(contentsOf: main.appending(path: "file.txt")) == Data("base\n".utf8))

        let remote = root.appending(path: "remote.git")
        try await git(["init", "--bare", remote.path])
        try await a.changeRemote(
            .add(name: "origin", fetchURL: remote.path, pushURL: nil), in: a.remoteManagement(),
            expectedHead: committed)
        try check(
            "Remote writes from linked worktree reach shared config",
            try await primary.remoteManagement().remotes.contains { $0.name == "origin" && $0.canEdit })
        try check(
            "Shared config lease is released",
            !FileManager.default.fileExists(
                atPath: primary.location.commonDirectory.appending(path: "config.lock").path))
        try await git(["config", "extensions.worktreeConfig", "true"])
        try await git(["config", "--worktree", "user.name", "Only Topic"], at: first)
        let settings = GitConfigurationService(engine: engine, location: a.location)
        let current = try await settings.read(.userName)
        try check(
            "Worktree-specific config retains its effective source",
            current.effective?.scope == "worktree" && current.effective?.value == "Only Topic")
        let updated = try await settings.set("Shared Name", scope: .local, expected: current)
        try check(
            "Shared config edit preserves worktree override",
            updated.effective?.value == "Only Topic" && updated.localValues == ["Shared Name"])
        try await git(["config", "--worktree", "remote.private.url", remote.path], at: first)
        try check(
            "Worktree Remote configuration is visible and protected",
            try await a.remoteManagement().remotes.contains {
                $0.name == "private" && !$0.canEdit && !$0.canDelete
            })
        let push = try await a.preparePush(
            remote: "origin", branch: "topic", setUpstream: true, expectedHead: committed)
        _ = try await a.push(push)
        try check(
            "Linked worktree push uses its own branch",
            try await git(["rev-parse", "refs/heads/topic"], at: remote) == Data((committed + "\n").utf8))

        func scope(_ path: String, for service: RepositoryService = a) -> RepositoryRefreshScope {
            RepositoryRefreshScope.events(paths: [path], flags: [0], location: service.location)
        }
        let common = primary.location.commonDirectory.path
        try check(
            "Private index events refresh only the owning worktree",
            scope(a.location.gitDirectory.path + "/index") == [.status, .diff]
                && scope(b.location.gitDirectory.path + "/index").isEmpty && scope(common + "/index").isEmpty)
        try check(
            "Sibling HEAD events refresh branch occupancy only",
            scope(b.location.gitDirectory.path + "/HEAD") == .references
                && scope(common + "/HEAD") == .references)
        try check(
            "Main worktree ignores sibling index and sequence events",
            scope(a.location.gitDirectory.path + "/index", for: primary).isEmpty
                && scope(a.location.gitDirectory.path + "/sequencer/todo", for: primary).isEmpty)
        try check(
            "Shared refs and stash reflog retain refresh scopes",
            scope(common + "/refs/tags/shared") == [.status, .references, .history, .diff]
                && scope(common + "/logs/refs/stash") == .status)
        try check(
            "Only local worktree configuration triggers full refresh",
            scope(a.location.gitDirectory.path + "/config.worktree") == .all
                && scope(b.location.gitDirectory.path + "/config.worktree").isEmpty)
        try check(
            "Own sequencer events retain recovery refresh",
            scope(a.location.gitDirectory.path + "/sequencer/todo") == [
                .status, .references, .history, .diff,
            ])
        let events = WorktreeEvents()
        let watcher = try RepositoryWatcher(location: a.location) { value in Task { await events.add(value) }
        }
        defer { watcher.stop() }
        try await git(["tag", "shared-tag"])
        for _ in 0..<100 {
            if await events.scope.contains(.references) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try check("Actual FSEvents delivers shared tag updates", await events.scope.contains(.references))
        try check(
            "Shared tag is readable from linked worktree",
            try await a.tags().entries.contains { $0.name == "shared-tag" })
        try await Task.sleep(for: .milliseconds(600))
        await events.reset()
        try Data("watcher edit\n".utf8).write(to: first.appending(path: "file.txt"))
        for _ in 0..<100 {
            if await events.scope.contains(.status) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(
            "Actual temporary-directory file event refreshes only status and diff",
            await events.scope == [.status, .diff])
        try Data("first\n".utf8).write(to: first.appending(path: "file.txt"))
        watcher.stop()

        let stash = try await b.createStash(
            message: "Detached worktree changes", includeUntracked: false, expectedHead: initial)
        let sharedStashes = try await a.stashes()
        try check(
            "Stash created in detached worktree is shared by object identity",
            sharedStashes.entries.first?.objectID == stash.objectID)
        _ = try await b.restoreStash(
            stash, in: b.stashes(), restoreIndex: true, pop: true, expectedHead: initial)
        let restoredIndex = try await git(["show", ":file.txt"], at: second)
        let untouchedMain = try await git(["show", ":file.txt"])
        let untouchedTopic = try await git(["show", ":file.txt"], at: first)
        try check(
            "Stash pop restores only its chosen worktree and removes the shared entry",
            try await a.stashes().entries.isEmpty && restoredIndex == Data("second\n".utf8)
                && untouchedMain == Data("base\n".utf8) && untouchedTopic == Data("first\n".utf8))

        let clock = ContinuousClock()
        var samples: [String: [Double]] = ["main": [], "linked": []]
        for iteration in 0..<30 {
            let locations =
                iteration.isMultiple(of: 2)
                ? [("main", main), ("linked", first)] : [("linked", first), ("main", main)]
            for (name, url) in locations {
                let start = clock.now
                let location = try await RepositoryService.discover(url, engine: engine)
                _ = try await RepositoryService(location: location, engine: engine).readSnapshot()
                let duration = start.duration(to: clock.now).components
                samples[name, default: []].append(
                    Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            }
        }
        let p95 = samples.mapValues { $0.sorted()[28] }
        // Retain every measurement before asserting the budget. A slow runner
        // must leave evidence, rather than only an error and no sample file.
        if CommandLine.arguments.count > 1 {
            let measurements: [String: Any] = [
                "completed": false, "discoveryAndFirstSnapshotMilliseconds": samples,
                "p95Milliseconds": p95, "backendBudgetMilliseconds": 2000,
            ]
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        try check(
            "Thirty discovery plus first-snapshot samples stay within the 2000 ms backend budget",
            p95.values.allSatisfy { $0 <= 2000 })

        try Data("main conflict\n".utf8).write(to: main.appending(path: "file.txt"))
        try await primary.stage(paths: ["file.txt"], expectedHead: initial)
        let mainTip = try await primary.commit(message: "Main conflict", amend: false, expectedHead: initial)
        let mainBranch = try await a.branches().first { $0.name == "main" }!
        do {
            try await a.merge(mainBranch, expectedHead: committed)
            try check("Merge must expose the linked-worktree conflict", false)
        } catch is GitFailure {}
        let conflict = try await a.status()
        let mainState = try await primary.status()
        let siblingState = try await b.status()
        try check(
            "Real merge conflict state is private to its worktree",
            conflict.sequencer == .merge && !conflict.conflicts.isEmpty && mainState.sequencer == .none
                && siblingState.sequencer == .none)
        let recovery = try await open(first)
        try await recovery.sequencer(continueOperation: false, expected: .merge)
        try check(
            "Reopened linked worktree can abort without changing sibling content",
            try await recovery.head() == committed
                && Data(contentsOf: first.appending(path: "file.txt")) == Data("first\n".utf8))
        do { try await recovery.merge(mainBranch, expectedHead: committed) } catch is GitFailure {}
        try Data("resolved\n".utf8).write(to: first.appending(path: "file.txt"))
        try await recovery.markResolved(path: "file.txt", expectedHead: committed)
        try await recovery.sequencer(continueOperation: true, expected: .merge)
        let merged = try await recovery.status()
        let finalMain = try await primary.head()
        let finalSibling = try await b.head()
        let finalMainIndex = try await git(["show", ":file.txt"])
        let finalSiblingIndex = try await git(["show", ":file.txt"], at: second)
        try check(
            "Linked merge continue preserves other HEADs and indexes",
            merged.sequencer == .none && merged.files.isEmpty && finalMain == mainTip
                && finalSibling == initial && finalMainIndex == Data("main conflict\n".utf8)
                && finalSiblingIndex == Data("second\n".utf8)
                && (try Data(contentsOf: second.appending(path: "file.txt"))) == Data("second\n".utf8))
        let expectedReopenHead = merged.head

        // Identity attacks happen only after all normal behavior; every directory
        // and replacement remains under this private fixture's cleanup root.
        let commonPointer = a.location.gitDirectory.appending(path: "commondir")
        let pointerBytes = try Data(contentsOf: commonPointer)
        try pointerBytes.write(to: commonPointer, options: .atomic)
        do {
            _ = try await a.status()
            try check("Rewritten commondir must reject old session", false)
        } catch ModelFailure.repositoryReplaced {}
        let reopened = try await open(first)
        try check(
            "Reopen after pointer rewrite restores correct worktree",
            try await reopened.head() == expectedReopenHead)
        try await git(["worktree", "remove", second.path, "--force"])
        do {
            _ = try await b.status()
            try check("Removed worktree must reject old session", false)
        } catch ModelFailure.repositoryReplaced {}
        let old = root.appending(path: "old-common")
        let commonURL = primary.location.commonDirectory
        try FileManager.default.moveItem(at: commonURL, to: old)
        try FileManager.default.copyItem(at: old, to: commonURL)
        do {
            _ = try await reopened.status()
            try check("Replaced shared directory must reject old session", false)
        } catch ModelFailure.repositoryReplaced {}
        checks.append(
            "Pointer rewrite, removed worktree and shared-directory replacement reject stale sessions")
        let report: [String: Any] = [
            "completed": true, "passed": checks.count, "checks": checks, "xctestExecuted": false,
            "discoveryAndFirstSnapshotMilliseconds": samples, "p95Milliseconds": p95,
            "backendBudgetMilliseconds": 2000, "applicationPerformanceAcceptance": false,
        ]
        if CommandLine.arguments.count > 1 {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
                to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("Worktree checks passed: \(checks.count)")
    }
}
