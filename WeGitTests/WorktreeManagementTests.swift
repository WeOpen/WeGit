import Foundation
import Testing

@testable import WeGitCore

struct WorktreeManagementTests {
    @Test func parserPreservesOriginalNewlinePathAndCanonicalIdentity() throws {
        let path = "/tmp/工作区\nlinked"
        let head = String(repeating: "a", count: 40)
        let bytes = Data("worktree \(path)\0HEAD \(head)\0branch refs/heads/topic\0locked reason\0\0".utf8)
        let rows = try WorktreeParser.parse(bytes)
        #expect(rows.count == 1 && rows[0].reportedPath == path && rows[0].head == head)
        #expect(rows[0].branchName == "topic" && rows[0].locked == "reason")
        #expect(rows[0].path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    @Test(arguments: [WorktreeCreationKind.newBranch("topic"), .existingBranch("free"), .detached])
    func creationPinsBranchAndKeepsSourceBytes(kind: WorktreeCreationKind) async throws {
        let f = try await Fixture.create()
        let path = f.root.appendingPathExtension("linked")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: path)
        }
        try f.write("file", "base\n")
        let head = try await f.commit()
        _ = try await f.engine.run(["branch", "free"], in: f.root)
        let index = try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index"))
        let plan = try await f.service.prepareWorktreeCreation(at: path, kind: kind)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let receipt = try await f.service.executeWorktreeCreation(plan)
        let state = try await RepositoryService(location: receipt.location, engine: f.engine).status()
        #expect(state.head == head && state.files.isEmpty)
        #expect(state.branch == (kind.branch ?? "(detached)"))
        #expect(try Data(contentsOf: path.appending(path: "file")) == Data("base\n".utf8))
        #expect(try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index")) == index)
        #expect(try await f.service.head() == head)
    }

    @Test func lateDestinationDoesNotGetOverwritten() async throws {
        let f = try await Fixture.create()
        let path = f.root.appendingPathExtension("foreign")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: path)
        }
        try f.write("file", "base\n")
        _ = try await f.commit()
        let plan = try await f.service.prepareWorktreeCreation(at: path, kind: .newBranch("topic"))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        let bytes = Data("foreign\n".utf8)
        try bytes.write(to: path.appending(path: "private"))
        await #expect(throws: ModelFailure.self) { _ = try await f.service.executeWorktreeCreation(plan) }
        #expect(try Data(contentsOf: path.appending(path: "private")) == bytes)
    }

    @Test func removalKeepsIgnoredBytesAndPrivateIndex() async throws {
        let f = try await Fixture.create()
        let path = f.root.appendingPathExtension("linked")
        var saved: URL?
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: path)
            if let saved { try? FileManager.default.removeItem(at: saved) }
        }
        try f.write("file", "base\n")
        try f.write(".gitignore", "*.ignored\n")
        let head = try await f.commit()
        _ = try await f.service.executeWorktreeCreation(
            f.service.prepareWorktreeCreation(at: path, kind: .newBranch("topic")))
        let row = try #require(try await f.service.worktrees().first { $0.branchName == "topic" })
        let plan = try await f.service.prepareWorktreeRemoval(row)
        let bytes = Data("late ignored\n".utf8)
        try bytes.write(to: path.appending(path: "late.ignored"))
        let receipt = try await f.service.executeWorktreeRemoval(plan)
        saved = receipt.preservedDirectory.deletingLastPathComponent()
        #expect(try Data(contentsOf: receipt.preservedDirectory.appending(path: "late.ignored")) == bytes)
        #expect(FileManager.default.fileExists(atPath: saved!.appending(path: "git-state/index").path))
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(try await f.service.head() == head)
        #expect(
            try await f.engine.run(["rev-parse", "refs/heads/topic"], in: f.root).text.removingLastNewline
                == head)
    }

    @Test func staleLockProtectsRemovalAndIndex() async throws {
        let f = try await Fixture.create()
        let path = f.root.appendingPathExtension("linked")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: path)
        }
        try f.write("file", "base\n")
        _ = try await f.commit()
        let creation = try await f.service.prepareWorktreeCreation(at: path, kind: .newBranch("topic"))
        let created = try await f.service.executeWorktreeCreation(creation)
        let row = try #require(try await f.service.worktrees().first { $0.branchName == "topic" })
        let plan = try await f.service.prepareWorktreeRemoval(row)
        let index = try Data(contentsOf: created.location.gitDirectory.appending(path: "index"))
        _ = try await f.engine.run(["worktree", "lock", path.path], in: f.root)
        await #expect(throws: ModelFailure.self) { _ = try await f.service.executeWorktreeRemoval(plan) }
        #expect(try Data(contentsOf: created.location.gitDirectory.appending(path: "index")) == index)
        #expect(try Data(contentsOf: path.appending(path: "file")) == Data("base\n".utf8))
    }
}
