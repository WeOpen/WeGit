import Darwin
import Foundation
import Testing

@testable import WeGitCore

struct FileModificationTests {
    @Test func partialDiscardPreservesUnselectedCRLFChangesAndRawIndexAndCanRecover() async throws {
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
        let plan = try await f.service.prepareSelectedLineDiscard(diff: diff, lineIDs: ids)
        #expect(plan.resultPreview == "a\r\nb\r\nC\r\nd")
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == working)
        let record = try await f.service.executeFileModification(plan)
        #expect(record.state == .succeeded)
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("a\r\nb\r\nC\r\nd".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(try await f.service.head() == head)
        _ = try await f.service.executeRecoveryRestore(
            f.service.prepareRecoveryRestore(record, layer: .worktree))
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == working)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
    }

    @Test func allUntrackedAdditionsAreRemovedAndRecoveryRestoresTheFile() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let working = Data("新文件\r\n末行".utf8)
        try working.write(to: f.root.appending(path: "new"))
        let diff = try await f.service.diff(path: "new", layer: .untracked)
        let ids: Set<Int> = [0, 1]
        let plan = try await f.service.prepareSelectedLineDiscard(diff: diff, lineIDs: ids)
        #expect(plan.deletesFile)
        let record = try await f.service.executeFileModification(plan)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "new").path))
        #expect(try await f.service.head() == nil)
        _ = try await f.service.executeRecoveryRestore(
            f.service.prepareRecoveryRestore(record, layer: .worktree))
        #expect(try Data(contentsOf: f.root.appending(path: "new")) == working)
    }

    @Test func indexOnlyHistoricalBinaryRestorePreservesWorkingBytesAndOtherStagedObjects() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let old = Data([0, 1, 2, 10, 255])
        try old.write(to: f.root.appending(path: "file"))
        try f.write("other", "original\n")
        let source = try await f.commit("Source")
        try f.write("file", "current committed\n")
        let head = try await f.commit("Current")
        let working = Data("unstaged work\r\n".utf8)
        try working.write(to: f.root.appending(path: "file"))
        try f.write("other", "new staged object\n")
        try await f.service.stage(paths: ["other"], expectedHead: head)
        #expect(chmod(f.root.appending(path: ".git/index").path, 0o600) == 0)
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let plan = try await f.service.prepareFileRestore(revision: source, sourcePath: "file", layer: .index)
        #expect(plan.resultPreview == nil)
        let record = try await f.service.executeFileModification(plan)
        #expect(try await f.engine.run(["show", ":file"], in: f.root).stdout == old)
        #expect(
            try await f.engine.run(["show", ":other"], in: f.root).stdout == Data("new staged object\n".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == working)
        _ = try await f.engine.run(["gc", "--prune=now"], in: f.root)
        _ = try await f.service.executeRecoveryRestore(
            f.service.prepareRecoveryRestore(record, layer: .index))
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(
            try await f.engine.run(["show", ":other"], in: f.root).stdout == Data("new staged object\n".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == working)
        #expect(try await f.service.head() == head)
    }

    @Test func renamedSourceUsesOnlyTheExplicitDestinationAndRestoresExecutableMode() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("old", "old bytes\n")
        #expect(chmod(f.root.appending(path: "old").path, 0o755) == 0)
        let source = try await f.commit("Source")
        try FileManager.default.moveItem(
            at: f.root.appending(path: "old"), to: f.root.appending(path: "renamed"))
        try f.write("renamed", "new bytes\n")
        _ = try await f.engine.run(["add", "--all"], in: f.root)
        let head = try await f.service.commit(message: "Rename", amend: false, expectedHead: source)
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let plan = try await f.service.prepareFileRestore(
            revision: source, sourcePath: "old", destinationPath: "renamed")
        _ = try await f.service.executeFileModification(plan)
        #expect(try Data(contentsOf: f.root.appending(path: "renamed")) == Data("old bytes\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "old").path))
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        var info = stat()
        #expect(lstat(f.root.appending(path: "renamed").path, &info) == 0 && info.st_mode & 0o777 == 0o755)
        #expect(try await f.service.head() == head)
    }

    @Test func missingHistoricalEntryDeletesBothLayersAndRecoveryRestoresThem() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("anchor", "anchor\n")
        let source = try await f.commit("Before file")
        try f.write("later", "added\n")
        let head = try await f.commit("Add file")
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let plan = try await f.service.prepareFileRestore(revision: source, sourcePath: "later", layer: .both)
        #expect(plan.deletesFile)
        let record = try await f.service.executeFileModification(plan)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "later").path))
        #expect(try await f.engine.run(["ls-files", "--", "later"], in: f.root).stdout.isEmpty)
        #expect(try await f.service.head() == head)
        _ = try await f.service.executeRecoveryRestore(f.service.prepareRecoveryRestore(record, layer: .both))
        #expect(try Data(contentsOf: f.root.appending(path: "later")) == Data("added\n".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
    }

    @Test func historicalSymlinkRestoreNeverReadsOrWritesTheLinkTarget() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try FileManager.default.createSymbolicLink(
            atPath: f.root.appending(path: "link").path, withDestinationPath: "missing-target")
        let source = try await f.commit("Link")
        try FileManager.default.removeItem(at: f.root.appending(path: "link"))
        try f.write("link", "regular file\n")
        let head = try await f.commit("Regular file")
        let plan = try await f.service.prepareFileRestore(revision: source, sourcePath: "link", layer: .both)
        _ = try await f.service.executeFileModification(plan)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: f.root.appending(path: "link").path)
                == "missing-target")
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "missing-target").path))
        #expect(
            try await f.engine.run(["ls-files", "--stage", "--", "link"], in: f.root).text.hasPrefix(
                "120000 "))
        #expect(try await f.service.head() == head)
    }

    @Test func staleWorkingFileRejectsHistoricalRestoreBeforeCreatingARecoveryRecord() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "old\n")
        let source = try await f.commit()
        try f.write("file", "preview bytes\n")
        let plan = try await f.service.prepareFileRestore(revision: source, sourcePath: "file")
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        try f.write("file", "external bytes\n")
        await #expect(throws: ModelFailure.self) { try await f.service.executeFileModification(plan) }
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("external bytes\n".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(try await f.service.recoveryRecords().isEmpty)
    }
}
