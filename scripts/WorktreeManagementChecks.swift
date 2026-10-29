import Foundation
import WeGitCore

private struct AfterMoveRunner: ProcessRunning {
    let callback: @Sendable (URL, URL) throws -> Void
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await ProcessRunner().run(request)
        if let i = request.arguments.firstIndex(of: "worktree"), request.arguments.count > i + 3,
            request.arguments[i + 1] == "move", result.exitCode == 0
        {
            try callback(
                URL(fileURLWithPath: request.arguments[i + 2]), URL(fileURLWithPath: request.arguments[i + 3])
            )
        }
        return result
    }
}

@main struct WorktreeManagementChecks {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("Worktree management check failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var checks: [String] = []
        func check(_ name: String, _ pass: Bool) throws {
            guard pass else {
                throw NSError(
                    domain: "WorktreeManagementChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
            }
            checks.append(name)
            print("PASS: " + name)
        }
        func reject(_ name: String, _ operation: () async throws -> Void) async throws {
            do { try await operation() } catch {
                try check(name, true)
                return
            }
            try check(name, false)
        }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitWorktreeManagement-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let canonical = root.resolvingSymlinksInPath()
        var completed = false
        defer {
            if let path = CommandLine.arguments.dropFirst().first {
                let report: [String: Any] = [
                    "checks": checks, "total": checks.count,
                    "failed": completed ? 0 : 1, "fixturePath": canonical.path,
                    "fixturePreserved": !completed,
                ]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: path))
            }
            if completed {
                try? FileManager.default.removeItem(at: canonical)
            } else {
                print("Fixture preserved: " + canonical.path)
            }
        }
        let main = canonical.appending(path: "main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: false)
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let engine = GitEngine(environment: env)
        @discardableResult func git(_ args: [String], at location: URL? = nil) async throws -> Data {
            try await engine.run(args, in: location ?? main).stdout
        }
        func open(_ url: URL, with selected: GitEngine? = nil) async throws -> RepositoryService {
            let value = selected ?? engine
            return try await RepositoryService(
                location: RepositoryService.discover(url, engine: value), engine: value)
        }
        try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Worktree Fixture"), ("user.email", "fixture@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", canonical.appending(path: "no-hooks").path),
        ] {
            try await git(["config", key, value])
        }
        let base = Data("base\n".utf8)
        try base.write(to: main.appending(path: "file"))
        try Data("*.ignored\n".utf8).write(to: main.appending(path: ".gitignore"))
        try await git(["add", "."])
        try await git(["commit", "-m", "Base"])
        let bare = canonical.appending(path: "remote.git")
        try await git(["init", "--bare", bare.path])
        try await git(["remote", "add", "origin", bare.path])
        try await git(["push", "origin", "main"])
        let service = try await open(main)
        let originalHead = try await service.head()
        let originalIndex = try Data(contentsOf: service.location.gitDirectory.appending(path: "index"))
        let destination = canonical.appending(path: "中文\nworktree")
        let plan = try await service.prepareWorktreeCreation(at: destination, kind: .newBranch("topic"))
        try check(
            "Creation preview does not create directories or change the index",
            !FileManager.default.fileExists(atPath: destination.path)
                && (try Data(contentsOf: service.location.gitDirectory.appending(path: "index")))
                    == originalIndex
        )
        let created = try await service.executeWorktreeCreation(plan)
        try check(
            "Creation preserves newline/Unicode path and base bytes",
            created.location.root.path == destination.path
                && (try Data(contentsOf: destination.appending(path: "file"))) == base)
        try check(
            "Creation leaves the source HEAD and index unchanged",
            try await service.head() == originalHead
                && Data(contentsOf: service.location.gitDirectory.appending(path: "index")) == originalIndex)
        var trees = try await service.worktrees()
        try check(
            "NUL list reports primary and linked branch identities",
            trees.count == 2 && trees[0].primary
                && trees.contains { $0.path == destination.path && $0.branchName == "topic" })
        try await reject("Occupied branch creation is refused") {
            _ = try await service.prepareWorktreeCreation(
                at: canonical.appending(path: "occupied"), kind: .existingBranch("topic"))
        }
        try await reject("Nested creation is refused") {
            _ = try await service.prepareWorktreeCreation(at: main.appending(path: "nested"), kind: .detached)
        }
        let foreign = canonical.appending(path: "foreign")
        let staleCreate = try await service.prepareWorktreeCreation(at: foreign, kind: .newBranch("stale"))
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let foreignBytes = Data("foreign must stay\n".utf8)
        try foreignBytes.write(to: foreign.appending(path: "private"))
        try await reject("A late foreign destination blocks creation") {
            _ = try await service.executeWorktreeCreation(staleCreate)
        }
        try check(
            "Foreign destination bytes remain unchanged",
            try Data(contentsOf: foreign.appending(path: "private")) == foreignBytes)
        try await git(["branch", "free"])
        let freePath = canonical.appending(path: "free")
        let freePlan = try await service.prepareWorktreeCreation(at: freePath, kind: .existingBranch("free"))
        let free = try await service.executeWorktreeCreation(freePlan)
        try check(
            "Existing branch attaches instead of detaching",
            try await open(free.location.root).status().branch == "free")
        let detachedPath = canonical.appending(path: "detached")
        let detachedPlan = try await service.prepareWorktreeCreation(at: detachedPath, kind: .detached)
        let detached = try await service.executeWorktreeCreation(detachedPlan)
        try check(
            "Detached creation pins the selected commit",
            try await open(detached.location.root).status().isDetached)
        try await git(["worktree", "lock", freePath.path])
        trees = try await service.worktrees()
        let locked = trees.first { $0.path == freePath.path }!
        try await reject("Locked worktree cannot be removed") {
            _ = try await service.prepareWorktreeRemoval(locked)
        }
        try await git(["worktree", "unlock", freePath.path])
        try Data("unsaved\n".utf8).write(to: freePath.appending(path: "file"))
        trees = try await service.worktrees()
        let dirty = trees.first { $0.path == freePath.path }!
        try await reject("Tracked unsaved content blocks removal") {
            _ = try await service.prepareWorktreeRemoval(dirty)
        }
        try check(
            "Rejected removal preserves tracked bytes",
            try Data(contentsOf: freePath.appending(path: "file")) == Data("unsaved\n".utf8))
        try base.write(to: freePath.appending(path: "file"))
        try await git(["update-index", "--skip-worktree", "file"], at: freePath)
        trees = try await service.worktrees()
        let skipped = trees.first { $0.path == freePath.path }!
        try await reject("Skip-worktree flags block removal") {
            _ = try await service.prepareWorktreeRemoval(skipped)
        }
        try await git(["update-index", "--no-skip-worktree", "file"], at: freePath)
        let orphanBytes = Data("detached only\n".utf8)
        try orphanBytes.write(to: detachedPath.appending(path: "file"))
        try await git(["add", "file"], at: detachedPath)
        try await git(["commit", "-m", "Orphan"], at: detachedPath)
        trees = try await service.worktrees()
        let orphan = trees.first { $0.path == detachedPath.path }!
        try await reject("An unreferenced detached commit blocks removal") {
            _ = try await service.prepareWorktreeRemoval(orphan)
        }
        try check(
            "Orphan rejection preserves commit and working bytes",
            try await open(detachedPath).head() == orphan.head
                && Data(contentsOf: detachedPath.appending(path: "file")) == orphanBytes)
        let ignored = Data("ignored private bytes\n".utf8)
        let late = Data("late ignored bytes\n".utf8)
        try ignored.write(to: destination.appending(path: "private.ignored"))
        let racing = GitEngine(
            runner: AfterMoveRunner(callback: { old, moved in
                try late.write(to: moved.appending(path: "late.ignored"))
                try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
                try foreignBytes.write(to: old.appending(path: "foreign"))
            }), environment: env)
        let raceService = try await open(main, with: racing)
        trees = try await raceService.worktrees()
        let removable = trees.first { $0.path == destination.path }!
        let removal = try await raceService.prepareWorktreeRemoval(removable)
        let removed = try await raceService.executeWorktreeRemoval(removal)
        try check(
            "Removal retains tracked, ignored and late bytes",
            try Data(contentsOf: removed.preservedDirectory.appending(path: "file")) == base
                && Data(contentsOf: removed.preservedDirectory.appending(path: "private.ignored")) == ignored
                && Data(contentsOf: removed.preservedDirectory.appending(path: "late.ignored")) == late)
        try check(
            "Original-path foreign directory is untouched",
            try Data(contentsOf: destination.appending(path: "foreign")) == foreignBytes)
        try check(
            "Removal preserves private Git state",
            FileManager.default.fileExists(
                atPath: removed.preservedDirectory.deletingLastPathComponent().appending(
                    path: "git-state/index"
                ).path))
        trees = try await service.worktrees()
        try check(
            "Only the selected registration retires",
            trees.count == 3 && !trees.contains { $0.branchName == "topic" })
        let branchObject = try await git(["rev-parse", "refs/heads/topic"]).textValue
        let finalHead = try await service.head()
        let finalIndex = try Data(contentsOf: service.location.gitDirectory.appending(path: "index"))
        try check(
            "Branch object, source HEAD and source index remain",
            branchObject == originalHead && finalHead == originalHead && finalIndex == originalIndex)
        completed = true
        print("\(checks.count) Worktree management checks passed")
    }
}

extension Data {
    fileprivate var textValue: String {
        String(decoding: self, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
