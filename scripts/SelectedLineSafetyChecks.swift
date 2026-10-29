import Foundation
import WeGitCore

private actor Gate {
    var entered = false
    var released = false
    func arrive() async throws {
        entered = true
        while !released { try await Task.sleep(for: .milliseconds(10)) }
    }
    func release() { released = true }
}
private struct PausingRunner: ProcessRunning {
    let gate: Gate
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("hash-object") { try await gate.arrive() }
        return try await ProcessRunner().run(request)
    }
}
@main struct StaleProbe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitSelectedStale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let engine = GitEngine(environment: env)
        @discardableResult func git(_ args: [String], accepted: Set<Int32> = [0]) async throws
            -> ProcessResult
        {
            try await engine.run(args, in: root, accepted: accepted)
        }
        func rejected(_ op: () async throws -> Void) async -> Bool {
            do {
                try await op()
                return false
            } catch { return true }
        }
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw NSError(domain: name, code: 1) }
            print("PASS", name)
            fflush(stdout)
        }
        try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Tester"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false"),
            ("core.hooksPath", root.appending(path: "no-hooks").path),
        ] { try await git(["config", key, value]) }
        let file = root.appending(path: "file")
        let other = root.appending(path: "other")
        let index = root.appending(path: ".git/index")
        let lock = root.appending(path: ".git/index.lock")
        try Data("a\nb\n".utf8).write(to: file)
        try Data("other\n".utf8).write(to: other)
        try await git(["add", "."])
        try await git(["commit", "-m", "Base"])
        try Data("a\nB\n".utf8).write(to: file)
        let service = try await RepositoryService(
            location: RepositoryService.discover(root, engine: engine), engine: engine)
        func prepare(_ svc: RepositoryService) async throws -> SelectedLinesPlan {
            let diff = try await svc.diff(path: "file", layer: .unstaged)
            let ids = Set(
                diff.hunks.flatMap { $0.lines }.filter { $0.kind == "+" || $0.kind == "-" }.map { $0.id })
            return try await svc.prepareSelectedLines(diff: diff, lineIDs: ids)
        }
        func objects() -> [String] {
            let dir = root.appending(path: ".git/objects")
            return (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).sorted()
        }
        let initialIndex = try Data(contentsOf: index)
        let initialObjects = objects()
        let initialPlan = try await prepare(service)
        try check(
            try Data(contentsOf: index) == initialIndex && objects() == initialObjects,
            "preview preserves raw index and object store")
        try Data("outside edit\n".utf8).write(to: file)
        try check(
            await rejected { try await service.executeSelectedLines(initialPlan) },
            "external work-file edit invalidates confirmation")
        try check(
            try Data(contentsOf: index) == initialIndex && !FileManager.default.fileExists(atPath: lock.path),
            "rejected edit preserves index and removes its lock")
        try Data("a\nB\n".utf8).write(to: file)
        let indexPlan = try await prepare(service)
        try Data("other changed\n".utf8).write(to: other)
        try await git(["add", "other"])
        let changedIndex = try Data(contentsOf: index)
        try check(
            await rejected { try await service.executeSelectedLines(indexPlan) },
            "external staging invalidates confirmation")
        try check(
            try Data(contentsOf: index) == changedIndex && !FileManager.default.fileExists(atPath: lock.path),
            "external staged content is preserved")
        try await git(["reset", "-q", "HEAD", "--", "other"])
        let branchPlan = try await prepare(service)
        try await git(["switch", "-c", "other-branch"])
        let switchIndex = try Data(contentsOf: index)
        try check(
            await rejected { try await service.executeSelectedLines(branchPlan) },
            "same-HEAD branch switch invalidates confirmation")
        try check(try Data(contentsOf: index) == switchIndex, "branch rejection preserves index")
        let lockPlan = try await prepare(service)
        try Data("foreign lock".utf8).write(to: lock)
        try check(
            await rejected { try await service.executeSelectedLines(lockPlan) },
            "foreign index lock blocks execution")
        try check(try Data(contentsOf: lock) == Data("foreign lock".utf8), "foreign lock is never removed")
        try FileManager.default.removeItem(at: lock)
        let gate = Gate()
        let waiting = RepositoryService(
            location: service.location,
            engine: GitEngine(runner: PausingRunner(gate: gate), environment: env), queue: service.queue)
        let concurrentPlan = try await prepare(waiting)
        let executing = Task { try await waiting.executeSelectedLines(concurrentPlan) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.entered), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(await gate.entered, "writer holds index lock before writing object")
        let otherWrite = try await git(["add", "other"], accepted: [0, 128])
        try check(otherWrite.exitCode != 0, "another Git writer cannot acquire index lock")
        await gate.release()
        try await executing.value
        try check(
            try await git(["show", ":file"]).stdout == Data("a\nB\n".utf8),
            "verified candidate installs selected index bytes")
        try check(
            try Data(contentsOf: file) == Data("a\nB\n".utf8)
                && !FileManager.default.fileExists(atPath: lock.path),
            "execution preserves work file and removes lock")
    }
}
