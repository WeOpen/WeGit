import Foundation
import Testing

@testable import WeGitCore

struct WordDiffTests {
    private func fragments(_ text: String, _ ranges: [NSRange]) -> [String] {
        ranges.map { (text as NSString).substring(with: $0) }
    }

    @Test func distinguishesSeparateChangedWords() throws {
        let old = "let count = old + base;"
        let new = "var count = new + base;"
        let result = try #require(WordDiff.ranges(old: old, new: new))
        #expect(fragments(old, result.removed) == ["let", "old"])
        #expect(fragments(new, result.added) == ["var", "new"])
    }

    @Test func handlesInsertionsDeletionsAndWhitespace() throws {
        let inserted = try #require(WordDiff.ranges(old: "", new: "let count = 1"))
        #expect(inserted.removed.isEmpty)
        #expect(fragments("let count = 1", inserted.added) == ["let count = 1"])
        let removed = try #require(WordDiff.ranges(old: "gone", new: ""))
        #expect(fragments("gone", removed.removed) == ["gone"] && removed.added.isEmpty)
        let spaces = try #require(WordDiff.ranges(old: "call(a,b)", new: "call(a, b)"))
        #expect(spaces.removed.isEmpty)
        #expect(fragments("call(a, b)", spaces.added) == [" "])
    }

    @Test func keepsUnicodeGraphemesIntact() throws {
        let old = "icon = 👩🏽‍💻"
        let new = "icon = 👨🏽‍💻"
        let result = try #require(WordDiff.ranges(old: old, new: new))
        #expect(fragments(old, result.removed) == ["👩🏽‍💻"])
        #expect(fragments(new, result.added) == ["👨🏽‍💻"])
        #expect(result.removed.allSatisfy { Range($0, in: old) != nil })
        #expect(result.added.allSatisfy { Range($0, in: new) != nil })
    }

    @Test func repeatedWordsKeepTheCommonSuffix() throws {
        let old = "a + a + b"
        let new = "a + b"
        let result = try #require(WordDiff.ranges(old: old, new: new))
        #expect(result.added.isEmpty)
        let removed = fragments(old, result.removed).joined()
        #expect(removed.contains("a") && removed.contains("+"))
        #expect(!removed.contains("b"))
    }

    @Test func boundsWorkForLongLinesAndDenseTokens() {
        #expect(WordDiff.ranges(old: String(repeating: "a", count: 8193), new: "b") == nil)
        #expect(
            WordDiff.ranges(
                old: String(repeating: "a ", count: 200), new: String(repeating: "b ", count: 200)) == nil)
        #expect(WordDiff.ranges(old: "a", new: "b", maximumCells: 1) == nil)
        #expect(WordDiff.ranges(old: "same", new: "same", maximumCells: 0)?.removed.isEmpty == true)
    }

    @Test func highlightingDoesNotChangeThePatchAppliedToGit() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("code.swift", "let count = 1\n")
        _ = try await f.commit()
        try f.write("code.swift", "let count = 2\n")
        let diff = try await f.service.diff(path: "code.swift", layer: .unstaged)
        let before = diff.raw
        let result = try await DiffHighlighting.prepare(diff)
        let old = try #require(diff.hunks[0].lines.first { $0.kind == "-" })
        let new = try #require(diff.hunks[0].lines.first { $0.kind == "+" })
        #expect(fragments(old.content, result.words[old.id] ?? []) == ["1"])
        #expect(fragments(new.content, result.words[new.id] ?? []) == ["2"])
        #expect(!(result.syntax[new.id] ?? []).isEmpty)
        #expect(diff.raw == before)
        try await f.service.apply(hunk: diff.hunks[0], from: diff)
        #expect(try await f.engine.run(["show", ":code.swift"], in: f.root).text == "let count = 2\n")
    }

    @Test func presentationPreparationRespectsCancellation() async throws {
        let diff = try DiffParser.parse(
            Data("@@ -1 +1 @@\n-old\n+new\n".utf8), path: "code.swift", layer: .unstaged, head: nil)
        let task = Task {
            try? await Task.sleep(for: .seconds(10))
            return try await DiffHighlighting.prepare(diff)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
    @Test func splitRowIdentityIsUniqueAcrossHunks() throws {
        let patch = "@@ -1 +1 @@\n-a\n+b\n@@ -10 +10 @@\n-c\n+d\n"
        let diff = try DiffParser.parse(Data(patch.utf8), path: "file", layer: .unstaged, head: nil)
        let rows = diff.hunks.flatMap { DiffAlignment.rows($0.lines) }
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows[0].new?.content == "b" && rows[1].new?.content == "d")
    }
}
