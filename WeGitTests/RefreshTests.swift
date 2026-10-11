import CoreServices
import Foundation
import Testing

@testable import WeGitCore

private actor SnapshotRunner: ProcessRunning {
    enum Interference { case none, once, continuously }
    let interference: Interference
    private(set) var commands: [[String]] = []
    private var changes = 0
    init(_ interference: Interference = .none) { self.interference = interference }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        commands.append(request.arguments)
        let result = try await ProcessRunner().run(request)
        if request.arguments.contains("status"),
            interference == .continuously || (interference == .once && changes == 0)
        {
            changes += 1
            var mutation = request
            mutation.arguments = ["switch", "-c", "changed-\(changes)"]
            _ = try await ProcessRunner().run(mutation)
        }
        return result
    }
}

struct RefreshTests {
    @Test func fileEventsMergeScopesAndIgnoreObjectStorage() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let root = f.service.location.root.path
        let git = f.service.location.gitDirectory.path
        let paths = [root + "/空 格/文件.txt", git + "/index", git + "/objects/ab/object"]
        #expect(
            RepositoryRefreshScope.events(paths: paths, flags: [0, 0, 0], location: f.service.location) == [
                .status, .diff,
            ])
        #expect(
            RepositoryRefreshScope.events(
                paths: [git + "/refs/heads/main"], flags: [0], location: f.service.location)
                == [.status, .references, .history, .diff])
        #expect(
            RepositoryRefreshScope.events(paths: [git + "/config"], flags: [0], location: f.service.location)
                == .all)
        #expect(
            RepositoryRefreshScope.events(
                paths: [git + "/refs/wegit/pull/temporary"], flags: [0], location: f.service.location
            ).isEmpty)
        #expect(
            RepositoryRefreshScope.events(paths: [root], flags: [0], location: f.service.location) == .all)
        #expect(
            RepositoryRefreshScope.events(
                paths: [root + "/file"],
                flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)],
                location: f.service.location) == .all)
        #expect(
            RepositoryRefreshScope.events(
                paths: [root + "-different/file"], flags: [0], location: f.service.location) == .all)
        #expect(RepositoryRefreshScope.events(paths: [root], flags: [], location: f.service.location) == .all)
    }

    @Test func worktreeRefreshDoesNotRescanReferencesAndRemoteConfiguration() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let head = try await f.commit()
        try f.write("file", "changed\n")
        let runner = SnapshotRunner()
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: runner, environment: f.engine.environment))
        let snapshot = try await service.readSnapshot(
            scope: [.status, .diff], previousHead: head, previousBranch: "main")
        #expect(snapshot.status.files.count == 1)
        #expect(snapshot.branches == nil && snapshot.remotes == nil)
        #expect(await runner.commands.allSatisfy { !$0.contains("for-each-ref") && !$0.contains("remote") })
    }

    @Test func branchSwitchDuringReadRetriesEvenWhenTheCommitIsUnchanged() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let head = try await f.commit()
        let runner = SnapshotRunner(.once)
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: runner, environment: f.engine.environment))
        let snapshot = try await service.readSnapshot(
            scope: [.status, .diff], previousHead: head, previousBranch: "main")
        #expect(snapshot.status.head == head && snapshot.status.branch == "changed-1")
        #expect(snapshot.branches?.first { $0.current }?.name == "changed-1")
        #expect(snapshot.scope.contains(.history) && snapshot.scope.contains(.references))
        #expect(await runner.commands.filter { $0.contains("status") }.count == 2)
    }

    @Test func continuousExternalChangesFailRatherThanPublishAMixedSnapshot() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        _ = try await f.commit()
        let runner = SnapshotRunner(.continuously)
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: runner, environment: f.engine.environment))
        await #expect(throws: ModelFailure.self) { _ = try await service.readSnapshot() }
        #expect(await runner.commands.filter { $0.contains("status") }.count == 3)
    }

    @Test func snapshotSupportsUnbornAndDetachedHeads() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let unborn = try await f.service.readSnapshot()
        #expect(
            unborn.status.head == nil && unborn.status.branch == "main" && unborn.branches?.isEmpty == true)
        try f.write("file", "base\n")
        let head = try await f.commit()
        try await f.service.checkoutCommit(head, expectedHead: head)
        let detached = try await f.service.readSnapshot()
        #expect(detached.status.isDetached && detached.status.head == head)
    }
}
