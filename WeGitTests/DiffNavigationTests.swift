import Foundation
import Testing

@testable import WeGitCore

struct DiffNavigationTests {
    @Test func lineEndingsRemainExactAcrossMemoryAndDiskPageBoundaries() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("endings.txt", "before\r\nold tail")
        _ = try await fixture.commit()
        try fixture.write("endings.txt", "after\r\n终点🙂")
        let memory = try await fixture.service.diff(path: "endings.txt", layer: .unstaged)
        let disk = try await fixture.service.diskDiff(path: "endings.txt", layer: .unstaged)
        let expected = memory.hunks.flatMap(\.lines).filter { $0.kind != "\\" }
        #expect(expected.map(\.hasNewline) == [true, false, true, false])
        var actual: [DiffLine] = []
        var cursor: DiskDiffCursor?
        repeat {
            let page = try await disk.page(from: cursor, split: false, count: 2)
            actual += page.rows.compactMap { row in
                if case .line(let line) = row, line.kind != "\\" { return line }
                return nil
            }
            cursor = page.next
        } while cursor != nil
        #expect(actual.map(\.content) == expected.map(\.content))
        #expect(actual.map(\.hasNewline) == expected.map(\.hasNewline))
        let newer = actual.filter { $0.kind == "+" }
        let copied = CodeSelection.text(
            in: newer, from: CodeSelectionEndpoint(line: newer[0].id, offset: 0),
            to: CodeSelectionEndpoint(line: newer[1].id, offset: newer[1].content.utf16.count))
        #expect(copied == "after\r\n终点🙂")
    }

    @Test func diskDisplayPrefixesPreserveUnicodeAtTheirByteBoundary() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let prefix = String(repeating: "a", count: 8190)
        let source = prefix + "🙂" + String(repeating: "b", count: 100) + "\n"
        try fixture.write("long.txt", source)
        let preview = try await fixture.service.diskDiff(path: "long.txt", layer: .untracked)
        let page = try await preview.page()
        let line = try #require(
            page.rows.compactMap { if case .line(let value) = $0 { value } else { nil } }.first)
        #expect(line.truncated)
        #expect(line.content == prefix)
        #expect(!line.content.contains("�"))
        _ = try await fixture.commit()
        try fixture.write("long.txt", source.replacingOccurrences(of: "b", with: "c"))
        let patch = try await fixture.service.diskDiff(path: "long.txt", layer: .unstaged)
        let changes = try await patch.page(split: true)
        let pair = try #require(
            changes.rows.compactMap { if case .split(let value) = $0 { value } else { nil } }.first)
        #expect(pair.old?.content == prefix && pair.new?.content == prefix)
        #expect(pair.old?.truncated == true && pair.new?.truncated == true)
        #expect(try UTF8DisplayPrefix.decode(Data("🙂".utf8.prefix(3)), truncated: true) == "")
        #expect(throws: (any Error).self) {
            try UTF8DisplayPrefix.decode(Data([0xFF, 0x61]), truncated: true)
        }
    }

    @Test func sparseJumpAndCopiedPatchMatchTheExactSelectedHunk() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let original = (1...1500).map { "let value\($0) = \"中文🙂\"\r\n" }.joined()
        try fixture.write("navigation.swift", original)
        _ = try await fixture.commit()
        let modified = original.replacingOccurrences(of: "value5 =", with: "changed5 =")
            .replacingOccurrences(of: "value1450 =", with: "changed1450 =")
        try fixture.write("navigation.swift", modified)
        let memory = try await fixture.service.diff(path: "navigation.swift", layer: .unstaged)
        let disk = try await fixture.service.diskDiff(path: "navigation.swift", layer: .unstaged)
        try #require(memory.hunks.count == 2 && disk.hunks.count == 2)
        for split in [false, true] {
            let page = try await disk.page(atHunk: 1, split: split, count: 5)
            #expect(page.rows.first?.id == .hunk(1))
            #expect(!page.firstHunkContinues)
            #expect(page.bytesRead <= 16_384)
            #expect(page.firstLine > 1)
            #expect(
                try await disk.hunkPatch(disk.hunks[1]) == Data((memory.header + memory.hunks[1].raw).utf8))
            await #expect(throws: (any Error).self) { _ = try await disk.page(atHunk: 99, split: split) }
        }
        await #expect(throws: (any Error).self) { _ = try await disk.hunkPatch(disk.hunks[1], limit: 10) }
    }

    @Test func copiedHunkRefusesAChangedSnapshot() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file.txt", "old\n")
        _ = try await fixture.commit()
        try fixture.write("file.txt", "new\n")
        let disk = try await fixture.service.diskDiff(path: "file.txt", layer: .unstaged)
        let hunk = try #require(disk.hunks.first)
        try Data("replacement\n".utf8).write(to: disk.file.url)
        await #expect(throws: (any Error).self) { _ = try await disk.hunkPatch(hunk) }
        await #expect(throws: (any Error).self) { _ = try await disk.page(atHunk: hunk.id) }
    }
}
