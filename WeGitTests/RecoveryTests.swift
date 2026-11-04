import Foundation
import Testing

@testable import WeGitCore

private actor LostResetReply: ProcessRunning {
    private(set) var writes = 0
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await ProcessRunner().run(request)
        if request.arguments.contains("reset"), result.exitCode == 0 {
            writes += 1
            throw ProcessFailure.timedOut
        }
        return result
    }
}

struct RecoveryTests {
    @Test(arguments: ResetMode.allCases)
    func resetPreservesEachLayerAndBackupsRestoreExactBytes(mode: ResetMode) async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let path = "中文\n[恢复].txt"
        try f.write(path, "original\r\nlast")
        let target = try await f.commit("Target")
        try f.write(path, "committed\r\nlast")
        let before = try await f.commit("Current")
        try f.write(path, "staged\r\nlast")
        try await f.service.stage(paths: [path], expectedHead: before)
        try f.write(path, "working\r\nlast")
        let originalIndex = try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index"))
        let originalWork = try Data(contentsOf: f.root.appending(path: path))
        let plan = try await f.service.prepareReset(target: target, mode: mode)
        #expect(try await f.service.head() == before)
        #expect(
            try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index")) == originalIndex)
        let backup = try await f.service.executeReset(plan)
        #expect(try await f.service.head() == target)
        #expect(backup.head == before && backup.state == .succeeded)
        if mode == .soft {
            #expect(
                try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index"))
                    == originalIndex)
        } else {
            #expect(
                try await f.engine.run(["show", ":" + path], in: f.root).stdout
                    == Data("original\r\nlast".utf8))
        }
        #expect(
            try Data(contentsOf: f.root.appending(path: path))
                == (mode == .hard ? Data("original\r\nlast".utf8) : originalWork))
        let reopened = RepositoryService(
            location: try await RepositoryService.discover(f.root, engine: f.engine), engine: f.engine)
        let record = try #require(try await reopened.recoveryRecords().first)
        let restore = try await reopened.prepareRecoveryRestore(record, layer: mode == .hard ? .both : .index)
        _ = try await reopened.executeRecoveryRestore(restore)
        #expect(
            try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index")) == originalIndex)
        #expect(try Data(contentsOf: f.root.appending(path: path)) == originalWork)
        #expect(try await reopened.head() == target)
        try await reopened.createBranch("recovered", start: before, switchTo: false, expectedHead: target)
        #expect(
            try await f.engine.run(["rev-parse", "refs/heads/recovered"], in: f.root).text.removingLastNewline
                == before)
    }

    @Test(arguments: ["workfile", "index", "branch"])
    func stalePreviewNeverOverwritesExternalChanges(kind: String) async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let base = try await f.commit("Base")
        try f.write("file", "current\n")
        let head = try await f.commit("Current")
        let plan = try await f.service.prepareReset(target: base, mode: .hard)
        switch kind {
        case "workfile": try f.write("file", "external bytes\n")
        case "index":
            try f.write("file", "external bytes\n")
            try await f.service.stage(paths: ["file"], expectedHead: head)
        default: _ = try await f.engine.run(["switch", "-c", "external-branch"], in: f.root)
        }
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let bytes = try Data(contentsOf: f.root.appending(path: "file"))
        await #expect(throws: ModelFailure.self) { _ = try await f.service.executeReset(plan) }
        #expect(try await f.service.head() == head)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == bytes)
        #expect(try await f.service.recoveryRecords().isEmpty)
    }

    @Test func ignoredObstaclesAndRedirectedBackupDirectoriesAreRejectedBeforeWriting() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "target\n")
        let target = try await f.commit("Target")
        _ = try await f.engine.run(["rm", "file"], in: f.root)
        let head = try await f.commit("Remove file")
        try f.write(".git/info/exclude", "file\n")
        try f.write("file", "ignored private content\n")
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.prepareReset(target: target, mode: .hard)
        }
        #expect(try await f.service.head() == head)
        #expect(
            try Data(contentsOf: f.root.appending(path: "file")) == Data("ignored private content\n".utf8))
        try FileManager.default.removeItem(at: f.root.appending(path: "file"))
        let plan = try await f.service.prepareReset(target: target, mode: .hard)
        let foreign = f.root.appending(path: "foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: f.root.appending(path: ".git/wegit-recovery"), withDestinationURL: foreign)
        await #expect(throws: ModelFailure.self) { _ = try await f.service.executeReset(plan) }
        #expect(try await f.service.head() == head)
        #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path).isEmpty)
    }

    @Test func symbolicLinkBackupNeverReadsOrWritesItsDestination() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let outside = FileManager.default.temporaryDirectory.appending(
            path: "WeGitRecoveryExternal-" + UUID().uuidString)
        try Data("external private bytes".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try f.write("link", "base\n")
        let target = try await f.commit("Base")
        try FileManager.default.removeItem(at: f.root.appending(path: "link"))
        try FileManager.default.createSymbolicLink(
            at: f.root.appending(path: "link"), withDestinationURL: outside)
        _ = try await f.commit("Link")
        let plan = try await f.service.prepareReset(target: target, mode: .hard)
        let record = try await f.service.executeReset(plan)
        #expect(record.files.first?.kind == .symbolicLink)
        let restore = try await f.service.prepareRecoveryRestore(record)
        _ = try await f.service.executeRecoveryRestore(restore)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: f.root.appending(path: "link").path)
                == outside.path)
        #expect(try Data(contentsOf: outside) == Data("external private bytes".utf8))
    }

    @Test func lostReplyRetainsBackupAndCannotRepeatTheReset() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let base = try await f.commit("Base")
        try f.write("file", "current\n")
        _ = try await f.commit("Current")
        try f.write("file", "private uncommitted\n")
        let recorder = LostResetReply()
        let engine = TestGit.engine(runner: recorder, environment: f.engine.environment)
        let service = RepositoryService(location: f.service.location, engine: engine)
        let plan = try await service.prepareReset(target: base, mode: .hard)
        await #expect(throws: RecoveryOutcomeUnknown.self) { _ = try await service.executeReset(plan) }
        #expect(try await service.head() == base)
        let record = try #require(try await service.recoveryRecords().first)
        #expect(record.state == .needsVerification)
        await #expect(throws: ModelFailure.self) { _ = try await service.executeReset(plan) }
        #expect(await recorder.writes == 1)
        let restore = try await service.prepareRecoveryRestore(record)
        _ = try await service.executeRecoveryRestore(restore)
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("private uncommitted\n".utf8))
    }

    @Test func damagedBackupBytesCannotReachTheWorktreeOrIndex() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let base = try await f.commit("Base")
        try f.write("file", "current\n")
        _ = try await f.commit("Current")
        let record = try await f.service.executeReset(f.service.prepareReset(target: base, mode: .hard))
        let blob = f.service.location.gitDirectory.appending(
            path: "wegit-recovery/" + record.id.uuidString + "/" + record.files[0].storageName)
        try Data("tampered bytes\n".utf8).write(to: blob)
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.prepareRecoveryRestore(record, layer: .both)
        }
        #expect(try await f.service.head() == base)
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("base\n".utf8))
    }

    @Test func reflogPagesUseEntryTimesAndRecoverDeletedBranchObjects() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let base = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "deleted"], in: f.root)
        try f.write("file", "recoverable\n")
        let old = try await f.commit("Recoverable")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        _ = try await f.engine.run(["branch", "-D", "deleted"], in: f.root)
        let first = try await f.service.reflog(limit: 2)
        let second = try await f.service.reflog(offset: 2, limit: 2)
        #expect(first.count == 2 && !second.isEmpty)
        #expect(first.allSatisfy { $0.date != nil && $0.objectExists })
        #expect(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        #expect((first + second).contains { $0.object == old })
        try await f.service.createBranch("recovered", start: old, switchTo: false, expectedHead: base)
        #expect(
            try await f.engine.run(["rev-parse", "recovered"], in: f.root).text.removingLastNewline == old)
    }
}
