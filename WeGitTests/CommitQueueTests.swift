import Foundation
import Testing

@testable import WeGitCore

struct CommitQueueTests {
    @Test func orderedQueueCommitsAndRevertsWithPinnedSourceReferences() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("base", "base\n")
        let base = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "source"], in: f.root)
        try f.write("one", "one\r\nlast")
        let one = try await f.commit("One")
        try f.write("two", "two\n")
        let two = try await f.commit("Two")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        let originalIndex = try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index"))
        let plan = try await f.service.prepareCommitQueue(
            .cherryPick,
            selections: [CommitQueueSelection(target: one), CommitQueueSelection(target: two)])
        #expect(try await f.service.head() == base)
        #expect(
            try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index")) == originalIndex)
        let completed = try await f.service.executeCommitQueue(plan)
        #expect(completed.phase == .completed && completed.next == 2)
        #expect(completed.items.allSatisfy { $0.state == .committed && $0.result != nil })
        #expect(try Data(contentsOf: f.root.appending(path: "one")) == Data("one\r\nlast".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: "two")) == Data("two\n".utf8))
        let reopened = RepositoryService(location: f.service.location, engine: f.engine)
        #expect(try await reopened.commitQueue() == completed)
        try await reopened.closeCommitQueue(completed)
        #expect(try await reopened.commitQueue() == nil)
        let revert = try await f.service.prepareCommitQueue(
            .revert,
            selections: [CommitQueueSelection(target: two), CommitQueueSelection(target: one)])
        let reverted = try await f.service.executeCommitQueue(revert)
        #expect(reverted.phase == .completed)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "one").path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "two").path))
        #expect(try Data(contentsOf: f.root.appending(path: "base")) == Data("base\n".utf8))
    }

    @Test func conflictSkipRetainsEarlierCommitsAndReopenContinuesRemainingOrder() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        _ = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "source"], in: f.root)
        try f.write("one", "one\n")
        let one = try await f.commit("One")
        try f.write("file", "source conflict\n")
        let conflict = try await f.commit("Conflict")
        try f.write("three", "three\n")
        let three = try await f.commit("Three")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        try f.write("file", "target conflict\n")
        let head = try await f.commit("Target")
        let plan = try await f.service.prepareCommitQueue(
            .cherryPick,
            selections: [one, conflict, three].map { CommitQueueSelection(target: $0) })
        let stopped = try await f.service.executeCommitQueue(plan)
        #expect(stopped.phase == .waiting && stopped.next == 1)
        #expect(stopped.items[0].state == .committed)
        #expect(try await f.service.head() != head)
        let reopened = RepositoryService(location: f.service.location, engine: f.engine)
        #expect(try await reopened.commitQueue() == stopped)
        let completed = try await reopened.skipCommitQueueItem(stopped)
        #expect(completed.phase == .completed && completed.next == 3)
        #expect(completed.items[1].state == .skipped && completed.items[2].state == .committed)
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("target conflict\n".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: "one")) == Data("one\n".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: "three")) == Data("three\n".utf8))
        #expect(
            try await reopened.recoveryRecords().contains {
                $0.operation == "commit-queue-interruption-backup"
            })
    }

    @Test func mergeCommitNeedsAnExplicitParentAndAppliesThatParentsDifference() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("base", "base\n")
        let base = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "feature"], in: f.root)
        try f.write("feature", "feature\n")
        _ = try await f.commit("Feature")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        try f.write("main", "main\n")
        let before = try await f.commit("Main")
        _ = try await f.engine.run(["merge", "--no-ff", "feature", "-m", "Merge"], in: f.root)
        let merge = try #require(await f.service.head())
        _ = try await f.engine.run(["reset", "--hard", before], in: f.root)
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.prepareSingleCommit(.cherryPick, target: merge)
        }
        let selected = try await f.service.prepareSingleCommit(.cherryPick, target: merge, mainline: 1)
        #expect(selected.mainline == 1 && selected.files.map(\.path) == ["feature"])
        _ = try await f.service.executeSingleCommit(selected)
        #expect(try Data(contentsOf: f.root.appending(path: "feature")) == Data("feature\n".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: "main")) == Data("main\n".utf8))
        #expect(base != merge)
    }
}
