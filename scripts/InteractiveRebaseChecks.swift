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
        func write(_ text: String) throws {
            try Data(text.utf8).write(to: root.appending(path: "file"))
        }
        try write("base\n")
        try await git(["add", "."])
        try await git(["commit", "-m", "Base"])
        try await git(["switch", "-c", "topic"])
        try write("first\n")
        try await git(["commit", "-am", "First"])
        let first = try await git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        try write("second\n")
        try await git(["commit", "-am", "Second"])
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
        let adjusted = prepared.replacing(
            steps: prepared.steps.map { step in
                InteractiveRebaseStep(
                    id: step.id, subject: step.subject, author: step.author,
                    action: step.id == first ? .reword : .drop,
                    message: step.id == first ? "Renamed First\n" : nil)
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
                .trimmingCharacters(in: .whitespacesAndNewlines) == "Renamed First",
            "reword did not update the commit message")
        try require(try await git(["show", "HEAD:file"]).text == "first\n", "replayed file content changed")
        try require(try await git(["status", "--porcelain"]).text.isEmpty, "worktree is not clean")
        print("PASS interactive rebase prepare/drop/reword/clean state (4 checks)")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.assertion(message) }
    }
}
