import Foundation
import Testing

@testable import WeGitCore

struct HistoryDepthTests {
    @Test func deepenAndCompleteHistoryPreserveHeadIndexAndDirtyWorkingBytes() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        for value in ["one", "two", "three"] {
            try f.write("file", value + "\n")
            _ = try await f.commit(value)
        }
        let coordinator = CloneCoordinator(engine: f.engine)
        let location = try await coordinator.clone(
            CloneRequest(
                address: f.root.path, parent: f.root, folderName: "shallow",
                options: CloneOptions(depth: 1)))
        let service = RepositoryService(location: location, engine: f.engine)
        let head = try await service.head()
        let index = try Data(contentsOf: location.gitDirectory.appending(path: "index"))
        let working = Data("dirty\r\nlast".utf8)
        try working.write(to: location.root.appending(path: "file"))
        let remote = try #require(try await service.remoteDetails().first)
        _ = try await service.fetchHistoryDepth(
            service.prepareHistoryDepth(remote: remote, change: .deepen(1)))
        #expect(
            try await f.engine.run(["rev-list", "--count", "HEAD"], in: location.root).text
                .removingLastNewline == "2")
        _ = try await service.fetchHistoryDepth(
            service.prepareHistoryDepth(remote: remote, change: .complete))
        #expect(try await service.hasShallowHistory() == false)
        #expect(try await service.head() == head)
        #expect(try Data(contentsOf: location.gitDirectory.appending(path: "index")) == index)
        #expect(try Data(contentsOf: location.root.appending(path: "file")) == working)
    }

    @Test func changedRemoteInvalidatesThePreparedHistoryFetch() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        for value in ["one", "two"] {
            try f.write("file", value)
            _ = try await f.commit(value)
        }
        let location = try await CloneCoordinator(engine: f.engine).clone(
            CloneRequest(
                address: f.root.path, parent: f.root,
                folderName: "shallow", options: CloneOptions(depth: 1)))
        let service = RepositoryService(location: location, engine: f.engine)
        let remote = try #require(try await service.remoteDetails().first)
        let plan = try await service.prepareHistoryDepth(remote: remote, change: .complete)
        let shallow = try Data(contentsOf: location.commonDirectory.appending(path: "shallow"))
        _ = try await f.engine.run(
            ["remote", "set-url", remote.name, "https://example.invalid/changed"], in: location.root)
        await #expect(throws: ModelFailure.self) { _ = try await service.fetchHistoryDepth(plan) }
        #expect(try Data(contentsOf: location.commonDirectory.appending(path: "shallow")) == shallow)
    }
}
