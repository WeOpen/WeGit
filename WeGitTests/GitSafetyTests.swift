import Foundation
import Testing

@testable import WeGitCore

private actor ReplaceAfterPatchCheck: ProcessRunning {
    let root: URL
    let moved: URL
    private var replaced = false
    init(root: URL, moved: URL) {
        self.root = root
        self.moved = moved
    }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await ProcessRunner().run(request)
        if !replaced && request.arguments.contains("apply") && request.arguments.contains("--check") {
            replaced = true
            try FileManager.default.moveItem(at: root, to: moved)
            _ = try await ProcessRunner().run(
                ProcessRequest(
                    executable: request.executable, arguments: ["clone", moved.path, root.path],
                    environment: request.environment))
        }
        return result
    }
}

private struct CancelAfterCommitRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await ProcessRunner().run(request)
        if request.arguments.contains("commit"), result.exitCode == 0 { throw ProcessFailure.cancelled }
        return result
    }
}

struct GitSafetyTests {
    @Test func interruptedCommitReportsAnObservedHeadWithoutClaimingRollback() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let base = try await f.commit()
        try f.write("file", "committed change\n")
        try await f.service.stage(paths: ["file"], expectedHead: base)
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: CancelAfterCommitRunner(), environment: f.engine.environment))
        do {
            _ = try await service.commit(
                message: "Completed before cancellation", amend: false, expectedHead: base)
            Issue.record("The transport reported an interrupted outcome")
        } catch let error as CommitOutcomeUnknown {
            #expect(error.previousHead == base)
            #expect(error.observedHead == (try await f.service.head()))
            #expect(error.observedHead != base)
        }
        #expect(try await f.engine.run(["rev-list", "--count", "HEAD"], in: f.root).text == "2\n")
        #expect(try await f.service.status().files.isEmpty)
    }

    @Test func replacingTheRepositoryAfterPatchPreflightStopsTheActualWrite() async throws {
        let f = try await Fixture.create()
        let moved = f.root.appendingPathExtension("after-check")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: moved)
        }
        try f.write("file", "old\n")
        _ = try await f.commit()
        try f.write("file", "new\n")
        let runner = ReplaceAfterPatchCheck(root: f.root, moved: moved)
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: runner, environment: f.engine.environment)
        )
        let diff = try await service.diff(path: "file", layer: .unstaged)
        await #expect(throws: ModelFailure.self) { try await service.apply(hunk: diff.hunks[0], from: diff) }
        #expect(try await f.engine.run(["diff", "--cached"], in: f.root).stdout.isEmpty)
        #expect(try String(contentsOf: f.root.appending(path: "file"), encoding: .utf8) == "old\n")
    }

    @Test func samePathReplacementWithIdenticalHeadCannotUseTheOldSession() async throws {
        let f = try await Fixture.create()
        let moved = f.root.appendingPathExtension("moved")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: moved)
        }
        try f.write("file.txt", "original\n")
        let head = try await f.commit()
        let service = f.service.expectingBranch("main")
        try FileManager.default.moveItem(at: f.root, to: moved)
        _ = try await f.engine.run(["clone", moved.path, f.root.path])
        try f.write("file.txt", "replacement checkout\n")
        await #expect(throws: ModelFailure.self) {
            try await service.stage(paths: ["file.txt"], expectedHead: head)
        }
        await #expect(throws: ModelFailure.self) {
            _ = try await service.commit(message: "wrong repository", amend: false, expectedHead: head)
        }
        await #expect(throws: ModelFailure.self) { _ = try await service.status() }
        #expect(try await f.engine.run(["diff", "--cached"], in: f.root).stdout.isEmpty)
        #expect(try await f.engine.run(["rev-parse", "HEAD"], in: f.root).text.removingLastNewline == head)
        let reopened = try await RepositoryService.discover(f.root, engine: f.engine)
        #expect(!reopened.isSameRepository(as: service.location))
        #expect(reopened.persistenceID != service.location.persistenceID)
        let current = RepositoryService(location: reopened, engine: f.engine)
        try await current.stage(paths: ["file.txt"], expectedHead: head)
        #expect(try await f.engine.run(["show", ":file.txt"], in: f.root).text == "replacement checkout\n")
    }

    @Test func movedRepositoryKeepsEntityIdentityButRequiresItsNewPath() async throws {
        let f = try await Fixture.create()
        let moved = f.root.appendingPathExtension("relocated")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: moved)
        }
        try f.write("file", "content\n")
        _ = try await f.commit()
        try FileManager.default.moveItem(at: f.root, to: moved)
        await #expect(throws: ModelFailure.self) { _ = try await f.service.head() }
        let location = try await RepositoryService.discover(moved, engine: f.engine)
        #expect(location.isSameRepository(as: f.service.location))
        #expect(location.persistenceID == f.service.location.persistenceID)
        #expect(try await RepositoryService(location: location, engine: f.engine).status().files.isEmpty)
    }

    @Test func changedGitFilePointerInvalidatesTheCapturedRepository() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "content\n")
        _ = try await f.commit()
        let checkout = f.root.appending(path: "separate-worktree")
        let metadata = f.root.appending(path: "separate-metadata")
        let copy = f.root.appending(path: "copied-metadata")
        _ = try await f.engine.run([
            "clone", "--separate-git-dir=" + metadata.path, f.root.path, checkout.path,
        ])
        let location = try await RepositoryService.discover(checkout, engine: f.engine)
        try FileManager.default.copyItem(at: metadata, to: copy)
        try Data("gitdir: \(copy.path)\n".utf8).write(to: checkout.appending(path: ".git"))
        await #expect(throws: ModelFailure.self) {
            _ = try await RepositoryService(location: location, engine: f.engine).status()
        }
        #expect(
            try await f.engine.run(["rev-parse", "HEAD"], in: checkout).text
                == f.engine.run(["rev-parse", "HEAD"], in: f.root).text)
    }

    @Test func diagnosticRedactionRemovesWholeAuthenticationValues() {
        let input = """
            fatal: authentication failed
            Authorization: Bearer sample-bearer-secret
            Proxy-Authorization: Basic sample-base64-secret
            authorization:
              Bearer folded-secret
            password='two word secret' reason=denied
            {"client_secret": "quoted secret", "message": "failed"}
            https://person:sample-url-secret@example.invalid/repo
            access_token=sample-access-secret
            private_token=sample-private-secret
            """
        let output = Redaction.text(input)
        for secret in [
            "sample-bearer-secret", "sample-base64-secret", "folded-secret", "two word secret",
            "quoted secret", "sample-url-secret", "sample-access-secret", "sample-private-secret",
        ] {
            #expect(!output.contains(secret))
        }
        #expect(output.contains("fatal: authentication failed"))
        #expect(output.contains("reason=denied"))
        #expect(output.contains("https://[redacted]@example.invalid/repo"))
    }
}
