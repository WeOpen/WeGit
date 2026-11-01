import Foundation
import Testing

@testable import WeGitCore

struct SelectedLinesTests {
    @Test func partialReplacementPreservesOtherIndexEntriesAndWorkingBytes() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "a\r\nb\r\nc\r\nd")
        try f.write("other", "original\n")
        let head = try await f.commit()
        try f.write("other", "already staged\n")
        try await f.service.stage(paths: ["other"], expectedHead: head)
        let working = Data("a\r\nB\r\nC\r\nd".utf8)
        try working.write(to: f.root.appending(path: "file"))
        let diff = try await f.service.diff(path: "file", layer: .unstaged)
        let ids = Set(diff.hunks.flatMap(\.lines).filter { ["b\r", "B\r"].contains($0.content) }.map(\.id))
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let plan = try await f.service.prepareSelectedLines(diff: diff, lineIDs: ids)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        try await f.service.executeSelectedLines(plan)
        #expect(
            try await f.engine.run(["show", ":file"], in: f.root).stdout == Data("a\r\nB\r\nc\r\nd".utf8))
        #expect(
            try await f.engine.run(["show", ":other"], in: f.root).stdout == Data("already staged\n".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == working)
        let staged = try await f.service.diff(path: "file", layer: .staged)
        let selected = Set(
            staged.hunks.flatMap(\.lines).filter { $0.kind == "+" || $0.kind == "-" }.map(\.id))
        try await f.service.executeSelectedLines(
            f.service.prepareSelectedLines(diff: staged, lineIDs: selected))
        #expect(
            try await f.engine.run(["show", ":file"], in: f.root).stdout == Data("a\r\nb\r\nc\r\nd".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == working)
        #expect(try await f.service.status().head == head)
    }

    @Test func externalEditRejectsSavedPreviewWithoutChangingIndex() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "old\n")
        _ = try await f.commit()
        try f.write("file", "new\n")
        let diff = try await f.service.diff(path: "file", layer: .unstaged)
        let ids = Set(diff.hunks.flatMap(\.lines).filter { $0.kind == "+" || $0.kind == "-" }.map(\.id))
        let plan = try await f.service.prepareSelectedLines(diff: diff, lineIDs: ids)
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        try f.write("file", "external\n")
        await #expect(throws: ModelFailure.self) { try await f.service.executeSelectedLines(plan) }
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: ".git/index.lock").path))
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("external\n".utf8))
    }
}
