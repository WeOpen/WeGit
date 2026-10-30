import Foundation
import Testing

@testable import WeGitCore

struct ConflictEditorTests {
    @Test func parserPreservesDiff3BytesAndAcceptsBothSides() throws {
        let input =
            "before\r\n<<<<<<< ours\r\nours\r\n||||||| base\r\nbase\r\n=======\r\ntheirs\r\n>>>>>>> theirs\r\nafter"
        let analysis = ConflictMarkerParser.analyze(input)
        let block = try #require(analysis.blocks.first)
        #expect(!analysis.malformed)
        #expect(block.hasBaseSection)
        #expect(
            try ConflictMarkerParser.replacing(text: input, block: block, with: .both)
                == "before\r\nours\r\ntheirs\r\nafter")
        #expect(ConflictMarkerParser.analyze("<<<<<<< ours\nmissing\n>>>>>>>").malformed)
    }

    @Test func mergeSaveLeavesIndexUntilExplicitResolution() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file.txt", "base\n")
        _ = try await fixture.commit("base")
        _ = try await fixture.engine.run(["switch", "-c", "feature"], in: fixture.root)
        try fixture.write("file.txt", "theirs\n")
        _ = try await fixture.commit("theirs")
        _ = try await fixture.engine.run(["switch", "main"], in: fixture.root)
        try fixture.write("file.txt", "ours\n")
        _ = try await fixture.commit("ours")
        _ = try await fixture.engine.run(["merge", "feature"], in: fixture.root, accepted: [0, 1, 128])

        let service = fixture.service
        var document = try await service.readConflictEditor(
            path: "file.txt", expectedHead: try await service.head())
        #expect(document.sequencer == .merge)
        #expect(document.unresolvedBlocks.count == 1)
        let before = try await fixture.engine.run(["ls-files", "--stage", "-z"], in: fixture.root)
        document = try await service.saveConflictResult(document, text: "resolved\n")
        let after = try await fixture.engine.run(["ls-files", "--stage", "-z"], in: fixture.root)
        #expect(before.stdout == after.stdout)
        #expect(try Data(contentsOf: fixture.root.appending(path: "file.txt")) == Data("resolved\n".utf8))
        #expect(!(try await service.status()).conflicts.isEmpty)

        try await service.markConflictResolved(document)
        #expect((try await service.status()).conflicts.isEmpty)
        #expect(
            try await fixture.engine.run(["show", ":file.txt"], in: fixture.root).stdout
                == Data("resolved\n".utf8))
    }

    @Test func externalWorkingFileChangeRejectsSaveWithoutOverwrite() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file.txt", "base\n")
        _ = try await fixture.commit("base")
        _ = try await fixture.engine.run(["switch", "-c", "feature"], in: fixture.root)
        try fixture.write("file.txt", "theirs\n")
        _ = try await fixture.commit("theirs")
        _ = try await fixture.engine.run(["switch", "main"], in: fixture.root)
        try fixture.write("file.txt", "ours\n")
        _ = try await fixture.commit("ours")
        _ = try await fixture.engine.run(["merge", "feature"], in: fixture.root, accepted: [0, 1, 128])

        let service = fixture.service
        let document = try await service.readConflictEditor(
            path: "file.txt", expectedHead: try await service.head())
        try Data("external\n".utf8).write(to: fixture.root.appending(path: "file.txt"))
        await #expect(throws: ModelFailure.self) {
            _ = try await service.saveConflictResult(document, text: "must-not-win\n")
        }
        #expect(
            try Data(contentsOf: fixture.root.appending(path: "file.txt"))
                == Data("external\n".utf8))
    }

    @Test func cancellingQueuedSaveLeavesTheConflictAndReleasesTheRepositoryQueue() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file.txt", "base\n")
        _ = try await fixture.commit("base")
        _ = try await fixture.engine.run(["switch", "-c", "feature"], in: fixture.root)
        try fixture.write("file.txt", "theirs\n")
        _ = try await fixture.commit("theirs")
        _ = try await fixture.engine.run(["switch", "main"], in: fixture.root)
        try fixture.write("file.txt", "ours\n")
        _ = try await fixture.commit("ours")
        _ = try await fixture.engine.run(["merge", "feature"], in: fixture.root, accepted: [0, 1, 128])

        let service = fixture.service
        let document = try await service.readConflictEditor(
            path: "file.txt", expectedHead: try await service.head())
        let gate = ConflictEditorQueueGate()
        let holder = Task {
            try await service.queue.perform {
                await gate.hold()
            }
        }
        while !(await gate.started) { await Task.yield() }

        let save = Task {
            try await service.saveConflictResult(document, text: "cancelled draft\n")
        }
        try await Task.sleep(for: .milliseconds(20))
        save.cancel()
        await #expect(throws: CancellationError.self) { _ = try await save.value }
        await gate.release()
        try await holder.value

        #expect(try Data(contentsOf: fixture.root.appending(path: "file.txt")) == document.result.bytes)
        #expect(!(try await service.status()).conflicts.isEmpty)
        let next = try await service.readConflictEditor(path: "file.txt", expectedHead: document.head)
        #expect(next.result.bytes == document.result.bytes)
    }
}

private actor ConflictEditorQueueGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
