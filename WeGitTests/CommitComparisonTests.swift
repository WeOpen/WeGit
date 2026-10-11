import Foundation
import Testing

@testable import WeGitCore

struct CommitComparisonTests {
    @Test func rootCommitListsLiteralPathsAndBinaryFiles() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let path = "name\twith\nspaces.swift"
        try f.write(path, "let value = 1\n")
        try Data([0, 1, 2]).write(to: f.root.appending(path: "image.bin"))
        let id = try await f.commit()
        let comparison = try await f.service.commitComparison(id: id)
        #expect(comparison.parent == nil && comparison.files.count == 2)
        let file = try #require(comparison.files.first { $0.path == path })
        #expect(file.status == "A" && file.additions == 1 && file.deletions == 0)
        #expect(comparison.files.first { $0.path == "image.bin" }?.binary == true)
        guard case .loaded(let diff) = try await f.service.readCommitFile(file, comparison: comparison) else {
            Issue.record("Root file diff should be readable")
            return
        }
        #expect(diff.layer == .commit && !diff.canApplyHunk && diff.additions == 1)
        await #expect(throws: ModelFailure.self) {
            try await f.service.apply(hunk: diff.hunks[0], from: diff)
        }
        #expect(try await f.service.status().files.isEmpty)
    }

    @Test func renamedFilesKeepBothPathsAndZeroChangeStatistics() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("before.txt", "unchanged\n")
        let parent = try await f.commit()
        _ = try await f.engine.run(["mv", "before.txt", "after\tname.txt"], in: f.root)
        let id = try await f.service.commit(message: "Rename", amend: false, expectedHead: parent)
        let comparison = try await f.service.commitComparison(id: id)
        let renamed = try #require(comparison.files.first)
        #expect(renamed.oldPath == "before.txt" && renamed.path == "after\tname.txt")
        #expect(renamed.status == "R" && renamed.additions == 0 && renamed.deletions == 0)
        guard case .loaded(let diff) = try await f.service.readCommitFile(renamed, comparison: comparison)
        else {
            Issue.record("Rename metadata should be readable")
            return
        }
        #expect(diff.header.contains("rename from before.txt"))
        #expect(!diff.canApplyHunk)
    }

    @Test func mergeFilesChangeWithTheSelectedParent() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("base.txt", "base\n")
        _ = try await f.commit()
        _ = try await f.engine.run(["switch", "-c", "feature"], in: f.root)
        try f.write("feature.txt", "feature\n")
        let feature = try await f.commit()
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        try f.write("main.txt", "main\n")
        let main = try await f.commit()
        _ = try await f.engine.run(["merge", "--no-edit", "feature"], in: f.root)
        let merge = try #require(try await f.service.head())
        let first = try await f.service.commitComparison(id: merge, parent: main)
        let second = try await f.service.commitComparison(id: merge, parent: feature)
        #expect(first.files.map(\.path) == ["feature.txt"])
        #expect(second.files.map(\.path) == ["main.txt"])
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.commitComparison(id: merge, parent: merge)
        }
    }

    @Test func immutableCommitDiffIgnoresLaterWorktreeAndHeadChanges() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "old\n")
        _ = try await f.commit()
        try f.write("file", "new\n")
        let id = try await f.commit()
        let comparison = try await f.service.commitComparison(id: id)
        try f.write("file", "later\n")
        _ = try await f.commit()
        guard
            case .loaded(let diff) = try await f.service.readCommitFile(
                comparison.files[0], comparison: comparison)
        else {
            Issue.record("Historical comparison should remain readable")
            return
        }
        #expect(diff.hunks[0].lines.contains { $0.kind == "+" && $0.content == "new" })
        #expect(!diff.hunks[0].lines.contains { $0.content == "later" })
    }
}
