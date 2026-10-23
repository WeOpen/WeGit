import Foundation
import Testing

@testable import WeGitCore

struct FileHistoryTests {
    @Test func renameChainSurvivesPagingAndExcludedRenameMessage() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let old = "旧名\n[1]"
        let new = "新名\n[1]"
        try f.write(old, "one\ntwo\nthree\nfour\n")
        let initial = try await f.commit("Initial [literal]")
        _ = try await f.engine.run(["mv", "--", old, new], in: f.root)
        let rename = try await f.service.commit(message: "Rename", amend: false, expectedHead: initial)
        try f.write(new, "one\ntwo\nthree\nfour\nfive\n")
        let changed = try await f.commit("Change")
        _ = try await f.engine.run(["rm", "--", new], in: f.root)
        let deleted = try await f.service.commit(message: "Delete", amend: false, expectedHead: changed)
        let anchor = try await f.service.fileHistoryAnchor(FileHistoryQuery(path: new))
        var cursor: FileHistoryCursor?
        var rows: [FileHistoryEntry] = []
        repeat {
            let page = try await f.service.fileHistoryPage(anchor, after: cursor, count: 1)
            rows += page.entries
            cursor = page.next
        } while cursor != nil
        #expect(rows.map(\.id) == [deleted, changed, rename, initial])
        #expect(rows.last?.path == old)
        #expect(rows[2].oldPath == old && rows[2].path == new)
        let filtered = try await f.service.fileHistoryAnchor(
            FileHistoryQuery(path: new, message: "[literal]"))
        #expect(try await f.service.fileHistoryPage(filtered).entries.map(\.id) == [initial])
        let comparison = try await f.service.commitComparison(id: rename, paths: [old, new])
        #expect(comparison.files.count == 1 && comparison.files[0].oldPath == old)
    }

    @Test func snapshotPagesDoNotMoveOrWriteWhenHeadChanges() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "a\n")
        let first = try await f.commit()
        try f.write("file", "b\n")
        let second = try await f.commit("Next")
        let anchor = try await f.service.fileHistoryAnchor(FileHistoryQuery(path: "file"))
        let page = try await f.service.fileHistoryPage(anchor, count: 1)
        try f.write("file", "c\n")
        let third = try await f.commit("External")
        let index = f.root.appending(path: ".git/index")
        let indexBytes = try Data(contentsOf: index)
        let next = try await f.service.fileHistoryPage(anchor, after: page.next, count: 1)
        #expect(next.entries.map(\.id) == [first] && next.next == nil)
        #expect(page.entries.map(\.id) == [second])
        let fresh = try await f.service.fileHistoryAnchor(FileHistoryQuery(path: "file"))
        do {
            _ = try await f.service.fileHistoryPage(fresh, after: page.next)
            Issue.record("Cursor must remain attached to one anchor")
        } catch ModelFailure.changed {}
        #expect(try await f.service.head() == third)
        #expect(try Data(contentsOf: index) == indexBytes)
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("c\n".utf8))
    }

    @Test func mergeHistoryIncludesFeatureAndComparesFirstParent() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        _ = try await f.commit()
        _ = try await f.engine.run(["switch", "-c", "feature"], in: f.root)
        try f.write("file", "feature\n")
        let feature = try await f.commit("Feature")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        try f.write("other", "other\n")
        let parent = try await f.commit("Parent")
        _ = try await f.engine.run(["merge", "--no-ff", "feature", "-m", "Merge"], in: f.root)
        let merge = try #require(await f.service.head())
        let anchor = try await f.service.fileHistoryAnchor(FileHistoryQuery(path: "file"))
        let rows = try await f.service.fileHistoryPage(anchor).entries
        #expect(rows.contains { $0.id == feature } && rows.first?.id == merge)
        let comparison = try await f.service.commitComparison(id: merge, paths: ["file"])
        #expect(comparison.parent == parent && comparison.files.map(\.path) == ["file"])
    }

    @Test func invalidQueriesAndTruncatedPathMetadataAreRejected() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        for query in [
            FileHistoryQuery(path: "../outside"), FileHistoryQuery(path: "file", author: "a\0b"),
            FileHistoryQuery(
                path: "file", since: Date(timeIntervalSince1970: 2), until: Date(timeIntervalSince1970: 1)),
        ] {
            do {
                _ = try await f.service.fileHistoryAnchor(query)
                Issue.record("Invalid query was accepted")
            } catch {}
        }
        for raw in [
            Data([0, 1, 2]), Data(("\0" + String(repeating: "a", count: 40) + "\0\0\nR100\0old\0").utf8),
        ] {
            do {
                _ = try FileHistoryParser.parse(raw)
                Issue.record("Truncated path metadata was accepted")
            } catch {}
        }
        let empty = try await f.service.fileHistoryAnchor(FileHistoryQuery(path: "unborn"))
        #expect(try await f.service.fileHistoryPage(empty).entries.isEmpty)
    }
}
