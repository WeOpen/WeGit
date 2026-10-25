import CoreServices
import Foundation
import Testing

@testable import WeGitCore

struct WorktreeTests {
    private func linked(_ f: Fixture, at path: URL, branch: String = "topic") async throws
        -> RepositoryService
    {
        _ = try await f.engine.run(["worktree", "add", "-b", branch, path.path], in: f.root)
        return try await RepositoryService(
            location: RepositoryService.discover(path, engine: f.engine), engine: f.engine)
    }

    @Test func snapshotsKeepBranchIndexAndSequenceStateLocal() async throws {
        let f = try await Fixture.create()
        let path = f.root.appendingPathExtension("linked")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: path)
        }
        try f.write("file", "base\n")
        let head = try await f.commit()
        let service = try await linked(f, at: path)
        try Data("topic\n".utf8).write(to: path.appending(path: "file"))
        try await service.stage(paths: ["file"], expectedHead: head)
        try Data((head + "\n").utf8).write(
            to: service.location.gitDirectory.appending(path: "CHERRY_PICK_HEAD"))
        let primary = try await f.service.readSnapshot()
        let secondary = try await service.readSnapshot()
        #expect(
            primary.status.branch == "main" && primary.status.files.isEmpty
                && primary.status.sequencer == .none)
        #expect(
            secondary.status.branch == "topic" && secondary.status.files.first?.staged == true
                && secondary.status.sequencer == .cherryPick)
        #expect(
            primary.branches?.first { $0.name == "topic" }?.worktreePath
                == path.resolvingSymlinksInPath().path)
        #expect(secondary.branches?.first { $0.current }?.name == "topic")
    }

    @Test func changingCommonPointerRejectsWritesEvenWhenGitDirectoryAndHeadMatch() async throws {
        let f = try await Fixture.create()
        let path = f.root.appendingPathExtension("linked")
        let copy = f.root.appendingPathExtension("common-copy")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: copy)
        }
        try f.write("file", "base\n")
        let head = try await f.commit()
        let service = try await linked(f, at: path)
        let index = try Data(contentsOf: service.location.gitDirectory.appending(path: "index"))
        try FileManager.default.copyItem(at: f.service.location.commonDirectory, to: copy)
        try Data((copy.path + "\n").utf8).write(
            to: service.location.gitDirectory.appending(path: "commondir"))
        try Data("do not stage\n".utf8).write(to: path.appending(path: "file"))
        do {
            try await service.stage(paths: ["file"], expectedHead: head)
            Issue.record("The changed common-directory pointer must reject the staged write")
        } catch ModelFailure.repositoryReplaced {}
        #expect(try Data(contentsOf: service.location.gitDirectory.appending(path: "index")) == index)
        let reopened = try await RepositoryService.discover(path, engine: f.engine)
        #expect(reopened.persistenceID != service.location.persistenceID)
        #expect(!reopened.isSameRepository(as: service.location))
    }

    @Test func copyingAGitPointerCannotImpersonateAnotherWorktree() async throws {
        let f = try await Fixture.create()
        let path = f.root.appendingPathExtension("linked")
        let impostor = f.root.appendingPathExtension("impostor")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: impostor)
        }
        try f.write("file", "base\n")
        _ = try await f.commit()
        _ = try await linked(f, at: path)
        try FileManager.default.copyItem(at: path, to: impostor)
        do {
            _ = try await RepositoryService.discover(impostor, engine: f.engine)
            Issue.record("A copied .git pointer must not open the original worktree")
        } catch ModelFailure.repositoryReplaced {}
    }

    @Test func siblingRemoteEditInvalidatesConfirmedConfiguration() async throws {
        let f = try await Fixture.create()
        let path = f.root.appendingPathExtension("linked")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: path)
        }
        try f.write("file", "base\n")
        let head = try await f.commit()
        let service = try await linked(f, at: path)
        let old = try await service.remoteManagement()
        let primary = try await f.service.remoteManagement()
        try await f.service.changeRemote(
            .add(name: "one", fetchURL: "https://example.invalid/one.git", pushURL: nil),
            in: primary, expectedHead: head)
        do {
            try await service.changeRemote(
                .add(name: "two", fetchURL: "https://example.invalid/two.git", pushURL: nil), in: old,
                expectedHead: head)
            Issue.record("A sibling's remote edit must invalidate the prior confirmation")
        } catch ModelFailure.changed {}
        #expect(try await service.remotes() == ["one"])
        #expect(
            !FileManager.default.fileExists(
                atPath: f.service.location.commonDirectory.appending(path: "config.lock").path))
    }

    @Test func unrelatedRepositoryQueuesStayIndependent() async throws {
        let first = try await Fixture.create()
        let second = try await Fixture.create()
        defer {
            first.remove()
            second.remove()
        }
        #expect(first.service.queue !== second.service.queue)
        let rediscovered = try await RepositoryService.discover(first.root, engine: first.engine)
        #expect(RepositoryService(location: rediscovered, engine: first.engine).queue === first.service.queue)
    }
}
