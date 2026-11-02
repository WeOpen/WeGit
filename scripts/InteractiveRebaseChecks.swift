import Foundation
import WeGitCore

@main struct InteractiveRebaseChecks {
    enum Failure: Error { case assertion(String) }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "WeGitInteractive-\(UUID())")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let engine = GitEngine(environment: environment)
        @discardableResult func git(_ args: [String]) async throws -> ProcessResult {
            try await engine.run(args, in: root, timeout: 60)
        }
        try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Interactive Check"),
            ("user.email", "interactive@example.invalid"),
            ("commit.gpgsign", "false"),
        ] {
            try await git(["config", key, value])
        }
        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: root.appending(path: path))
        }
        try write("base.txt", "base\n")
        try await git(["add", "."])
        try await git(["commit", "-m", "Base"])
        try await git(["switch", "-c", "topic"])
        try write("first.txt", "first\n")
        try await git(["add", "first.txt"])
        try await git(["commit", "-m", "First"])
        let first = try await git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        try write("second.txt", "second\n")
        try await git(["add", "second.txt"])
        try await git(["commit", "-m", "Second"])
        let second = try await git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        try await git(["switch", "main"])
        let location = try await RepositoryService.discover(root, engine: engine)
        let service = RepositoryService(location: location, engine: engine)
        guard let upstream = try await service.branches().first(where: { $0.name == "main" }) else {
            throw Failure.assertion("missing main branch")
        }
        try await git(["switch", "topic"])
        let prepared: InteractiveRebasePlan
        do {
            prepared = try await service.prepareInteractiveRebase(upstream: upstream)
            FileHandle.standardError.write(Data("prepared ids: \(prepared.steps.map { $0.id })\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("prepare error: \(error)\n".utf8))
            throw error
        }
        let preparedIDs = prepared.steps.map { $0.id }
        try require(preparedIDs == [first, second], "prepare did not capture linear steps")
        let allDropped = prepared.replacing(
            steps: prepared.steps.map {
                InteractiveRebaseStep(id: $0.id, subject: $0.subject, author: $0.author, action: .drop)
            })
        do {
            _ = try await service.executeInteractiveRebase(allDropped)
            throw Failure.assertion("all-drop sequence was accepted")
        } catch is ModelFailure {}
        try require(
            try await git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
                == prepared.head,
            "all-drop rejection changed HEAD")
        try require(
            try await git(["status", "--porcelain"]).text.isEmpty, "all-drop rejection changed files")

        let reordered = prepared.replacing(steps: Array(prepared.steps.reversed()))
        guard case .completed = try await service.executeInteractiveRebase(reordered) else {
            throw Failure.assertion("reordered picks did not complete")
        }
        let reorderedMessages = try await git(
            ["log", "--reverse", "--format=%s", upstream.oid + "..HEAD"])
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
        try require(reorderedMessages == "Second\nFirst", "pick order was not preserved")
        try require(try await git(["show", "HEAD:first.txt"]).text == "first\n", "first path was lost")
        try require(try await git(["show", "HEAD:second.txt"]).text == "second\n", "second path was lost")

        let reorderedPlan = try await service.prepareInteractiveRebase(upstream: upstream)
        let firstInSequence = try requireValue(reorderedPlan.steps.first?.id, "missing reordered step")
        let adjusted = reorderedPlan.replacing(
            steps: reorderedPlan.steps.map { step in
                InteractiveRebaseStep(
                    id: step.id, subject: step.subject, author: step.author,
                    action: step.id == firstInSequence ? .reword : .drop,
                    message: step.id == firstInSequence ? "Renamed Second\n" : nil)
            })
        do {
            guard case .completed = try await service.executeInteractiveRebase(adjusted) else {
                throw Failure.assertion("interactive rebase did not complete")
            }
        } catch {
            let status = try? await git(["status", "--porcelain=v2", "--branch"]).text
            let details = (error as? GitFailure)?.details ?? error.localizedDescription
            FileHandle.standardError.write(
                Data("interactive execution error: \(details)\nstatus:\n\(status ?? "<unavailable>")\n".utf8))
            throw error
        }
        try require(
            try await git(["rev-list", "--count", upstream.oid + "..HEAD"]).text
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1",
            "drop did not remove the selected commit")
        try require(
            try await git(["log", "-1", "--format=%s"]).text
                .trimmingCharacters(in: .whitespacesAndNewlines) == "Renamed Second",
            "reword did not update the commit message")
        try require(
            try await git(["show", "HEAD:second.txt"]).text == "second\n", "replayed content changed")
        try require(
            try await git(["ls-tree", "-r", "--name-only", "HEAD"]).text
                .trimmingCharacters(in: .whitespacesAndNewlines) == "base.txt\nsecond.txt",
            "drop retained the dropped path")
        try require(try await git(["status", "--porcelain"]).text.isEmpty, "worktree is not clean")
        print("PASS interactive rebase prepare/reject-all-drop/reorder/drop/reword/clean state (9 checks)")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.assertion(message) }
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure.assertion(message) }
        return value
    }
}
