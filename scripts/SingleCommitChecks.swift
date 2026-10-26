import Foundation
import WeGitCore

private struct LostSingleCommitReply: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await ProcessRunner().run(request)
        if request.arguments.contains("cherry-pick"), !request.arguments.contains("--continue"),
            result.exitCode == 0
        {
            throw ProcessFailure.timedOut
        }
        return result
    }
}

private struct CommitFixture {
    let root: URL
    let engine: GitEngine
    let service: RepositoryService

    static func create() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitSingleCommit-中文:\n" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let engine = GitEngine(environment: environment)
        do {
            _ = try await engine.run(["init", "-b", "main"], in: root)
            for (key, value) in [
                ("user.name", "Single Commit Fixture"), ("user.email", "commit@example.invalid"),
                ("commit.gpgsign", "false"), ("core.hooksPath", root.appending(path: ".git/no-hooks").path),
            ] { _ = try await engine.run(["config", key, value], in: root) }
            let service = try await RepositoryService(
                location: RepositoryService.discover(root, engine: engine), engine: engine)
            return Self(root: root, engine: engine, service: service)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @discardableResult func git(_ arguments: [String]) async throws -> String {
        try await engine.run(arguments, in: root).text.trimmingCharacters(in: .newlines)
    }
    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
    func commit(_ message: String) async throws -> String {
        try await git(["add", "-A"])
        try await git(["commit", "-m", message])
        return try await git(["rev-parse", "HEAD"])
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func objects() throws -> [String] {
        let base = root.appending(path: ".git/objects")
        return (FileManager.default.enumerator(atPath: base.path)?.allObjects as? [String] ?? []).sorted()
    }
    func reopen() async throws -> RepositoryService {
        try await RepositoryService(
            location: RepositoryService.discover(root, engine: engine), engine: engine)
    }
}

private final class CheckLog {
    var checks: [String] = []
    let output: URL
    init() { output = URL(fileURLWithPath: CommandLine.arguments[1]) }
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else {
            throw NSError(domain: "SingleCommitChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
        }
        checks.append(name)
        print("PASS: " + name)
        try save(completed: false)
    }
    func save(completed: Bool, samples: [Double] = []) throws {
        var report: [String: Any] = [
            "completed": completed, "passed": checks.count, "checks": checks, "xctestExecuted": false,
        ]
        if !samples.isEmpty {
            report["previewMilliseconds"] = samples
            report["p95Milliseconds"] = samples.sorted()[28]
            report["backendBudgetMilliseconds"] = 2000
            report["applicationPerformanceAcceptance"] = false
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output)
    }
}

@main struct SingleCommitChecks {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("Single-commit check failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func rejects(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return false
        } catch { return true }
    }

    static func run() async throws {
        let log = CheckLog()
        let f = try await CommitFixture.create()
        defer { f.remove() }
        try f.write("base.txt", "base\n")
        let base = try await f.commit("Base")
        try await f.git(["switch", "-c", "topic"])
        try f.write("文件\n[one].txt", "topic\r\nwithout final newline")
        let target = try await f.commit("Selected change")
        try await f.git(["switch", "main"])
        let objects = try f.objects()
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let plan = try await f.service.prepareSingleCommit(.cherryPick, target: target)
        try log.check(
            "Preview reports the exact Unicode and newline path", plan.files.map(\.path) == ["文件\n[one].txt"])
        try log.check(
            "Preview preserves HEAD, raw index and repository objects",
            try await f.service.head() == base && f.objects() == objects
                && Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        let outcome = try await f.service.executeSingleCommit(plan)
        guard case .committed(let picked) = outcome else { throw ModelFailure.changed }
        try log.check(
            "Cherry-pick creates the selected change on the current branch",
            try await f.service.readCommit(picked).parents == [base])
        try log.check(
            "Cherry-pick preserves the exact file bytes",
            try f.read("文件\n[one].txt") == "topic\r\nwithout final newline")
        let revert = try await f.service.prepareSingleCommit(.revert, target: picked)
        guard case .committed(let reverted) = try await f.service.executeSingleCommit(revert) else {
            throw ModelFailure.changed
        }
        let retained = try await f.service.readCommit(picked)
        try log.check(
            "Revert creates a new commit and retains its original",
            try await f.service.readCommit(reverted).parents == [picked]
                && retained.id == picked)
        try log.check(
            "Revert restores the original tree",
            try await f.git(["rev-parse", "HEAD^{tree}"]) == f.git(["rev-parse", base + "^{tree}"]))
        let empty = try await f.service.prepareSingleCommit(.revert, target: picked)
        try log.check("An empty result is represented without a write", !empty.hasChanges)
        try log.check(
            "Executing an empty preview is refused",
            await rejects { _ = try await f.service.executeSingleCommit(empty) })
        try f.write("dirty", "preserve\n")
        try log.check(
            "Untracked work blocks execution",
            await rejects { _ = try await f.service.prepareSingleCommit(.cherryPick, target: target) })
        try FileManager.default.removeItem(at: f.root.appending(path: "dirty"))
        try await f.git(["update-index", "--assume-unchanged", "base.txt"])
        try log.check(
            "Assume-unchanged entries are refused",
            await rejects { _ = try await f.service.prepareSingleCommit(.cherryPick, target: target) })
        try await f.git(["update-index", "--no-assume-unchanged", "base.txt"])
        try await f.git(["update-index", "--skip-worktree", "base.txt"])
        try log.check(
            "Skip-worktree entries are refused",
            await rejects { _ = try await f.service.prepareSingleCommit(.cherryPick, target: target) })
        try await f.git(["update-index", "--no-skip-worktree", "base.txt"])
        let stale = try await f.service.prepareSingleCommit(.cherryPick, target: target)
        try await f.git(["switch", "-c", "same-head"])
        try log.check(
            "A branch switch at the same HEAD invalidates confirmation",
            await rejects { _ = try await f.service.executeSingleCommit(stale) })
        try await f.git(["switch", "main"])
        try f.write(".git/info/exclude", "文件*\n")
        try f.write("文件\n[one].txt", "ignored content must survive\n")
        try log.check(
            "Ignored files created after preview invalidate execution",
            await rejects { _ = try await f.service.executeSingleCommit(stale) })
        try log.check(
            "Rejected execution preserves ignored bytes",
            try f.read("文件\n[one].txt") == "ignored content must survive\n")
        try FileManager.default.removeItem(at: f.root.appending(path: "文件\n[one].txt"))
        try f.write(".git/info/exclude", "")
        let lost = RepositoryService(
            location: f.service.location,
            engine: GitEngine(runner: LostSingleCommitReply(), environment: f.engine.environment))
        do {
            _ = try await lost.executeSingleCommit(stale)
            throw ModelFailure.changed
        } catch let unknown as SingleCommitOutcomeUnknown {
            try log.check(
                "A lost successful reply is reported as unconfirmed", unknown.observedHead != stale.head)
        }
        try log.check(
            "An old confirmation cannot repeat a completed write",
            await rejects { _ = try await f.service.executeSingleCommit(stale) })
        try await checkConflicts(log)
        try await checkIgnoredRevertAndDirectoryRename(log)
        try await checkRootAndRename(log)
        try await checkCommitFailures(log)

        let previewTarget = try await f.service.head()!
        var samples: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            _ = try await f.service.prepareSingleCommit(.revert, target: previewTarget)
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        try log.save(completed: false, samples: samples)
        try log.check("Thirty fresh previews meet the 2000 ms backend budget", samples.sorted()[28] <= 2000)
        try log.save(completed: true, samples: samples)
    }

    private static func checkConflicts(_ log: CheckLog) async throws {
        for operation in SingleCommitOperation.allCases {
            for abort in [false, true] {
                let f = try await CommitFixture.create()
                defer { f.remove() }
                try f.write("file", "base\n")
                let base = try await f.commit("Base")
                try await f.git(["switch", "-c", "topic"])
                try f.write("file", "selected\n")
                let target = try await f.commit("Selected")
                if operation == .cherryPick { try await f.git(["switch", "main"]) }
                try f.write("file", "local\n")
                let before = try await f.commit("Local")
                let plan = try await f.service.prepareSingleCommit(operation, target: target)
                try log.check(
                    "\(operation.title) previews a content conflict (abort=\(abort))",
                    plan.conflictPaths == ["file"])
                guard case .conflicts(1) = try await f.service.executeSingleCommit(plan) else {
                    throw ModelFailure.changed
                }
                let reopened = try await f.reopen()
                guard let recovery = try await reopened.status().singleCommitRecovery else {
                    throw ModelFailure.changed
                }
                try log.check(
                    "\(operation.title) recovery survives reopening (abort=\(abort))",
                    recovery.head == before && recovery.target == target)
                if abort {
                    try await reopened.recoverSingleCommit(continueOperation: false, expected: recovery)
                    try log.check(
                        "\(operation.title) abort restores HEAD and work bytes",
                        try await reopened.head() == before && f.read("file") == "local\n")
                } else {
                    try log.check(
                        "\(operation.title) cannot continue unresolved conflicts",
                        await rejects {
                            try await reopened.recoverSingleCommit(
                                continueOperation: true, expected: recovery)
                        })
                    try f.write("file", "resolved\n")
                    try await reopened.markResolved(path: "file", expectedHead: before)
                    try await reopened.recoverSingleCommit(continueOperation: true, expected: recovery)
                    let after = try await reopened.head()!
                    try log.check(
                        "\(operation.title) continue commits only the resolution",
                        try await reopened.readCommit(after).parents == [before]
                            && f.read("file") == "resolved\n")
                }
                let baseCommit = try await reopened.readCommit(base)
                let targetCommit = try await reopened.readCommit(target)
                try log.check(
                    "\(operation.title) ends its sequence and retains original objects (abort=\(abort))",
                    try await reopened.status().sequencer == .none && baseCommit.id == base
                        && targetCommit.id == target)
            }
        }
    }

    private static func checkIgnoredRevertAndDirectoryRename(_ log: CheckLog) async throws {
        let f = try await CommitFixture.create()
        defer { f.remove() }
        try f.write("file", "tracked\n")
        _ = try await f.commit("Base")
        try await f.git(["rm", "file"])
        let removed = try await f.commit("Remove file")
        try f.write(".git/info/exclude", "file\n")
        try f.write("file", "ignored private content\n")
        try log.check(
            "Revert refuses an ignored destination",
            await rejects { _ = try await f.service.prepareSingleCommit(.revert, target: removed) })
        try log.check(
            "Revert obstruction preserves private content", try f.read("file") == "ignored private content\n")
        let g = try await CommitFixture.create()
        defer { g.remove() }
        try g.write("old/base", "base\n")
        _ = try await g.commit("Base")
        try await g.git(["switch", "-c", "topic"])
        try g.write("old/private", "incoming\n")
        let target = try await g.commit("Add in old directory")
        try await g.git(["switch", "main"])
        try await g.git(["mv", "old", "new"])
        _ = try await g.commit("Move directory")
        try g.write(".git/info/exclude", "new/private\n")
        try g.write("new/private", "ignored relocated content\n")
        try log.check(
            "Directory-rename destination is checked before writing",
            await rejects { _ = try await g.service.prepareSingleCommit(.cherryPick, target: target) })
        try log.check(
            "Directory-rename rejection preserves destination bytes",
            try g.read("new/private") == "ignored relocated content\n")
    }

    private static func checkRootAndRename(_ log: CheckLog) async throws {
        let f = try await CommitFixture.create()
        defer { f.remove() }
        try f.write("base", "base\n")
        _ = try await f.commit("Base")
        try await f.git(["checkout", "--orphan", "root-source"])
        try await f.git(["rm", "-rf", "."])
        try f.write("root-file", "root bytes\n")
        let root = try await f.commit("Independent root")
        try await f.git(["switch", "main"])
        let plan = try await f.service.prepareSingleCommit(.cherryPick, target: root)
        guard case .committed = try await f.service.executeSingleCommit(plan) else {
            throw ModelFailure.changed
        }
        try log.check(
            "A root commit is cherry-picked against the empty tree",
            try f.read("base") == "base\n" && f.read("root-file") == "root bytes\n")
        let revert = try await f.service.prepareSingleCommit(.revert, target: root)
        guard case .committed = try await f.service.executeSingleCommit(revert) else {
            throw ModelFailure.changed
        }
        try log.check(
            "Reverting a root commit preserves unrelated current files",
            try f.read("base") == "base\n"
                && !FileManager.default.fileExists(atPath: f.root.appending(path: "root-file").path))
        try await f.git(["switch", "-c", "rename"])
        try await f.git(["mv", "base", "renamed"])
        let rename = try await f.commit("Rename")
        try await f.git(["switch", "main"])
        let moved = try await f.service.prepareSingleCommit(.cherryPick, target: rename)
        guard case .committed = try await f.service.executeSingleCommit(moved) else {
            throw ModelFailure.changed
        }
        try log.check(
            "An ordinary rename applies with exact bytes",
            try f.read("renamed") == "base\n"
                && !FileManager.default.fileExists(atPath: f.root.appending(path: "base").path))
    }

    private static func checkCommitFailures(_ log: CheckLog) async throws {
        for operation in SingleCommitOperation.allCases {
            let f = try await CommitFixture.create()
            defer { f.remove() }
            try f.write("base", "base\n")
            _ = try await f.commit("Base")
            try await f.git(["switch", "-c", "topic"])
            try f.write("added", "added\n")
            let target = try await f.commit("Addition")
            if operation == .cherryPick { try await f.git(["switch", "main"]) }
            let plan = try await f.service.prepareSingleCommit(operation, target: target)
            try await f.git(["config", "gpg.program", "/usr/bin/false"])
            try await f.git(["config", "gpg.format", "openpgp"])
            try await f.git(["config", "commit.gpgsign", "true"])
            let outcome = try await f.service.executeSingleCommit(plan)
            guard case .pending = outcome, let recovery = try await f.service.status().singleCommitRecovery
            else { throw ModelFailure.changed }
            try log.check(
                "\(operation.title) signing failure retains a recoverable sequence",
                try await f.service.head() == plan.head)
            try await f.git(["config", "commit.gpgsign", "false"])
            try await f.service.recoverSingleCommit(continueOperation: true, expected: recovery)
            try log.check(
                "\(operation.title) resumes after the signing configuration is repaired",
                try await f.service.status().sequencer == .none)
        }
    }
}
