import Foundation
import Testing

@testable import WeGitCore

private final class CloneProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CloneProgress] = []
    private var didStart = false
    var progress: [CloneProgress] { lock.withLock { values } }
    var started: Bool { lock.withLock { didStart } }
    func append(_ value: CloneProgress) { lock.withLock { values.append(value) } }
    func start() { lock.withLock { didStart = true } }
}

private struct InterruptedCloneRunner: ProcessRunning {
    let probe: CloneProbe
    var waitForCancellation = false
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        guard request.arguments.contains("clone"), let path = request.arguments.last else {
            throw ProcessFailure.launch(22)
        }
        let directory = URL(fileURLWithPath: path)
        try Data("partial clone".utf8).write(to: directory.appending(path: "partial.pack"))
        request.onStderr?(Data("Receiving objects:  25% (1/4)\r".utf8))
        probe.start()
        if waitForCancellation { try await Task.sleep(for: .seconds(30)) }
        return ProcessResult(
            stdout: Data(), stderr: Data("fatal: test clone interrupted\n".utf8), exitCode: 128,
            duration: 0.01)
    }
}

private struct FixtureTrash: FileTrashing {
    let destination: URL
    func moveToTrash(_ url: URL) throws -> URL? {
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

struct CloneTests {
    @Test func progressHandlesFragmentedCarriageReturnsAndIgnoresSecrets() {
        var parser = CloneProgressParser()
        #expect(parser.consume(Data("remote: Count".utf8)).isEmpty)
        #expect(
            parser.consume(Data("ing objects:  17% (17/100)\r".utf8)) == [
                CloneProgress(stage: .counting, fraction: 0.17)
            ])
        #expect(parser.consume(Data("Counting objects: 17% (17/100)\r\n".utf8)).isEmpty)
        let next = parser.consume(
            Data("Receiving objects: 100% (4/4), done.\rResolving deltas: 42% (2/5)\r".utf8))
        #expect(
            next == [
                CloneProgress(stage: .receiving, fraction: 1),
                CloneProgress(stage: .resolving, fraction: 0.42),
            ])
        #expect(
            parser.consume(
                Data("password=not-a-real-secret\nfatal: failed https://token@example.invalid\n".utf8)
            ).isEmpty)
        #expect(
            parser.consume(Data("Updating files: 200% nonsense\r".utf8)) == [
                CloneProgress(stage: .checkingOut)
            ])
    }

    @Test func cloneRealRepositoryAndValidateResult() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("hello.txt", "real clone\n")
        let head = try await f.commit()
        let probe = CloneProbe()
        let coordinator = CloneCoordinator(engine: f.engine)
        let result = try await coordinator.clone(
            CloneRequest(
                address: f.root.absoluteString,
                parent: f.root, folderName: "克隆 with spaces"), onProgress: probe.append)
        #expect(result.root.lastPathComponent == "克隆 with spaces")
        #expect(
            try String(contentsOf: result.root.appending(path: "hello.txt"), encoding: .utf8)
                == "real clone\n")
        #expect(try await RepositoryService(location: result, engine: f.engine).head() == head)
        #expect(probe.progress.first?.stage == .connecting)
        #expect(probe.progress.last?.stage == .validating)
    }

    @Test func neverTakesOverExistingFileDirectoryOrSymlink() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let probe = CloneProbe()
        let coordinator = CloneCoordinator(
            engine: TestGit.engine(runner: InterruptedCloneRunner(probe: probe)))
        try FileManager.default.createDirectory(
            at: f.root.appending(path: "empty"), withIntermediateDirectories: false)
        try f.write("existing", "keep this file")
        try FileManager.default.createSymbolicLink(
            atPath: f.root.appending(path: "alias").path,
            withDestinationPath: f.root.appending(path: "empty").path)
        for name in ["empty", "existing", "alias"] {
            await #expect(throws: ModelFailure.self) {
                _ = try await coordinator.clone(
                    CloneRequest(
                        address: "https://example.invalid/repo.git", parent: f.root, folderName: name))
            }
        }
        #expect(!probe.started)
        #expect(
            try String(contentsOf: f.root.appending(path: "existing"), encoding: .utf8) == "keep this file")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: f.root.appending(path: "empty").path).isEmpty)
    }

    @Test func credentialsAndInvalidNamesRejectedBeforeStarting() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        for address in [
            "-bad", "https://token@example.invalid/repo", "HTTPS://user:password@example.invalid/repo",
            "https://example.invalid/repo?access_token=secret", "bad\0address",
        ] {
            #expect(throws: ModelFailure.self) {
                _ = try CloneRequest(address: address, parent: f.root, folderName: "clone")
                    .validatedDestination()
            }
        }
        for name in ["", ".", "..", "../other", "name\0bad"] {
            #expect(throws: ModelFailure.self) {
                _ = try CloneRequest(
                    address: "git@example.invalid:repo.git", parent: f.root, folderName: name
                ).validatedDestination()
            }
        }
        #expect(
            try CloneRequest(address: "git@example.invalid:repo.git", parent: f.root, folderName: "valid")
                .validatedDestination().lastPathComponent == "valid")
    }

    @Test func failedCloneCanOnlyMoveItsOwnUnchangedDirectory() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let coordinator = CloneCoordinator(
            engine: TestGit.engine(runner: InterruptedCloneRunner(probe: CloneProbe())),
            trash: FixtureTrash(destination: f.root.appending(path: "test-trash")))
        let failure = try await interrupted(coordinator, parent: f.root)
        let token = try #require(failure.cleanup)
        #expect(FileManager.default.fileExists(atPath: token.directory.appending(path: "partial.pack").path))
        _ = try await coordinator.cleanUp(token)
        #expect(!FileManager.default.fileExists(atPath: token.directory.path))
        #expect(
            try String(contentsOf: f.root.appending(path: "test-trash/partial.pack"), encoding: .utf8)
                == "partial clone")
        await #expect(throws: ModelFailure.self) { _ = try await coordinator.cleanUp(token) }
    }

    @Test func cleanupRefusesNewFilesAndReplacedDirectories() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let coordinator = CloneCoordinator(
            engine: TestGit.engine(runner: InterruptedCloneRunner(probe: CloneProbe())),
            trash: FixtureTrash(destination: f.root.appending(path: "test-trash")))
        let failure = try await interrupted(coordinator, parent: f.root)
        let token = try #require(failure.cleanup)
        try Data("user work".utf8).write(to: token.directory.appending(path: "new.txt"))
        await #expect(throws: ModelFailure.self) { _ = try await coordinator.cleanUp(token) }
        try FileManager.default.moveItem(at: token.directory, to: f.root.appending(path: "preserved"))
        try FileManager.default.createDirectory(at: token.directory, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: token.directory.appending(path: "partial.pack"))
        await #expect(throws: ModelFailure.self) { _ = try await coordinator.cleanUp(token) }
        #expect(
            try String(contentsOf: token.directory.appending(path: "partial.pack"), encoding: .utf8)
                == "replacement")
        #expect(
            try String(contentsOf: f.root.appending(path: "preserved/new.txt"), encoding: .utf8)
                == "user work")
    }

    @Test func cancellingCloneRetainsRecoveryAndRejectsConcurrentStart() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let probe = CloneProbe()
        let coordinator = CloneCoordinator(
            engine: TestGit.engine(runner: InterruptedCloneRunner(probe: probe, waitForCancellation: true)))
        let request = CloneRequest(
            address: "https://example.invalid/repo.git", parent: f.root, folderName: "partial")
        let task = Task { try await coordinator.clone(request, onProgress: probe.append) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !probe.started && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(probe.started)
        await #expect(throws: ModelFailure.self) { _ = try await coordinator.clone(request) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled clone unexpectedly succeeded")
        } catch let error as CloneFailure {
            #expect(error.message.contains("取消"))
            #expect(error.cleanup != nil)
            #expect(
                FileManager.default.fileExists(atPath: f.root.appending(path: "partial/partial.pack").path))
        }
        #expect(probe.progress.contains(CloneProgress(stage: .receiving, fraction: 0.25)))
    }

    private func interrupted(_ coordinator: CloneCoordinator, parent: URL) async throws -> CloneFailure {
        do {
            _ = try await coordinator.clone(
                CloneRequest(
                    address: "https://example.invalid/repo.git", parent: parent, folderName: "partial"))
            throw ModelFailure.unsupported("Expected fixture to fail")
        } catch let failure as CloneFailure { return failure }
    }
}

private struct ActivityFailureRunner: ProcessRunning {
    let error: ProcessFailure
    func run(_ request: ProcessRequest) async throws -> ProcessResult { throw error }
}

struct ActivityOutcomeTests {
    @Test func activityIdentifiesRepositoriesWithoutStoringCommandArguments() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let store = ActivityStore()
        let engine = TestGit.engine(activity: store, environment: f.engine.environment)
        _ = try await engine.run(["status", "--porcelain=v2"], in: f.root)
        let target = f.root.appending(path: "clone-target")
        let failing = TestGit.engine(runner: ActivityFailureRunner(error: .cancelled), activity: store)
        do {
            _ = try await failing.run(
                ["clone", "https://example.invalid/secret-path", target.path], activityRepository: target)
        } catch {}
        let records = await store.all()
        #expect(records.map(\.repository) == [target, f.root])
        #expect(records.map(\.command) == ["git clone", "git status"])
        #expect(
            records.allSatisfy { !$0.command.contains("secret-path") && !$0.details.contains("secret-path") })
    }

    @Test func cancelledAndTimedOutOperationsAreRecordedWithoutInventedExitCodes() async {
        for failure in [ProcessFailure.cancelled, .timedOut, .launch(2)] {
            let store = ActivityStore()
            let engine = TestGit.engine(runner: ActivityFailureRunner(error: failure), activity: store)
            do {
                _ = try await engine.run(["clone", "https://example.invalid/repo.git"])
                Issue.record("Expected failure")
            } catch {}
            let entries = await store.all()
            #expect(entries.count == 1)
            #expect(entries[0].exitCode == nil)
            #expect(entries[0].command == "git clone")
            switch failure {
            case .cancelled: #expect(entries[0].state == .cancelled)
            case .timedOut: #expect(entries[0].state == .timedOut)
            default: #expect(entries[0].state == .failed)
            }
        }
    }
}
