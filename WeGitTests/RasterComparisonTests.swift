import Foundation
import Testing

@testable import WeGitCore

struct RasterComparisonTests {
    @Test func workingImageInputsKeepBothOriginalSnapshotsAfterExternalEdit() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let original = Data([0, 1, 2, 3])
        let working = Data([0, 4, 5, 6])
        try original.write(to: f.root.appending(path: "image.png"))
        let head = try await f.commit()
        try working.write(to: f.root.appending(path: "image.png"))
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let images = try await f.service.prepareRasterComparison(path: "image.png", layer: .unstaged)
        try Data([0, 7, 8, 9]).write(to: f.root.appending(path: "image.png"))
        #expect(try await images.before.readBytes() == original)
        #expect(try await images.after.readBytes() == working)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(try await f.service.head() == head)
    }

    @Test func stagedRenameReadsTheOldHeadPathAndNewIndexPathWithoutReadingWorkingContent() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let original = Data([0, 1, 2])
        let staged = Data([0, 3, 4])
        try original.write(to: f.root.appending(path: "old.png"))
        let head = try await f.commit()
        try FileManager.default.moveItem(
            at: f.root.appending(path: "old.png"), to: f.root.appending(path: "new.png"))
        try staged.write(to: f.root.appending(path: "new.png"))
        _ = try await f.engine.run(["add", "--all"], in: f.root)
        try Data([0, 7, 8]).write(to: f.root.appending(path: "new.png"))
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let images = try await f.service.prepareRasterComparison(
            path: "new.png", layer: .staged, oldPath: "old.png")
        #expect(try await images.before.readBytes() == original)
        #expect(try await images.after.readBytes() == staged)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(try await f.service.head() == head)
    }

    @Test func oversizedWorkingImageIsRejectedBeforeCapturingOrAllocatingContent() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let url = f.root.appending(path: "large.png")
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(RasterReadBudget.bytes + 1))
        try file.close()
        let images = try await f.service.prepareRasterComparison(path: "large.png", layer: .untracked)
        #expect(images.before.kind == .absent && images.after.kind == .oversized)
        #expect(images.after.snapshot == nil && images.after.currentFile == nil)
        await #expect(throws: ModelFailure.self) { try await images.after.readBytes() }
    }

    @Test func historicalImageSymlinkIsClassifiedWithoutFollowingItsTargetAndLFSPointerStaysExplicit()
        async throws
    {
        let f = try await Fixture.create()
        defer { f.remove() }
        try FileManager.default.createSymbolicLink(
            atPath: f.root.appending(path: "link.png").path, withDestinationPath: "missing-image")
        let head = try await f.commit()
        let comparison = try await f.service.commitComparison(id: head)
        let file = try #require(comparison.files.first)
        let images = try await f.service.prepareRasterComparison(file: file, comparison: comparison)
        #expect(images.before.kind == .absent && images.after.kind == .symbolicLink)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "missing-image").path))
        let oid = String(repeating: "a", count: 64)
        let pointer = f.service.rasterLFSPointer(
            Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize 1024\n".utf8))
        #expect(pointer?.oid == oid && pointer?.bytes == 1024)
    }
}
