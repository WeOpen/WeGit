import Foundation
import Testing

@testable import WeGitCore

struct DiffContextTests {
    @Test func contextPagesMapZeroLengthHunksCRLFAndFinalLine() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let original = (1...70).map { "第 \($0) 行" }.joined(separator: "\r\n")
        try f.write("file.txt", original)
        _ = try await f.commit()
        let changed = original.replacingOccurrences(of: "第 20 行\r\n", with: "第 20 行\r\n插入一\r\n插入二\r\n")
            .replacingOccurrences(of: "第 50 行", with: "修改第 50 行")
        try f.write("file.txt", changed)
        let diff = try await f.service.diff(
            path: "file.txt", layer: .unstaged, options: DiffReadOptions(contextLines: 0))
        let gaps = DiffContextGap.gaps(for: diff)
        #expect(gaps.count == 3)
        let reader = DiffContextReader(diff: diff, service: f.service)
        let before = try await reader.page(for: gaps[0], offset: 0, limit: 5)
        #expect(before.lines.first?.oldLine == 16 && before.lines.last?.oldLine == 20)
        #expect(before.lines.first?.content == "第 16 行\r")
        #expect(before.hasMore && before.consumedLines == 5)
        let earlier = try await reader.page(for: gaps[0], offset: 5, limit: 20)
        #expect(earlier.lines.first?.oldLine == 1 && earlier.lines.last?.oldLine == 15)
        #expect(!earlier.hasMore)
        let middle = try await reader.page(for: gaps[1], offset: 0)
        #expect(middle.lines.first?.oldLine == 21 && middle.lines.first?.newLine == 23)
        #expect(middle.lines.last?.oldLine == 40 && middle.hasMore)
        let middleEnd = try await reader.page(for: gaps[1], offset: 20)
        #expect(middleEnd.lines.first?.oldLine == 41 && middleEnd.lines.last?.oldLine == 49)
        #expect(!middleEnd.hasMore)
        let tail = try await reader.page(for: gaps[2], offset: 0)
        #expect(tail.consumedLines == 20 && !tail.hasMore)
        #expect(tail.lines.first?.oldLine == 51 && tail.lines.first?.newLine == 53)
        #expect(tail.lines[19].content == "第 70 行" && tail.lines.last?.kind == "\\")
        let expanded = earlier.lines + before.lines + middle.lines + middleEnd.lines + tail.lines
        #expect(expanded.allSatisfy { $0.id < 0 })
        #expect(Set(expanded.map(\.id)).count == expanded.count)
        #expect(
            diff.raw
                == (try await f.service.diff(path: "file.txt", layer: .unstaged, options: diff.options)).raw)
    }

    @Test func contextUsesTheCapturedIndexBlobEvenAfterFurtherEdits() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let initial = (1...80).map { "line \($0)\n" }.joined()
        try f.write("file.txt", initial)
        let head = try await f.commit()
        let staged = initial.replacingOccurrences(of: "line 1\n", with: "already staged\n")
        try f.write("file.txt", staged)
        try await f.service.stage(paths: ["file.txt"], expectedHead: head)
        try f.write("file.txt", staged.replacingOccurrences(of: "line 40\n", with: "working change\n"))
        let snapshot = try await f.service.diff(path: "file.txt", layer: .unstaged)
        let gap = try #require(DiffContextGap.gaps(for: snapshot).first)
        try f.write("file.txt", initial.replacingOccurrences(of: "line 1\n", with: "later contents\n"))
        try await f.service.stage(paths: ["file.txt"], expectedHead: head)
        let reader = DiffContextReader(diff: snapshot, service: f.service)
        let page = try await reader.page(for: gap, offset: 0, limit: 200)
        #expect(page.lines.first?.content == "already staged")
        await #expect(throws: ModelFailure.self) {
            try await f.service.apply(hunk: snapshot.hunks[0], from: snapshot)
        }
    }

    @Test func expansionAndPagingNeverChangeTheHunkAppliedToTheIndex() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let original = (1...100).map { "line \($0)\n" }.joined()
        try f.write("file.txt", original)
        _ = try await f.commit()
        let first = original.replacingOccurrences(of: "line 30\n", with: "first edit\n")
        let both = first.replacingOccurrences(of: "line 70\n", with: "second edit\n")
        try f.write("file.txt", both)
        let diff = try await f.service.diff(path: "file.txt", layer: .unstaged)
        let raw = diff.raw
        let reader = DiffContextReader(diff: diff, service: f.service)
        for gap in DiffContextGap.gaps(for: diff) { _ = try await reader.page(for: gap, offset: 0) }
        let document = try await DiffDisplayDocument.prepare(diff, split: true)
        _ = try await document.page(from: 0)
        #expect(diff.raw == raw && diff.hunks.count == 2)
        try await f.service.apply(hunk: diff.hunks[0], from: diff)
        #expect(try await f.engine.run(["show", ":file.txt"], in: f.root).text == first)
        #expect(try String(contentsOf: f.root.appending(path: "file.txt"), encoding: .utf8) == both)
        let staged = try await f.service.diff(path: "file.txt", layer: .staged)
        let stagedReader = DiffContextReader(diff: staged, service: f.service)
        let prefix = try #require(DiffContextGap.gaps(for: staged).first)
        #expect(try await stagedReader.page(for: prefix, offset: 0).lines.last?.content == "line 26")
    }

    @Test func whitespaceFilteredDiffHasNoExpandersAndEmptyTailEndsCleanly() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file.txt", "one\ntwo\nthree\n")
        _ = try await f.commit()
        try f.write("file.txt", "one\ntwo\nchanged\n")
        let filtered = try await f.service.diff(
            path: "file.txt", layer: .unstaged, options: DiffReadOptions(ignoreWhitespace: true))
        #expect(DiffContextGap.gaps(for: filtered).isEmpty)
        let diff = try await f.service.diff(path: "file.txt", layer: .unstaged)
        let gap = try #require(DiffContextGap.gaps(for: diff).last)
        let reader = DiffContextReader(diff: diff, service: f.service)
        let page = try await reader.page(for: gap, offset: 0)
        #expect(page.lines.isEmpty && !page.hasMore)
    }

    @Test func oversizedContextObjectUsesBoundedDiskPrefixes() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let prefix = String(repeating: "x", count: DiffReadBudget.patchBytes + 1) + "\n"
        try f.write("file.txt", prefix + "old\n")
        _ = try await f.commit()
        try f.write("file.txt", prefix + "new\n")
        let diff = try await f.service.diff(
            path: "file.txt", layer: .unstaged, options: DiffReadOptions(contextLines: 0))
        #expect(diff.raw.count < 1024)
        let gap = try #require(DiffContextGap.gaps(for: diff).first)
        let reader = DiffContextReader(diff: diff, service: f.service)
        let page = try await reader.page(for: gap, offset: 0)
        #expect(page.consumedLines == 1 && !page.hasMore)
        #expect(page.lines[0].truncated && page.lines[0].content.utf8.count == DiskDiffBudget.prefixBytes)
        #expect(page.lines[0].oldLine == 1 && page.lines[0].newLine == 1)
        #expect(diff.raw.count < 1024)
    }

    @Test func diskAndMemorySnapshotsExposeTheSameContextRanges() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let original = (1...80).map { "line \($0)\n" }.joined()
        try f.write("file.txt", original)
        _ = try await f.commit()
        try f.write(
            "file.txt",
            original.replacingOccurrences(of: "line 20\n", with: "one\ntwo\n").replacingOccurrences(
                of: "line 60\n", with: "changed\n"))
        let memory = try await f.service.diff(path: "file.txt", layer: .unstaged)
        let disk = try await f.service.diskDiff(path: "file.txt", layer: .unstaged)
        #expect(DiffContextGap.gaps(for: memory) == DiffContextGap.gaps(for: disk))
        let lhs = DiffContextReader(diff: memory, service: f.service)
        let rhs = DiffContextReader(snapshot: disk, service: f.service)
        for gap in DiffContextGap.gaps(for: disk) {
            #expect(try await lhs.page(for: gap, offset: 0).lines == rhs.page(for: gap, offset: 0).lines)
        }
        let first = try await disk.page(count: 3)
        #expect(!first.firstHunkContinues)
        #expect(try await disk.page(from: first.next, count: 3).firstHunkContinues)
        let filtered = try await f.service.diskDiff(
            path: "file.txt", layer: .unstaged, options: DiffReadOptions(ignoreWhitespace: true))
        #expect(DiffContextGap.gaps(for: filtered).isEmpty)
    }

    @Test func largeContextReadsFixedBlobOffsetsAfterIndexChanges() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let padding = String(repeating: "x", count: 1000)
        let original = (1...10_000).map { "line \($0) \(padding)" }.joined(separator: "\r\n")
        try f.write("file.txt", original)
        let head = try await f.commit()
        try f.write(
            "file.txt",
            original.replacingOccurrences(of: "line 300 ", with: "changed 300 ").replacingOccurrences(
                of: "line 6000 ", with: "changed 6000 "))
        let disk = try await f.service.diskDiff(path: "file.txt", layer: .unstaged)
        let gaps = DiffContextGap.gaps(for: disk)
        #expect(gaps.count == 3)
        let reader = DiffContextReader(snapshot: disk, service: f.service)
        try f.write("file.txt", "later index contents\n")
        try await f.service.stage(paths: ["file.txt"], expectedHead: head)
        let middle = try await reader.page(for: gaps[1], offset: 1000)
        #expect(middle.lines.first?.oldLine == 1304)
        #expect(middle.lines.first?.content == "line 1304 \(padding)\r")
        #expect(middle.consumedLines == 20 && middle.hasMore)
        let tailOffset = 9999 - gaps[2].oldStart
        let tail = try await reader.page(for: gaps[2], offset: tailOffset)
        #expect(tail.consumedLines == 2 && !tail.hasMore)
        #expect(tail.lines[1].content == "line 10000 \(padding)")
        #expect(tail.lines.last?.kind == "\\")
        #expect(Set((middle.lines + tail.lines).map(\.id)).count == middle.lines.count + tail.lines.count)
    }
}
