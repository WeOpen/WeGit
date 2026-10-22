import Foundation
import WeGitCore

private struct StashReceiptFailure: ProcessRunning {
    enum Point { case beforeDrop, afterDrop, afterPush }
    let point: Point
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let isDrop = request.arguments.contains("stash") && request.arguments.contains("drop")
        let isPush = request.arguments.contains("stash") && request.arguments.contains("push")
        if isDrop && point == .beforeDrop { throw ProcessFailure.timedOut }
        let result = try await ProcessRunner().run(request)
        if (isDrop && point == .afterDrop) || (isPush && point == .afterPush) {
            throw ProcessFailure.timedOut
        }
        return result
    }
}

private actor InsertBeforeDrop: ProcessRunning {
    private var inserted = false
    private(set) var insertedObject: String?
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if !inserted && request.arguments.contains("stash") && request.arguments.contains("drop"),
            let root = request.directory
        {
            inserted = true
            try Data("concurrent unsaved bytes\n".utf8).write(to: root.appending(path: "file"))
            _ = try await ProcessRunner().run(
                ProcessRequest(
                    executable: request.executable,
                    arguments: ["stash", "push", "-m", "Concurrent inserted record"],
                    directory: root, environment: request.environment))
            let current = try await ProcessRunner().run(
                ProcessRequest(
                    executable: request.executable, arguments: ["rev-parse", "refs/stash"], directory: root,
                    environment: request.environment))
            insertedObject = String(decoding: current.stdout, as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        return try await ProcessRunner().run(request)
    }
}

@main struct StashChecks {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("Stash check failed: \(error.localizedDescription)\n".utf8))
            if let failure = error as? GitFailure {
                FileHandle.standardError.write(Data((failure.details + "\n").utf8))
            }
            exit(1)
        }
    }

    static func run() async throws {
        var checks: [String] = []
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else {
                throw NSError(
                    domain: "WeGit.StashChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
            }
            checks.append(name)
        }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitStashChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let engine = GitEngine(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: environment)
        @discardableResult func git(_ args: [String]) async throws -> Data {
            try await engine.run(args, in: root).stdout
        }
        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: root.appending(path: name))
        }
        _ = try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Stash Fixture"), ("user.email", "stash@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", root.appending(path: "no-hooks").path),
        ] {
            try await git(["config", key, value])
        }
        let location = try await RepositoryService.discover(root, engine: engine)
        let service = RepositoryService(location: location, engine: engine)
        let reflogScope = RepositoryRefreshScope.events(
            paths: [location.gitDirectory.appending(path: "logs/refs/stash").path], flags: [0],
            location: location)
        try check(
            "A reflog-only stash deletion requests a browser status refresh", reflogScope.contains(.status))
        try check("Unborn repository has an empty stash list", try await service.stashes().entries.isEmpty)
        try write("a.txt", "base-a\n")
        try write("b.txt", "base-b\n")
        try write(".gitignore", "ignored\n")
        try await git(["add", "."])
        try await git(["commit", "-m", "Base"])
        let head = try await service.head()
        try write("a.txt", "index-a\n")
        try await service.stage(paths: ["a.txt"], expectedHead: head)
        try write("a.txt", "work-a\n")
        try write("b.txt", "work-b\n")
        try write("新文件\n[1].txt", "untracked\n")
        try write("ignored", "private ignored\n")
        let entry = try await service.createStash(
            message: "第一条记录", includeUntracked: false, expectedHead: head)
        let list = try await service.stashes()
        try check(
            "Named stash records retain their source branch",
            entry.message.contains("第一条记录") && entry.branch == "main")
        try check("Save retains HEAD", try await service.head() == head)
        try check(
            "Save restores tracked working content",
            try Data(contentsOf: root.appending(path: "a.txt")) == Data("base-a\n".utf8))
        try check(
            "Excluded untracked content is preserved",
            try Data(contentsOf: root.appending(path: "新文件\n[1].txt")) == Data("untracked\n".utf8))
        try check(
            "Ignored content is preserved",
            try Data(contentsOf: root.appending(path: "ignored")) == Data("private ignored\n".utf8))
        try await git(["config", "log.date", "iso"])
        try await git(["config", "i18n.logOutputEncoding", "UTF-16"])
        try check(
            "Stash metadata stays canonical with configured date and output encoding",
            try await service.stashes().entries == list.entries)
        try await git(["config", "--unset", "log.date"])
        try await git(["config", "--unset", "i18n.logOutputEncoding"])
        let contents = try await service.stashContents(entry, in: list)
        let staged = try await service.commitComparison(id: contents.index.id, parent: contents.base)
        let working = try await service.commitComparison(id: contents.working.id, parent: contents.index.id)
        try check("Index preview contains only originally staged file", staged.files.map(\.path) == ["a.txt"])
        try check(
            "Working preview retains the index-to-worktree difference",
            Set(working.files.map(\.path)) == ["a.txt", "b.txt"])
        try check("Excluded untracked content has no preview parent", contents.untracked == nil)
        _ = try await service.restoreStash(
            entry, in: list, restoreIndex: true, pop: false, expectedHead: head)
        let applied = try await service.status()
        try check(
            "Apply restores original staged and unstaged layers",
            applied.files.contains { $0.path == "a.txt" && $0.staged && $0.unstaged })
        try check("Apply preserves the stash", try await service.stashes().entries == list.entries)
        try check(
            "Apply restores working bytes",
            try Data(contentsOf: root.appending(path: "a.txt")) == Data("work-a\n".utf8))
        var dirtyRejected = false
        do {
            _ = try await service.restoreStash(
                entry, in: list, restoreIndex: false, pop: false, expectedHead: head)
        } catch ModelFailure.unsupported { dirtyRejected = true }
        try check("Dirty tracked work rejects a repeated restoration", dirtyRejected)
        try await git(["reset", "--hard", "HEAD"])
        let second = try await service.createStash(
            message: "包含未跟踪", includeUntracked: true, expectedHead: head)
        let secondList = try await service.stashes()
        try check(
            "Included untracked files leave the working tree",
            !FileManager.default.fileExists(atPath: root.appending(path: "新文件\n[1].txt").path))
        let untrackedContents = try await service.stashContents(second, in: secondList)
        let untrackedCommit = try await service.readCommit(untrackedContents.untracked!.id)
        let untrackedDiff = try await service.commitComparison(id: untrackedCommit.id)
        try check(
            "Untracked preview contains exact special file path",
            untrackedDiff.files.map(\.path) == ["新文件\n[1].txt"])
        var staleRejected = false
        do { try await service.deleteStash(entry, in: list, expectedHead: head) } catch ModelFailure.changed {
            staleRejected = true
        }
        try check("Changed stash numbering rejects a stale delete", staleRejected)
        _ = try await service.restoreStash(
            second, in: secondList, restoreIndex: false, pop: true, expectedHead: head)
        try check(
            "Pop removes only the restored record",
            try await service.stashes().entries.map(\.objectID) == [entry.objectID])
        try check(
            "Pop restores exact untracked bytes",
            try Data(contentsOf: root.appending(path: "新文件\n[1].txt")) == Data("untracked\n".utf8))
        let current = try await service.stashes()
        try await service.deleteStash(current.entries[0], in: current, expectedHead: head)
        try check(
            "Delete single stash does not alter working files",
            try Data(contentsOf: root.appending(path: "新文件\n[1].txt")) == Data("untracked\n".utf8))
        try check("All explicitly deleted records disappear", try await service.stashes().entries.isEmpty)
        try write("a.txt", "stashed-conflict\n")
        let conflictEntry = try await service.createStash(
            message: "Conflict", includeUntracked: false, expectedHead: head)
        let conflictList = try await service.stashes()
        try write("a.txt", "different-base\n")
        try await git(["add", "a.txt"])
        try await git(["commit", "-m", "Changed base"])
        let conflictHead = try await service.head()
        var conflictReported = false
        do {
            _ = try await service.restoreStash(
                conflictEntry, in: conflictList, restoreIndex: false, pop: true, expectedHead: conflictHead)
        } catch ModelFailure.unsupported { conflictReported = true }
        let conflictState = try await service.status()
        try check(
            "Pop reports real apply conflicts",
            conflictReported && !conflictState.conflicts.isEmpty)
        try check(
            "Pop conflict preserves stash",
            try await service.stashes().entries.map(\.objectID) == [conflictEntry.objectID])
        try check(
            "Stash conflicts do not invent a merge sequencer", try await service.status().sequencer == .none)
        try await git(["reset", "--hard", "HEAD"])
        try write("replacement", "base\n")
        try await git(["add", "replacement"])
        try await git(["commit", "-m", "Replacement base"])
        let replacementHead = try await service.head()
        try FileManager.default.removeItem(at: root.appending(path: "replacement"))
        try FileManager.default.createDirectory(
            at: root.appending(path: "replacement"), withIntermediateDirectories: true)
        try write("replacement/child", "must survive\n")
        var obstructionRejected = false
        do {
            _ = try await service.createStash(
                message: "Must reject", includeUntracked: false, expectedHead: replacementHead)
        } catch ModelFailure.unsupported { obstructionRejected = true }
        try check("Save rejects unsaved untracked file/directory obstructions", obstructionRejected)
        try check(
            "Rejected save leaves obstructing child bytes",
            try Data(contentsOf: root.appending(path: "replacement/child")) == Data("must survive\n".utf8))
        try await git(["config", "core.excludesFile", root.appending(path: "exclude-patterns").path])
        try write("exclude-patterns", "replacement/child\n")
        var ignoredRejected = false
        do {
            _ = try await service.createStash(
                message: "Must reject ignored", includeUntracked: true, expectedHead: replacementHead)
        } catch ModelFailure.unsupported { ignoredRejected = true }
        try check("Save rejects ignored obstructions even when including untracked", ignoredRejected)
        try check(
            "Rejected ignored save leaves child bytes",
            try Data(contentsOf: root.appending(path: "replacement/child")) == Data("must survive\n".utf8))
        try await git(["-C", "replacement", "init", "-b", "nested"])
        var embeddedRejected = false
        do {
            _ = try await service.createStash(
                message: "Must preserve embedded repo", includeUntracked: true, expectedHead: replacementHead)
        } catch ModelFailure.unsupported { embeddedRejected = true }
        try check("Save rejects an embedded repository replacing a tracked file", embeddedRejected)
        let embeddedBytes = try Data(contentsOf: root.appending(path: "replacement/child"))
        try check(
            "Embedded repository metadata and private bytes survive rejection",
            FileManager.default.fileExists(atPath: root.appending(path: "replacement/.git").path)
                && embeddedBytes == Data("must survive\n".utf8))
        try FileManager.default.removeItem(at: root.appending(path: "replacement"))
        try await git(["reset", "--hard", "HEAD"])
        try write(".gitignore", "ignored\nnew-file/\n")
        try await git(["add", ".gitignore"])
        try await git(["commit", "-m", "Ignore obstruction fixture"])
        let ignoredRestoreHead = try await service.head()
        try write("new-file", "saved new file\n")
        try await service.stage(paths: ["new-file"], expectedHead: ignoredRestoreHead)
        let obstructionEntry = try await service.createStash(
            message: "Restore guard", includeUntracked: false, expectedHead: ignoredRestoreHead)
        let obstructionList = try await service.stashes()
        try FileManager.default.createDirectory(
            at: root.appending(path: "new-file"), withIntermediateDirectories: true)
        try write("new-file/child", "ignored private bytes\n")
        let ignoredStatus = try await service.status()
        try check(
            "Ignored obstruction is absent from ordinary status",
            !ignoredStatus.files.contains { $0.path.hasPrefix("new-file") })
        var ignoredRestoreRejected = false
        do {
            _ = try await service.restoreStash(
                obstructionEntry, in: obstructionList, restoreIndex: true, pop: true,
                expectedHead: ignoredRestoreHead)
        } catch ModelFailure.unsupported { ignoredRestoreRejected = true }
        try check("Pop refuses ignored directory obstructions before applying", ignoredRestoreRejected)
        try check(
            "Rejected Pop preserves ignored bytes",
            try Data(contentsOf: root.appending(path: "new-file/child"))
                == Data("ignored private bytes\n".utf8))
        try check(
            "Rejected Pop preserves its stash record",
            try await service.stashes().entries.contains(obstructionEntry))
        try await git(["mv", "replacement", "renamed"])
        try FileManager.default.createDirectory(
            at: root.appending(path: "replacement"), withIntermediateDirectories: true)
        try write("replacement/child", "ignored rename source\n")
        var renameRejected = false
        do {
            _ = try await service.createStash(
                message: "Rename guard", includeUntracked: true, expectedHead: ignoredRestoreHead)
        } catch ModelFailure.unsupported { renameRejected = true }
        try check("Save checks the original path of staged renames", renameRejected)
        try check(
            "Rejected rename save preserves ignored source bytes",
            try Data(contentsOf: root.appending(path: "replacement/child"))
                == Data("ignored rename source\n".utf8))
        try FileManager.default.removeItem(at: root.appending(path: "replacement"))
        try await git(["reset", "--hard", "HEAD"])
        try await git(["update-index", "--assume-unchanged", "b.txt"])
        try write("b.txt", "assumed private bytes\n")
        try write("a.txt", "other pending change\n")
        var specialRejected = false
        do {
            _ = try await service.createStash(
                message: "Index flag guard", includeUntracked: true, expectedHead: ignoredRestoreHead)
        } catch ModelFailure.unsupported { specialRejected = true }
        try check("Save rejects special index flags rather than trusting clean status", specialRejected)
        try check(
            "Rejected flagged save preserves bytes",
            try Data(contentsOf: root.appending(path: "b.txt")) == Data("assumed private bytes\n".utf8))
        try await git(["update-index", "--no-assume-unchanged", "b.txt"])
        try await git(["reset", "--hard", "HEAD"])
        try await git(["rm", "--cached", "b.txt"])
        try write("b.txt", "untracked replacement bytes\n")
        var deletedIndexRejected = false
        do {
            _ = try await service.createStash(
                message: "Deleted index guard", includeUntracked: false, expectedHead: ignoredRestoreHead)
        } catch ModelFailure.unsupported { deletedIndexRejected = true }
        try check("Save rejects excluded untracked files replacing staged deletions", deletedIndexRejected)
        try check(
            "Rejected staged deletion preserves untracked replacement bytes",
            try Data(contentsOf: root.appending(path: "b.txt")) == Data("untracked replacement bytes\n".utf8))
        let raceRoot = root.appending(path: "concurrent-fixture")
        try FileManager.default.createDirectory(at: raceRoot, withIntermediateDirectories: true)
        let runner = InsertBeforeDrop()
        let raceEngine = GitEngine(
            executable: URL(fileURLWithPath: "/usr/bin/git"), runner: runner, environment: environment)
        _ = try await raceEngine.run(["init", "-b", "main"], in: raceRoot)
        for (key, value) in [
            ("user.name", "Race Fixture"), ("user.email", "race@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", raceRoot.appending(path: "no-hooks").path),
        ] {
            _ = try await raceEngine.run(["config", key, value], in: raceRoot)
        }
        try Data("base\n".utf8).write(to: raceRoot.appending(path: "file"))
        _ = try await raceEngine.run(["add", "."], in: raceRoot)
        _ = try await raceEngine.run(["commit", "-m", "Race base"], in: raceRoot)
        let raceLocation = try await RepositoryService.discover(raceRoot, engine: raceEngine)
        let raceService = RepositoryService(location: raceLocation, engine: raceEngine)
        let raceHead = try await raceService.head()
        try Data("original saved bytes\n".utf8).write(to: raceRoot.appending(path: "file"))
        let original = try await raceService.createStash(
            message: "Original record", includeUntracked: false, expectedHead: raceHead)
        let raceList = try await raceService.stashes()
        var raceReported = false
        do {
            try await raceService.deleteStash(original, in: raceList, expectedHead: raceHead)
        } catch ModelFailure.unsupported { raceReported = true }
        let recovered = try await raceService.stashes()
        let insertedObject = await runner.insertedObject
        try check("A concurrent reflog insertion is detected from the drop receipt", raceReported)
        try check(
            "The originally confirmed record is not silently lost",
            recovered.entries.contains { $0.objectID == original.objectID })
        try check(
            "The concurrently removed record is immediately restored",
            recovered.entries.contains { $0.objectID == insertedObject })
        for point in [StashReceiptFailure.Point.beforeDrop, .afterDrop] {
            let pending = try await raceService.stashes()
            let target = pending.entries.first!
            let failingEngine = GitEngine(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                runner: StashReceiptFailure(point: point), environment: environment)
            let failingService = RepositoryService(location: raceLocation, engine: failingEngine)
            let outcome = try await failingService.restoreStash(
                target, in: pending, restoreIndex: false, pop: true, expectedHead: raceHead)
            let needsReview: Bool
            if case .appliedNeedsReview = outcome { needsReview = true } else { needsReview = false }
            let label = point == .beforeDrop ? "before removal" : "after removal"
            try check("Pop timeout \(label) reports applied contents needing review", needsReview)
            try check(
                "Pop timeout \(label) preserves applied working bytes",
                try Data(contentsOf: raceRoot.appending(path: "file"))
                    == Data("concurrent unsaved bytes\n".utf8))
            let remaining = try await raceService.stashes()
            try check(
                "Pop timeout \(label) exposes the real remaining list",
                remaining.entries.contains { $0.objectID == target.objectID } == (point == .beforeDrop))
            _ = try await raceEngine.run(["reset", "--hard", "HEAD"], in: raceRoot)
        }
        try Data("uncertain saved bytes\n".utf8).write(to: raceRoot.appending(path: "file"))
        let pushEngine = GitEngine(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            runner: StashReceiptFailure(point: .afterPush), environment: environment)
        let pushService = RepositoryService(location: raceLocation, engine: pushEngine)
        var uncertainSaveReported = false
        do {
            _ = try await pushService.createStash(
                message: "Uncertain save", includeUntracked: false, expectedHead: raceHead)
        } catch ModelFailure.unsupported { uncertainSaveReported = true }
        try check("Save timeout after mutation requires checking the changed list", uncertainSaveReported)
        let uncertain = try await raceService.stashes()
        let uncertainContents = try await raceService.stashContents(uncertain.entries.first!, in: uncertain)
        let savedBytes = try await raceEngine.run(
            ["show", uncertainContents.working.id + ":file"], in: raceRoot
        ).stdout
        try check(
            "An uncertain save retains exact bytes in its new record",
            savedBytes == Data("uncertain saved bytes\n".utf8))
        try Data("pending scope bytes\n".utf8).write(to: raceRoot.appending(path: "file"))
        let saveScope = try await raceService.status().files
        try Data("new untracked scope\n".utf8).write(to: raceRoot.appending(path: "extra"))
        var scopeRejected = false
        do {
            _ = try await raceService.createStash(
                message: "Stale scope", includeUntracked: true, expectedHead: raceHead,
                expectedFiles: saveScope)
        } catch ModelFailure.changed { scopeRejected = true }
        try check("An externally changed save preview is rejected", scopeRejected)
        try check(
            "Rejected stale preview preserves tracked and untracked working bytes",
            try Data(contentsOf: raceRoot.appending(path: "file")) == Data("pending scope bytes\n".utf8)
                && Data(contentsOf: raceRoot.appending(path: "extra")) == Data("new untracked scope\n".utf8))
        try check(
            "Rejected stale preview leaves the saved list unchanged",
            try await raceService.stashes().entries == uncertain.entries)
        let data = try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("\(checks.count) isolated stash behavior checks passed.")
    }
}
