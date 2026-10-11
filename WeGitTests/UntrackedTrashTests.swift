import Foundation
import Testing

@testable import WeGitCore

private struct TestTrash: FileTrashing {
    let directory: URL
    func moveToTrash(_ url: URL) throws -> URL? {
        let destination = directory.appending(path: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

private struct UnavailableTrash: FileTrashing {
    func moveToTrash(_ url: URL) throws -> URL? { throw CocoaError(.fileWriteNoPermission) }
}

struct UntrackedTrashTests {
    @Test func removalPreservesTheIndexAndOtherWorkingFiles() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("tracked.txt", "base\n")
        let head = try await f.commit()
        try f.write("tracked.txt", "staged\n")
        try await f.service.stage(paths: ["tracked.txt"], expectedHead: head)
        try f.write("remove.txt", "untracked contents\n")
        try f.write("keep.txt", "keep\n")
        let removal = try await f.service.prepareUntrackedRemoval(path: "remove.txt", expectedHead: head)
        let destination = f.root.appending(path: "test-trash")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let receipt = try await f.service.trashUntracked(removal, trash: TestTrash(directory: destination))
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "remove.txt").path))
        #expect(try String(contentsOf: receipt.trashURL, encoding: .utf8) == "untracked contents\n")
        #expect(try String(contentsOf: f.root.appending(path: "keep.txt"), encoding: .utf8) == "keep\n")
        #expect(try await f.engine.run(["show", ":tracked.txt"], in: f.root).text == "staged\n")
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.trashUntracked(removal, trash: TestTrash(directory: destination))
        }
    }

    @Test func changedOrNewlyTrackedFilesCannotUseAnOldConfirmation() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "first\n")
        let removal = try await f.service.prepareUntrackedRemoval(path: "file", expectedHead: nil)
        try f.write("file", "changed after confirmation\n")
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.trashUntracked(removal, trash: UnavailableTrash())
        }
        let current = try await f.service.prepareUntrackedRemoval(path: "file", expectedHead: nil)
        try await f.service.stage(paths: ["file"], expectedHead: nil)
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.trashUntracked(current, trash: UnavailableTrash())
        }
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.prepareUntrackedRemoval(path: "file", expectedHead: nil)
        }
        #expect(
            try String(contentsOf: f.root.appending(path: "file"), encoding: .utf8)
                == "changed after confirmation\n")
    }

    @Test func unavailableTrashNeverDeletesTheFile() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "keep these bytes")
        let removal = try await f.service.prepareUntrackedRemoval(path: "file", expectedHead: nil)
        await #expect(throws: CocoaError.self) {
            _ = try await f.service.trashUntracked(removal, trash: UnavailableTrash())
        }
        #expect(try String(contentsOf: f.root.appending(path: "file"), encoding: .utf8) == "keep these bytes")
    }

    @Test func onlyTheSymlinkEntryMovesToTrash() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("target", "target contents")
        try FileManager.default.createSymbolicLink(
            atPath: f.root.appending(path: "link").path, withDestinationPath: "target")
        let removal = try await f.service.prepareUntrackedRemoval(path: "link", expectedHead: nil)
        #expect(removal.symbolicLink)
        let destination = f.root.appending(path: "test-trash")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let receipt = try await f.service.trashUntracked(removal, trash: TestTrash(directory: destination))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: receipt.trashURL.path) == "target")
        #expect(
            try String(contentsOf: f.root.appending(path: "target"), encoding: .utf8) == "target contents")
    }

    @Test func systemTrashProducesARecoverableReceipt() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let name = "WeGit-trash-test-\(UUID().uuidString).txt"
        try f.write(name, "disposable WeGit test fixture")
        let removal = try await f.service.prepareUntrackedRemoval(path: name, expectedHead: nil)
        let receipt = try await f.service.trashUntracked(removal)
        // Restore only this test-created file, then normal fixture cleanup removes it.
        defer { try? FileManager.default.moveItem(at: receipt.trashURL, to: f.root.appending(path: name)) }
        #expect(try String(contentsOf: receipt.trashURL, encoding: .utf8) == "disposable WeGit test fixture")
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: name).path))
    }
}
