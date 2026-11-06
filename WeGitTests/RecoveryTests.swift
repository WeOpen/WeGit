import Darwin
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

private actor IndexEditAfterReset: ProcessRunning {
    let engine: GitEngine
    let root: URL
    let object: String
    init(engine: GitEngine, root: URL, object: String) {
        self.engine = engine
        self.root = root
        self.object = object
    }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await ProcessRunner().run(request)
        if request.arguments.contains("reset"), result.exitCode == 0 {
            _ = try await engine.run(
                ["update-index", "--add", "--cacheinfo", "100644", object, "file"], in: root)
        }
        return result
    }
}

private actor IndexEditDuringResetVerification: ProcessRunning {
    let engine: GitEngine
    let root: URL
    private var resetFinished = false
    private var indexCompared = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(engine: GitEngine, root: URL) {
        self.engine = engine
        self.root = root
    }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if resetFinished, request.arguments.contains("diff") {
            if !indexCompared {
                await withCheckedContinuation { waiting.append($0) }
            }
            try Data("external staged bytes\n".utf8).write(to: root.appending(path: "file"))
            _ = try await engine.run(["add", "--", "file"], in: root)
        }
        let result = try await ProcessRunner().run(request)
        if request.arguments.contains("reset"), result.exitCode == 0 { resetFinished = true }
        if resetFinished, request.arguments.contains("diff-index") {
            indexCompared = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }
        return result
    }
}

private actor WorkEditAfterResetShard: ProcessRunning {
    let root: URL
    private var resetFinished = false
    private(set) var changed = false
    init(root: URL) { self.root = root }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await ProcessRunner().run(request)
        if request.arguments.contains("reset"), result.exitCode == 0 { resetFinished = true }
        if resetFinished, !changed, request.arguments.contains("diff"),
            request.arguments.contains("file-0"), result.exitCode == 0
        {
            try Data("external after verified shard\n".utf8).write(to: root.appending(path: "file-0"))
            changed = true
        }
        return result
    }
}

private actor IndexEditDuringRecoveryPreview: ProcessRunning {
    let engine: GitEngine
    let root: URL
    private(set) var changed = false
    init(engine: GitEngine, root: URL) {
        self.engine = engine
        self.root = root
    }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await ProcessRunner().run(request)
        if !changed, request.arguments.contains("ls-files"), request.arguments.contains("--unmerged") {
            changed = true
            try Data("external staged preview edit\n".utf8).write(to: root.appending(path: "file"))
            _ = try await engine.run(["add", "--", "file"], in: root)
        }
        return result
    }
}

struct RecoveryTests {
    @Test func externalStagingDuringOverlappedRecoveryPreviewKeepsItsBytesAndRejectsThePlan() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "target\n")
        let target = try await f.commit("Target")
        try f.write("file", "original working\n")
        _ = try await f.commit("Current")
        let record = try await f.service.executeReset(f.service.prepareReset(target: target, mode: .hard))
        let runner = IndexEditDuringRecoveryPreview(engine: f.engine, root: f.root)
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: runner, environment: f.engine.environment))
        await #expect(throws: ModelFailure.self) {
            try await service.prepareRecoveryRestore(record, layer: .both)
        }
        #expect(await runner.changed)
        #expect(try await service.head() == target)
        #expect(
            try await f.engine.run(["show", ":file"], in: f.root).stdout
                == Data("external staged preview edit\n".utf8))
        #expect(try await service.recoveryRecords().first?.state == .succeeded)
    }

    @Test func capturedBatchesKeepOriginalBytesAndRejectAReplacedStorageDirectory() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let paths = (0..<128).map { "file-\($0)" }
        let original = Data("original\r\nlast".utf8)
        for path in paths { try original.write(to: f.root.appending(path: path)) }
        let head = try await f.commit("Initial")
        let index = try SelectedIndexSnapshot.read(location: f.service.location)
        let captures = try await RecoveryFileIO.captureAll(location: f.service.location, paths: paths)
        for path in paths { try f.write(path, "later edit\n") }
        for capture in captures {
            let snapshot = try #require(capture.snapshot)
            let descriptor = try snapshot.open()
            let bytes = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).readToEnd()
            #expect(bytes == original)
        }
        let storage = try #require(captures.last?.snapshot?.directory)
        let moved = storage.url.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: storage.url, to: moved)
        try FileManager.default.createDirectory(
            at: storage.url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            try? FileManager.default.removeItem(at: storage.url)
            try? FileManager.default.moveItem(at: moved, to: storage.url)
        }
        await #expect(throws: ModelFailure.self) {
            try await SnapshotIO.run { cancellation in
                try RecoveryFileIO.validateSnapshotStorage(captures, cancellation: cancellation)
            }
        }
        #expect(try await f.service.head() == head)
        #expect(try SelectedIndexSnapshot.read(location: f.service.location) == index)
    }

    @Test func independentRestoreLeavesKeepExactBytesModesAndTheOriginalIndex() async throws {
        let f = try await Fixture.create()
        let source = try await Fixture.create()
        defer {
            f.remove()
            source.remove()
        }
        let paths = (0..<128).map { "file-\($0)" }
        for path in paths { try f.write(path, "original\r\nlast") }
        _ = try await f.commit("Initial")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: f.root.appending(path: paths[0]).path)
        let index = try SelectedIndexSnapshot.read(location: f.service.location)
        let expected = try await RecoveryFileIO.captureAll(location: f.service.location, paths: paths)
        for (position, capture) in expected.enumerated() {
            try source.write(capture.file.path, "restored \(position)\r\nlast")
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: capture.file.mode)],
                ofItemAtPath: source.root.appending(path: capture.file.path).path)
        }
        let sources = try await RecoveryFileIO.captureAll(location: source.service.location, paths: paths)
        try await RecoveryFileIO.installAll(
            sources: sources, expected: expected, location: f.service.location)
        try await RecoveryFileIO.verifyContentsAll(sources, location: f.service.location)
        #expect(try SelectedIndexSnapshot.read(location: f.service.location) == index)
        let mode =
            try FileManager.default.attributesOfItem(atPath: f.root.appending(path: paths[0]).path)[
                .posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o444)
    }

    @Test func restoreWithNewParentDirectoriesPreservesItsSerialIdentityChain() async throws {
        let f = try await Fixture.create()
        let source = try await Fixture.create()
        defer {
            f.remove()
            source.remove()
        }
        let paths = (0..<128).map { "created/nested/file-\($0)" }
        let expected = try await RecoveryFileIO.captureAll(location: f.service.location, paths: paths)
        try FileManager.default.createDirectory(
            at: source.root.appending(path: "created/nested"), withIntermediateDirectories: true)
        for path in paths {
            try source.write(path, "created\r\nlast")
        }
        let sources = try await RecoveryFileIO.captureAll(location: source.service.location, paths: paths)
        try await RecoveryFileIO.installAll(
            sources: sources, expected: expected, location: f.service.location)
        try await RecoveryFileIO.verifyContentsAll(sources, location: f.service.location)
        #expect(try await f.service.head() == nil)
        #expect(try SelectedIndexSnapshot.read(location: f.service.location).bytes == nil)
    }

    @Test func editingAnAlreadyVerifiedWorkShardPreventsAResetSuccessReceipt() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let paths = (0..<128).map { "file-\($0)" }
        for path in paths { try f.write(path, "target\n") }
        let target = try await f.commit("Target")
        for path in paths { try f.write(path, "current\n") }
        _ = try await f.commit("Current")
        let runner = WorkEditAfterResetShard(root: f.root)
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: runner, environment: f.engine.environment))
        let plan = try await service.prepareReset(target: target, mode: .hard)
        await #expect(throws: RecoveryOutcomeUnknown.self) { _ = try await service.executeReset(plan) }
        #expect(await runner.changed)
        #expect(try await service.head() == target)
        #expect(
            try Data(contentsOf: f.root.appending(path: "file-0"))
                == Data("external after verified shard\n".utf8))
        #expect(try await service.recoveryRecords().first?.state == .needsVerification)
    }

    @Test func targetAndAdditionalDirtyPathsHaveDistinctRestorableBackupFiles() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "target\r\nlast")
        try f.write("additional", "unchanged\n")
        let target = try await f.commit("Target")
        try f.write("file", "current\r\nlast")
        _ = try await f.commit("Current")
        try f.write("additional", "separate private edit\r\nlast")
        _ = try await f.engine.run(["add", "--", "additional"], in: f.root)
        let index = try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index"))
        let plan = try await f.service.prepareReset(target: target, mode: .hard)
        let record = try await f.service.executeReset(plan)
        #expect(Set(record.files.map(\.path)) == ["file", "additional"])
        #expect(Set(record.files.map(\.storageName)).count == record.files.count)
        _ = try await f.service.executeRecoveryRestore(
            f.service.prepareRecoveryRestore(record, layer: .both))
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("current\r\nlast".utf8))
        #expect(
            try Data(contentsOf: f.root.appending(path: "additional"))
                == Data("separate private edit\r\nlast".utf8))
        #expect(try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index")) == index)
    }

    @Test func stagingBetweenCleanResetComparisonsRemainsAnUnknownOutcome() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "target\n")
        let target = try await f.commit("Target")
        try f.write("file", "current\n")
        _ = try await f.commit("Current")
        let runner = IndexEditDuringResetVerification(engine: f.engine, root: f.root)
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: runner, environment: f.engine.environment))
        let plan = try await service.prepareReset(target: target, mode: .hard)
        await #expect(throws: RecoveryOutcomeUnknown.self) { _ = try await service.executeReset(plan) }
        #expect(try await service.head() == target)
        #expect(
            try await f.engine.run(["show", ":file"], in: f.root).stdout
                == Data("external staged bytes\n".utf8))
        #expect(try await service.recoveryRecords().first?.state == .needsVerification)
    }

    @Test func corruptedFileInParallelCaptureRejectsAllRestorationBeforeAnyRepositoryWrite() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let paths = (0..<24).map { "file-\($0)" }
        for path in paths { try f.write(path, "target\n") }
        let target = try await f.commit("Target")
        for path in paths { try f.write(path, "original working\n") }
        _ = try await f.commit("Current")
        let record = try await f.service.executeReset(f.service.prepareReset(target: target, mode: .hard))
        let selected = try #require(record.files.last)
        let backup = f.root.appending(
            path: ".git/wegit-recovery/" + record.id.uuidString + "/" + selected.storageName)
        try Data("corrupted backup\n".utf8).write(to: backup)
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        await #expect(throws: ModelFailure.self) {
            try await f.service.prepareRecoveryRestore(record, layer: .both)
        }
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(try await f.service.head() == target)
        for path in paths {
            #expect(try Data(contentsOf: f.root.appending(path: path)) == Data("target\n".utf8))
        }
    }

    @Test func unexpectedRecordContentsPreventCleanupBeforeAnyProtectionRefIsRemoved() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "target\n")
        let target = try await f.commit("Target")
        try f.write("file", "current\n")
        let oldHead = try await f.commit("Current")
        let record = try await f.service.executeReset(f.service.prepareReset(target: target, mode: .hard))
        try f.write(".git/wegit-recovery/" + record.id.uuidString + "/unexpected", "retain this\n")
        await #expect(throws: ModelFailure.self) { try await f.service.removeRecoveryRecord(record) }
        let suffix = record.id.uuidString.lowercased()
        #expect(
            try await f.engine.run(["rev-parse", "refs/wegit/recovery/" + suffix], in: f.root).text
                .removingLastNewline == oldHead)
        #expect(
            try await f.engine.run(["rev-parse", "refs/wegit/recovery-index/" + suffix], in: f.root).text
                .removingLastNewline == record.indexTree)
    }

    @Test func changedIndexProtectionRefPreventsCleanupFromRemovingTheHeadProtectionRef() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "target\n")
        let target = try await f.commit("Target")
        try f.write("file", "current\n")
        let oldHead = try await f.commit("Current")
        let record = try await f.service.executeReset(f.service.prepareReset(target: target, mode: .hard))
        let suffix = record.id.uuidString.lowercased()
        let indexRef = "refs/wegit/recovery-index/" + suffix
        let targetTree = try await f.engine.run(["rev-parse", target + "^{tree}"], in: f.root).text
            .removingLastNewline
        _ = try await f.engine.run(
            ["update-ref", indexRef, targetTree, try #require(record.indexTree)], in: f.root)
        await #expect(throws: ModelFailure.self) { try await f.service.removeRecoveryRecord(record) }
        #expect(
            try await f.engine.run(["rev-parse", "refs/wegit/recovery/" + suffix], in: f.root).text
                .removingLastNewline == oldHead)
        #expect(try await f.service.recoveryRecords().contains { $0.id == record.id })
    }

    @Test func symbolicLinkRecoveryPreservesNondefaultPermissionsWithoutFollowingItsTarget() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("link", "regular target\n")
        let target = try await f.commit("Target")
        let path = f.root.appending(path: "link")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "missing-target")
        #expect(lchmod(path.path, 0o700) == 0)
        _ = try await f.commit("Link")
        let record = try await f.service.executeReset(f.service.prepareReset(target: target, mode: .hard))
        _ = try await f.service.executeRecoveryRestore(f.service.prepareRecoveryRestore(record))
        var info = stat()
        #expect(lstat(path.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == "missing-target")
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "missing-target").path))
    }

    @Test func stagedObjectsSurvivePruneAndRecoveryRestoresOriginalIndexPermissions() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "target\n")
        let target = try await f.commit("Target")
        try f.write("file", "current\n")
        let head = try await f.commit("Current")
        try f.write("file", "new staged bytes\n")
        try await f.service.stage(paths: ["file"], expectedHead: head)
        let staged = try await f.engine.run(["rev-parse", ":file"], in: f.root).text.removingLastNewline
        try f.write("file", "unstaged private bytes\r\nlast")
        let indexURL = f.service.location.gitDirectory.appending(path: "index")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        let original = try Data(contentsOf: indexURL)
        let record = try await f.service.executeReset(f.service.prepareReset(target: target, mode: .hard))
        #expect(record.indexTree != nil && record.indexMode == 0o600)
        _ = try await f.engine.run(["gc", "--prune=now"], in: f.root)
        _ = try await f.engine.run(["cat-file", "-e", staged], in: f.root)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: indexURL.path)
        _ = try await f.service.executeRecoveryRestore(f.service.prepareRecoveryRestore(record, layer: .both))
        #expect(try Data(contentsOf: indexURL) == original)
        #expect(try SelectedIndexSnapshot.read(location: f.service.location).mode == 0o600)
        #expect(
            try Data(contentsOf: f.root.appending(path: "file"))
                == Data("unstaged private bytes\r\nlast".utf8))
        #expect(try await f.service.head() == target)
    }

    @Test func splitIndexCompanionCanBeRestoredAfterItsOriginalFileWasRemoved() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "target\n")
        let target = try await f.commit("Target")
        try f.write("file", "current\n")
        let head = try await f.commit("Current")
        try f.write("file", "staged\n")
        try await f.service.stage(paths: ["file"], expectedHead: head)
        _ = try await f.engine.run(["update-index", "--split-index"], in: f.root)
        let original = try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index"))
        let record = try await f.service.executeReset(f.service.prepareReset(target: target, mode: .soft))
        let shared = try #require(record.sharedIndex)
        let path = f.service.location.gitDirectory.appending(path: shared.name)
        let originalShared = try Data(contentsOf: path)
        _ = try await f.engine.run(["update-index", "--no-split-index"], in: f.root)
        try FileManager.default.removeItem(at: path)
        _ = try await f.engine.run(["gc", "--prune=now"], in: f.root)
        _ = try await f.service.executeRecoveryRestore(
            f.service.prepareRecoveryRestore(record, layer: .index))
        #expect(try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index")) == original)
        #expect(try Data(contentsOf: path) == originalShared)
        #expect(try await f.engine.run(["show", ":file"], in: f.root).stdout == Data("staged\n".utf8))
        #expect(try await f.service.head() == target)
    }

    @Test func indexOnlyRecoveryDoesNotDependOnAnUnselectedDamagedWorkfileBackup() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "target\n")
        let target = try await f.commit("Target")
        try f.write("file", "current\n")
        _ = try await f.commit("Current")
        let original = try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index"))
        let record = try await f.service.executeReset(f.service.prepareReset(target: target, mode: .hard))
        let blob = f.service.location.gitDirectory.appending(
            path: "wegit-recovery/" + record.id.uuidString + "/" + record.files[0].storageName)
        try Data("damaged".utf8).write(to: blob)
        _ = try await f.service.executeRecoveryRestore(
            f.service.prepareRecoveryRestore(record, layer: .index))
        #expect(try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index")) == original)
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("target\n".utf8))
    }

    @Test func parallelSnapshotBatchesShareOneTotalByteBudget() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let paths = (0..<6).map { "file-\($0)" }
        for path in paths { try Data(repeating: 65, count: 100).write(to: f.root.appending(path: path)) }
        await #expect(throws: ModelFailure.self) {
            _ = try await RecoveryFileIO.captureAll(location: f.service.location, paths: paths, limit: 500)
        }
        for path in paths { #expect(try Data(contentsOf: f.root.appending(path: path)).count == 100) }
    }

    @Test func hardResetRejectsAnEditToAnOriginallyCleanFileOutsideItsBackupList() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("changed", "target\n")
        try f.write("clean", "unchanged\n")
        let target = try await f.commit("Target")
        try f.write("changed", "current\n")
        let head = try await f.commit("Current")
        let plan = try await f.service.prepareReset(target: target, mode: .hard)
        #expect(!plan.files.contains("clean"))
        try f.write("clean", "new private edit\n")
        let index = try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index"))
        await #expect(throws: ModelFailure.self) { _ = try await f.service.executeReset(plan) }
        #expect(try await f.service.head() == head)
        #expect(try Data(contentsOf: f.root.appending(path: "clean")) == Data("new private edit\n".utf8))
        #expect(try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index")) == index)
        #expect(try await f.service.recoveryRecords().isEmpty)
    }

    @Test func aNewSequencerMarkerInvalidatesResetBeforeAnyBackupOrWrite() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "target\n")
        let target = try await f.commit("Target")
        try f.write("file", "current\n")
        let head = try await f.commit("Current")
        let plan = try await f.service.prepareReset(target: target, mode: .hard)
        try f.write(".git/MERGE_HEAD", head + "\n")
        await #expect(throws: ModelFailure.self) { _ = try await f.service.executeReset(plan) }
        #expect(try await f.service.head() == head)
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("current\n".utf8))
        #expect(try await f.service.recoveryRecords().isEmpty)
    }

    @Test func externalIndexChangeAfterResetCannotBeReportedAsVerifiedSuccess() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "target\n")
        let target = try await f.commit("Target")
        try f.write("file", "external index\n")
        _ = try await f.commit("Current")
        let object = try await f.engine.run(["rev-parse", "HEAD:file"], in: f.root).text.removingLastNewline
        let runner = IndexEditAfterReset(engine: f.engine, root: f.root, object: object)
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: runner, environment: f.engine.environment))
        let plan = try await service.prepareReset(target: target, mode: .hard)
        await #expect(throws: RecoveryOutcomeUnknown.self) { _ = try await service.executeReset(plan) }
        #expect(try await service.head() == target)
        #expect(
            try await f.engine.run(["show", ":file"], in: f.root).stdout == Data("external index\n".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("target\n".utf8))
        #expect(try await service.recoveryRecords().first?.state == .needsVerification)
    }
    @Test func capturedReadOnlyFileRemainsAnIndependentSnapshotAfterAnInPlaceEdit() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let bytes = Data([0, 1, 13, 10, 255]) + Data(repeating: 67, count: 128 * 1024)
        let file = f.root.appending(path: "read-only")
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        let capture = try await RecoveryFileIO.capture(
            location: f.service.location, path: "read-only", name: "blob-0")
        #expect(capture.file.mode == 0o444)
        let snapshot = try #require(capture.snapshot)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: Data(repeating: 68, count: bytes.count))
        try writer.close()
        #expect(try Data(contentsOf: snapshot.url) == bytes)
        #expect(capture.file.sha256 == RecoveryFileIO.hash(bytes))
        await #expect(throws: ModelFailure.self) {
            try await RecoveryFileIO.verifyAll([capture], location: f.service.location)
        }
    }

    @Test func streamingFallbackPreservesBinaryBytesAndRejectsAnAlreadyCancelledCopy() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let bytes = Data(repeating: 255, count: 3 * 64 * 1024) + Data("\r\nlast".utf8)
        try bytes.write(to: f.root.appending(path: "binary"))
        let capture = try await RecoveryFileIO.capture(
            location: f.service.location, path: "binary", name: "blob-0")
        let snapshot = try #require(capture.snapshot)
        let output = f.root.appending(path: "streamed")
        let descriptor = Darwin.open(output.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        #expect(
            try RecoveryFileIO.copy(snapshot, to: descriptor, cancellation: IOCancellation())
                == capture.file.sha256)
        #expect(try Data(contentsOf: output) == bytes)
        let cancelled = IOCancellation()
        cancelled.cancel()
        #expect(throws: CancellationError.self) {
            _ = try RecoveryFileIO.copy(snapshot, to: descriptor, cancellation: cancelled)
        }
        #expect(try Data(contentsOf: output) == bytes)
    }

    @Test func aChangedSnapshotInvalidatesItsVerifiedDigestBeforeCreatingAClone() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "original bytes")
        let capture = try await RecoveryFileIO.capture(
            location: f.service.location, path: "file", name: "blob-0")
        let snapshot = try #require(capture.snapshot)
        #expect(snapshot.verifiedSHA256 == capture.file.sha256)
        try Data("modified bytes".utf8).write(to: snapshot.url)
        let directory = Darwin.open(f.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(directory >= 0)
        defer { Darwin.close(directory) }
        #expect(throws: ModelFailure.self) {
            _ = try RecoveryFileIO.copy(
                snapshot, directory: directory, name: "rejected", cancellation: IOCancellation())
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "rejected").path))
    }

    @Test func readBatchPinsOriginalBytesButRejectsAReplacedRepositoryAtItsBoundary() async throws {
        let f = try await Fixture.create()
        let moved = f.root.deletingLastPathComponent().appending(path: "WeGitReadFence-" + UUID().uuidString)
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: moved)
        }
        try f.write("file", "original\r\nbytes")
        let fence = try RepositoryReadFence(location: f.service.location)
        let reader = try RepositoryFileReader(
            location: f.service.location, path: "file", cancellation: IOCancellation(), readFence: fence)
        try FileManager.default.moveItem(at: f.root, to: moved)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false)
        try f.write("file", "foreign replacement")
        var bytes = Data()
        try reader.read(limit: 1024) { bytes.append($0) }
        #expect(bytes == Data("original\r\nbytes".utf8))
        #expect(throws: ModelFailure.self) { try fence.validate() }
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("foreign replacement".utf8))
    }

    @Test func exportPreservesBackupBytesAndRefusesToOverwriteAnExistingExport() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let base = try await f.commit("Base")
        try f.write("file", "current\n")
        _ = try await f.commit("Current")
        try f.write("file", "working\r\nlast")
        let record = try await f.service.executeReset(f.service.prepareReset(target: base, mode: .hard))
        let parent = f.root.appending(path: "exports")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let exported = try await f.service.exportRecoveryRecord(record, to: parent)
        #expect(
            try Data(contentsOf: exported.appending(path: record.files[0].storageName))
                == Data("working\r\nlast".utf8))
        #expect(
            try JSONDecoder().decode(
                RecoveryRecord.self, from: Data(contentsOf: exported.appending(path: "record.json")))
                == record)
        let original = try Data(contentsOf: exported.appending(path: "index"))
        await #expect(throws: ProcessFailure.self) {
            _ = try await f.service.exportRecoveryRecord(record, to: parent)
        }
        #expect(try Data(contentsOf: exported.appending(path: "index")) == original)
        #expect(try await f.service.head() == base)
    }

    @Test func resetToAMovedBranchReferenceRequiresANewPreview() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let base = try await f.commit("Base")
        try await f.service.createBranch("target", start: base, switchTo: false, expectedHead: base)
        try f.write("file", "current\n")
        let head = try await f.commit("Current")
        let plan = try await f.service.prepareReset(target: base, mode: .hard, sourceRef: "refs/heads/target")
        _ = try await f.engine.run(["update-ref", "refs/heads/target", head, base], in: f.root)
        await #expect(throws: ModelFailure.self) { _ = try await f.service.executeReset(plan) }
        #expect(try await f.service.head() == head)
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("current\n".utf8))
    }

    @Test func submoduleResetChangesOnlyGitlinksAndPreservesChildHeadAndDirtyBytes() async throws {
        let f = try await Fixture.create()
        let child = try await Fixture.create()
        defer {
            f.remove()
            child.remove()
        }
        try child.write("file", "child base\n")
        let childBase = try await child.commit("Child base")
        _ = try await f.engine.run(
            ["submodule", "add", child.root.path, "module"], in: f.root,
            configuration: [(key: "protocol.file.allow", value: "always")])
        let base = try await f.commit("Parent base")
        let module = f.root.appending(path: "module")
        for (key, value) in [
            ("user.name", "Child fixture"), ("user.email", "fixture@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", child.root.appending(path: "no-hooks").path),
        ] {
            _ = try await f.engine.run(["config", key, value], in: module)
        }
        try Data("child committed\n".utf8).write(to: module.appending(path: "file"))
        _ = try await f.engine.run(["commit", "-am", "Child current"], in: module)
        let childHead = try await f.engine.run(["rev-parse", "HEAD"], in: module).text.removingLastNewline
        _ = try await f.commit("Parent current")
        try Data("child private bytes\n".utf8).write(to: module.appending(path: "file"))
        _ = try await f.engine.run(["config", "submodule.recurse", "true"], in: f.root)
        let plan = try await f.service.prepareReset(target: base, mode: .hard)
        _ = try await f.service.executeReset(plan)
        #expect(
            try await f.engine.run(["rev-parse", ":module"], in: f.root).text.removingLastNewline == childBase
        )
        #expect(
            try await f.engine.run(["rev-parse", "HEAD"], in: module).text.removingLastNewline == childHead)
        #expect(try Data(contentsOf: module.appending(path: "file")) == Data("child private bytes\n".utf8))
    }

    @Test func untrackedFileAtANewGitlinkPathCannotBeRemovedByHardReset() async throws {
        let f = try await Fixture.create()
        let child = try await Fixture.create()
        defer {
            f.remove()
            child.remove()
        }
        try child.write("file", "child\n")
        let childHead = try await child.commit("Child")
        try f.write("file", "parent\n")
        let base = try await f.commit("Base")
        _ = try await f.engine.run(
            ["update-index", "--add", "--cacheinfo", "160000", childHead, "module"], in: f.root)
        let target = try await f.service.commit(message: "Add gitlink", amend: false, expectedHead: base)
        _ = try await f.engine.run(["reset", "--hard", base], in: f.root)
        try f.write("module", "private untracked file\n")
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.prepareReset(target: target, mode: .hard)
        }
        #expect(
            try Data(contentsOf: f.root.appending(path: "module")) == Data("private untracked file\n".utf8))
        #expect(try await f.service.head() == base)
    }

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
        let head = try await f.service.commit(message: "Remove file", amend: false, expectedHead: target)
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
        let originalVersion = try await f.service.reflogVersion()
        _ = try await f.engine.run(["switch", "-c", "deleted"], in: f.root)
        try f.write("file", "recoverable\n")
        let old = try await f.commit("Recoverable")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        _ = try await f.engine.run(["branch", "-D", "deleted"], in: f.root)
        #expect(try await f.service.reflogVersion() != originalVersion)
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
