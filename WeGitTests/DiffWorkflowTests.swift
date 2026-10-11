import Darwin
import Foundation
import Testing

@testable import WeGitCore

struct DiffWorkflowTests {
    @Test func expandedContextIsReadAndAppliedAgainstTheSameOptions() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file.txt", (1...40).map { "line \($0)\n" }.joined())
        _ = try await f.commit()
        try f.write(
            "file.txt", (1...40).map { [5, 25].contains($0) ? "changed \($0)\n" : "line \($0)\n" }.joined())
        #expect(try await f.service.diff(path: "file.txt", layer: .unstaged).hunks.count == 2)
        let expanded = try await f.service.diff(
            path: "file.txt", layer: .unstaged, options: DiffReadOptions(contextLines: 20))
        #expect(expanded.hunks.count == 1)
        #expect(expanded.options.contextLines == 20)
        try await f.service.apply(hunk: expanded.hunks[0], from: expanded)
        #expect(try await f.service.status().files[0].layers == [.staged])
    }

    @Test func ignoreWhitespaceNeverPermitsWritingTheFilteredPatch() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file.swift", "let value = 1\nlet other = 2\n")
        _ = try await f.commit()
        let updated = "let   value = 1\nlet other = 3\n"
        try f.write("file.swift", updated)
        let filtered = try await f.service.diff(
            path: "file.swift", layer: .unstaged,
            options: DiffReadOptions(ignoreWhitespace: true))
        #expect(!filtered.canApplyHunk)
        #expect(!filtered.hunks.isEmpty)
        await #expect(throws: ModelFailure.self) {
            try await f.service.apply(hunk: filtered.hunks[0], from: filtered)
        }
        await #expect(throws: ModelFailure.self) { try await f.service.discard(filtered) }
        #expect(try String(contentsOf: f.root.appending(path: "file.swift"), encoding: .utf8) == updated)
        #expect(try await f.service.status().files[0].layers == [.unstaged])
    }

    @Test func discardHunkKeepsStagedContentAndOtherWorkingChanges() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        func contents(_ edits: Set<Int>) -> String {
            (1...70).map { edits.contains($0) ? "edited \($0)\n" : "line \($0)\n" }.joined()
        }
        try f.write("file.txt", contents([]))
        let head = try await f.commit()
        try f.write("file.txt", contents([2]))
        try await f.service.stage(paths: ["file.txt"], expectedHead: head)
        try f.write("file.txt", contents([2, 30, 65]))
        let unstaged = try await f.service.diff(path: "file.txt", layer: .unstaged)
        #expect(unstaged.hunks.count == 2)
        try await f.service.apply(hunk: unstaged.hunks[0], from: unstaged, discard: true)
        #expect(
            try String(contentsOf: f.root.appending(path: "file.txt"), encoding: .utf8) == contents([2, 65]))
        #expect(try await f.engine.run(["show", ":file.txt"], in: f.root).text == contents([2]))
        let staged = try await f.service.diff(path: "file.txt", layer: .staged)
        await #expect(throws: ModelFailure.self) {
            try await f.service.apply(hunk: staged.hunks[0], from: staged, discard: true)
        }
    }

    @Test func rejectsHunkThatDoesNotBelongToTheFreshDiff() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file.txt", "old\n")
        _ = try await f.commit()
        try f.write("file.txt", "new\n")
        let diff = try await f.service.diff(path: "file.txt", layer: .unstaged)
        let hunk = diff.hunks[0]
        let forged = DiffHunk(
            id: hunk.id, header: hunk.header, lines: hunk.lines,
            raw: hunk.raw.replacingOccurrences(of: "+new", with: "+unexpected"))
        await #expect(throws: ModelFailure.self) { try await f.service.apply(hunk: forged, from: diff) }
        #expect(try await f.engine.run(["show", ":file.txt"], in: f.root).text == "old\n")
    }

    @Test func unstageRenameRestoresBothIndexPaths() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("old name.txt", "content\n")
        let head = try await f.commit()
        _ = try await f.engine.run(["mv", "old name.txt", "new name.txt"], in: f.root)
        #expect(try await f.service.status().files[0].oldPath == "old name.txt")
        try await f.service.unstage(paths: ["new name.txt"], expectedHead: head)
        #expect(try await f.service.status().files.allSatisfy { !$0.staged })
        #expect(try await f.engine.run(["ls-files", "-z"], in: f.root).stdout == Data("old name.txt\0".utf8))
        #expect(
            try String(contentsOf: f.root.appending(path: "new name.txt"), encoding: .utf8) == "content\n")
    }

    @Test func parserRejectsIncompleteAndOverflowingHunks() {
        let inputs = [
            "@@ -1,2 +1,2 @@\n-old\n+new\n",
            "@@ -999999999999999999999999 +1 @@\n-old\n+new\n",
            "@@ -1 +1 @@\n-old\n+new\n+extra\n",
            "@@ malformed\n",
            "@@ -1 +1 @@\n-old\n+new",
        ]
        for text in inputs {
            #expect(throws: ModelFailure.self) {
                _ = try DiffParser.parse(Data(text.utf8), path: "file", layer: .unstaged, head: nil)
            }
        }
        #expect(throws: ModelFailure.self) { _ = try StatusParser.parse(Data("? truncated".utf8)) }
    }

    @Test func binaryLookingCodeIsTextAndTypeChangeIsReadOnly() throws {
        let text =
            "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+Binary files are ordinary words in code\n"
        let diff = try DiffParser.parse(Data(text.utf8), path: "a", layer: .unstaged, head: nil)
        #expect(!diff.binary && diff.canApplyHunk)
        let multiple = text + "diff --git a/a b/a\nnew file mode 120000\n@@ -0,0 +1 @@\n+target\n"
        let typeChange = try DiffParser.parse(Data(multiple.utf8), path: "a", layer: .unstaged, head: nil)
        #expect(typeChange.preview == multiple && !typeChange.canApplyHunk)
    }

    @Test func untrackedSymlinkIsNotFollowedAndFIFOIsRejected() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("target.txt", "do not read through the link")
        try FileManager.default.createSymbolicLink(
            atPath: f.root.appending(path: "link").path, withDestinationPath: "target.txt")
        #expect(try await f.service.diff(path: "link", layer: .untracked).preview == "target.txt")
        let fifo = f.root.appending(path: "pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.diff(path: "pipe", layer: .untracked)
        }
    }
    @Test func staleBinaryDiscardIsRejected() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let file = f.root.appending(path: "image.bin")
        try Data([0, 1, 2, 3]).write(to: file)
        _ = try await f.commit()
        try Data([0, 4, 5, 6]).write(to: file)
        let diff = try await f.service.diff(path: "image.bin", layer: .unstaged)
        #expect(diff.binary)
        try Data([0, 7, 8, 9]).write(to: file)
        await #expect(throws: ModelFailure.self) { try await f.service.discard(diff) }
        #expect(try Data(contentsOf: file) == Data([0, 7, 8, 9]))
    }
    @Test func patchPathsAreIndependentOfUserDiffPrefixConfiguration() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try FileManager.default.createDirectory(
            at: f.root.appending(path: "nested"), withIntermediateDirectories: true)
        try f.write("target.txt", "old\n")
        try f.write("nested/target.txt", "old\n")
        _ = try await f.commit()
        _ = try await f.engine.run(["config", "diff.noprefix", "true"], in: f.root)
        try f.write("nested/target.txt", "new\n")
        let diff = try await f.service.diff(path: "nested/target.txt", layer: .unstaged)
        #expect(diff.header.contains("--- a/nested/target.txt"))
        try await f.service.apply(hunk: diff.hunks[0], from: diff)
        #expect(try await f.engine.run(["show", ":nested/target.txt"], in: f.root).text == "new\n")
        #expect(try await f.engine.run(["show", ":target.txt"], in: f.root).text == "old\n")
    }
}
