import Foundation
import Testing

@testable import WeGitCore

struct MailPatchTests {
    @Test func rootCommitMailExportsAndImportsIntoAnUnbornRepository() async throws {
        let source = try await Fixture.create()
        let target = try await Fixture.create()
        defer {
            source.remove()
            target.remove()
        }
        try source.write("root.txt", "root\r\nlast")
        let root = try await source.commit("根提交\n\n原始正文")
        let original = try SelectedIndexSnapshot.read(location: source.service.location)
        let mail = try await source.service.exportMailPatches([root])
        #expect(try SelectedIndexSnapshot.read(location: source.service.location) == original)
        let plan = try await target.service.prepareMailPatches([
            MailPatchSource(name: "root.mbox", bytes: mail)
        ])
        #expect(plan.head == nil && plan.entries.count == 1)
        let done = try await target.service.executeMailPatches(plan)
        #expect(done.phase == .completed)
        #expect(try Data(contentsOf: target.root.appending(path: "root.txt")) == Data("root\r\nlast".utf8))
    }

    @Test func mergeMailExportRefusesToSubstituteAnotherCommit() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("base", "base\n")
        _ = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "feature"], in: f.root)
        try f.write("feature", "feature\n")
        _ = try await f.commit("Feature")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        try f.write("main", "main\n")
        _ = try await f.commit("Main")
        _ = try await f.engine.run(["merge", "--no-ff", "feature", "-m", "Merge"], in: f.root)
        let merge = try #require(await f.service.head())
        let index = try SelectedIndexSnapshot.read(location: f.service.location)
        await #expect(throws: ModelFailure.self) { _ = try await f.service.exportMailPatches([merge]) }
        #expect(try await f.service.head() == merge)
        #expect(try SelectedIndexSnapshot.read(location: f.service.location) == index)
    }

    @Test func orderedMailsPreserveAuthorsMessagesRawFilesAndModes() async throws {
        let f = try await MailFixture.create()
        defer { f.remove() }
        let service = f.target.service
        let before = try SelectedIndexSnapshot.read(location: service.location)
        let prepared = try await service.prepareMailPatches([f.mail])
        let moved = try prepared.moving(from: 1, to: 0)
        let plan = try moved.moving(from: 0, to: 1)
        #expect(plan.entries.count == 2)
        #expect(plan.entries[0].author == "邮件作者")
        #expect(plan.entries[0].body?.contains("正文 📬") == true)
        #expect(try SelectedIndexSnapshot.read(location: service.location) == before)
        #expect(try await service.head() == f.originalHead)
        let record = try await service.executeMailPatches(plan)
        #expect(record.phase == .completed && record.next == 2)
        for name in ["file.txt", "one.txt", "tool.sh", "data.bin"] {
            #expect(
                try Data(contentsOf: f.target.root.appending(path: name))
                    == Data(contentsOf: f.source.root.appending(path: name)))
        }
        let sourceMode =
            try FileManager.default.attributesOfItem(
                atPath: f.source.root.appending(path: "tool.sh").path)[.posixPermissions] as? NSNumber
        let targetMode =
            try FileManager.default.attributesOfItem(
                atPath: f.target.root.appending(path: "tool.sh").path)[.posixPermissions] as? NSNumber
        #expect(sourceMode == targetMode)
        let actual = try await f.target.engine.run(
            ["log", "-2", "--format=%an%x00%ae%x00%B", "--reverse"], in: f.target.root
        ).stdout
        let expected = try await f.source.engine.run(
            ["log", "-2", "--format=%an%x00%ae%x00%B", "--reverse"], in: f.source.root
        ).stdout
        #expect(actual == expected)
        try await service.closeMailPatches(record)
        #expect(try await service.mailPatchRecord() == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: service.location.gitDirectory.appending(
                    path: "wegit-mail-patches/" + record.id.uuidString
                ).path))
    }

    @Test func closingRetainsChangedCachedInputsAndTheOriginalMailbox() async throws {
        let f = try await MailFixture.create()
        defer { f.remove() }
        let external = f.source.root.appending(path: ".git/original.mbox")
        try f.bytes.write(to: external)
        let plan = try await f.target.service.prepareMailPatches([f.mail])
        let record = try await f.target.service.executeMailPatches(plan)
        let cached = f.target.service.location.gitDirectory.appending(
            path: "wegit-mail-patches/" + record.id.uuidString + "/0001")
        let changed = Data("changed cached input\n".utf8)
        try changed.write(to: cached)
        try await f.target.service.closeMailPatches(record)
        #expect(try await f.target.service.mailPatchRecord() == nil)
        #expect(try Data(contentsOf: cached) == changed)
        #expect(try Data(contentsOf: external) == f.bytes)
    }

    @Test func conflictEditorAndContinueWorkWithoutTheSourceCommitObject() async throws {
        let f = try await MailFixture.create(conflict: true)
        defer { f.remove() }
        let service = f.target.service
        let missing = try await f.target.engine.run(
            ["cat-file", "-e", f.commits[1]], in: f.target.root, accepted: [0, 1, 128])
        #expect(missing.exitCode != 0)
        let plan = try await service.prepareMailPatches([f.mail])
        let paused = try await service.executeMailPatches(plan)
        #expect(paused.phase == .waiting && paused.next == 1)
        #expect(try await service.status().sequencer == .mailApply)
        var document = try await service.readConflictEditor(
            path: "file.txt", expectedHead: try await service.head())
        #expect(document.base.bytes == Data("base\r\nlast".utf8))
        #expect(document.ours.bytes == Data("target\r\nlast".utf8))
        #expect(document.theirs.bytes == Data("source\r\nlast".utf8))
        document = try await service.saveConflictResult(document, text: "resolved\r\nlast")
        #expect(!(try await service.status()).conflicts.isEmpty)
        try await service.markConflictResolved(document)
        let ready = try await service.inspectMailPatches(paused)
        let done = try await service.recoverMailPatches(ready, action: "continue")
        #expect(done.phase == .completed && done.next == 2)
        #expect(
            try Data(contentsOf: f.target.root.appending(path: "file.txt")) == Data("resolved\r\nlast".utf8))
        #expect(try Data(contentsOf: f.target.root.appending(path: "one.txt")) == Data("one\r\nlast".utf8))
    }

    @Test func reopeningAndSkippingKeepsEarlierCommits() async throws {
        let f = try await MailFixture.create(conflict: true)
        defer { f.remove() }
        let plan = try await f.target.service.prepareMailPatches([f.mail])
        let paused = try await f.target.service.executeMailPatches(plan)
        let reopened = RepositoryService(location: f.target.service.location, engine: f.target.engine)
        let inspected = try await reopened.inspectMailPatches(paused)
        #expect(inspected.phase == .waiting && inspected.next == 1 && inspected.nativeToken != nil)
        let done = try await reopened.recoverMailPatches(inspected, action: "skip")
        #expect(done.phase == .completed && done.skipped == [1])
        #expect(
            try Data(contentsOf: f.target.root.appending(path: "file.txt")) == Data("target\r\nlast".utf8))
        #expect(try Data(contentsOf: f.target.root.appending(path: "one.txt")) == Data("one\r\nlast".utf8))
        let commits = try await f.target.engine.run(
            ["rev-list", "--count", f.originalHead + "..HEAD"], in: f.target.root
        ).text.removingLastNewline
        #expect(commits == "1")
    }

    @Test func missingStartReceiptIsReconciledBeforeAnyContinuation() async throws {
        let f = try await MailFixture.create(conflict: true)
        defer { f.remove() }
        let plan = try await f.target.service.prepareMailPatches([f.mail])
        let paused = try await f.target.service.executeMailPatches(plan)
        var interrupted = paused
        interrupted.phase = .running
        interrupted.next = 0
        interrupted.nativeToken = nil
        try MailPatchStore(location: f.target.service.location).save(interrupted, expected: paused)
        let reopened = RepositoryService(location: f.target.service.location, engine: f.target.engine)
        let head = try await reopened.head()
        let inspected = try await reopened.inspectMailPatches(interrupted)
        #expect(inspected.phase == .waiting && inspected.next == 1 && inspected.nativeToken != nil)
        #expect(try await reopened.head() == head)
        let done = try await reopened.recoverMailPatches(inspected, action: "skip")
        #expect(done.phase == .completed)
    }

    @Test func abortBackupSurvivesGcAndRestoresManualBytesAndAllIndexStages() async throws {
        let f = try await MailFixture.create(conflict: true)
        defer { f.remove() }
        let service = f.target.service
        let plan = try await service.prepareMailPatches([f.mail])
        let paused = try await service.executeMailPatches(plan)
        var document = try await service.readConflictEditor(
            path: "file.txt", expectedHead: try await service.head())
        document = try await service.saveConflictResult(document, text: "manual\r\nlast")
        let index = try SelectedIndexSnapshot.read(location: service.location).bytes
        let stage = try await f.target.engine.run(
            ["rev-parse", ":3:file.txt"], in: f.target.root
        ).text.removingLastNewline
        let ready = try await service.inspectMailPatches(paused)
        let aborted = try await service.recoverMailPatches(ready, action: "abort")
        #expect(aborted.phase == .aborted)
        #expect(try await service.head() == f.originalHead)
        #expect(!FileManager.default.fileExists(atPath: f.target.root.appending(path: "one.txt").path))
        let backup = try #require(
            try await service.recoveryRecords().first { $0.operation == "git-am-interruption-backup" })
        #expect(backup.conflictIndexTree != nil && backup.indexTree == nil)
        _ = try await f.target.engine.run(["gc", "--prune=now"], in: f.target.root)
        _ = try await f.target.engine.run(["cat-file", "-e", stage], in: f.target.root)
        let restore = try await service.prepareRecoveryRestore(backup, layer: .both)
        _ = try await service.executeRecoveryRestore(restore)
        #expect(try SelectedIndexSnapshot.read(location: service.location).bytes == index)
        #expect(
            try Data(contentsOf: f.target.root.appending(path: "file.txt")) == Data("manual\r\nlast".utf8))
    }

    @Test func replacedNativeMailRejectsRecoveryWithoutTouchingTheIndexOrFiles() async throws {
        let f = try await MailFixture.create(conflict: true)
        defer { f.remove() }
        let service = f.target.service
        let plan = try await service.prepareMailPatches([f.mail])
        let paused = try await service.executeMailPatches(plan)
        let native = service.location.gitDirectory.appending(path: "rebase-apply/0002")
        var mail = try Data(contentsOf: native)
        mail.append(Data("\nchanged by another process\n".utf8))
        try mail.write(to: native)
        let index = try SelectedIndexSnapshot.read(location: service.location)
        let file = try Data(contentsOf: f.target.root.appending(path: "file.txt"))
        let head = try await service.head()
        await #expect(throws: ModelFailure.self) {
            _ = try await service.recoverMailPatches(paused, action: "skip")
        }
        let inspected = try await service.inspectMailPatches(paused)
        #expect(inspected.phase == .needsVerification && inspected.nativeToken == nil)
        #expect(try SelectedIndexSnapshot.read(location: service.location) == index)
        #expect(try Data(contentsOf: f.target.root.appending(path: "file.txt")) == file)
        #expect(try await service.head() == head)
    }

    @Test func externalGitAmIsDistinctFromRebaseAndHasNoOwnedRecoveryControls() async throws {
        let f = try await MailFixture.create(conflict: true)
        defer { f.remove() }
        _ = try await f.target.engine.run(
            ["am", "--3way", "--keep-cr"], in: f.target.root, input: f.bytes, accepted: [0, 1, 128])
        let state = try await f.target.service.status()
        #expect(state.sequencer == .mailApply && state.mailPatch == nil)
        await #expect(throws: ModelFailure.self) {
            try await f.target.service.sequencer(continueOperation: true, expected: .rebase)
        }
        await #expect(throws: ModelFailure.self) {
            _ = try await f.target.service.readConflictEditor(path: "file.txt", expectedHead: state.head)
        }
    }

    @Test func stalePreviewAndHookMovedHeadCannotBeReportedAsSuccessful() async throws {
        let f = try await MailFixture.create()
        defer { f.remove() }
        let service = f.target.service
        let stale = try await service.prepareMailPatches([f.mail])
        try f.target.write("file.txt", "external\r\nlast")
        await #expect(throws: ModelFailure.self) { _ = try await service.executeMailPatches(stale) }
        #expect(try await service.mailPatchRecord() == nil)
        #expect(
            try Data(contentsOf: f.target.root.appending(path: "file.txt")) == Data("external\r\nlast".utf8))
        try f.target.write("file.txt", "base\r\nlast")
        let configurationPlan = try await service.prepareMailPatches([f.mail])
        _ = try await f.target.engine.run(["config", "commit.gpgsign", "true"], in: f.target.root)
        await #expect(throws: ModelFailure.self) {
            _ = try await service.executeMailPatches(configurationPlan)
        }
        #expect(try await service.mailPatchRecord() == nil)
        _ = try await f.target.engine.run(["config", "commit.gpgsign", "false"], in: f.target.root)
        let hooks = service.location.gitDirectory.appending(path: "test-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
        let hook = hooks.appending(path: "post-applypatch")
        try Data(("#!/bin/sh\n/usr/bin/git reset --hard " + f.originalHead + "\n").utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try await f.target.engine.run(["config", "core.hooksPath", hooks.path], in: f.target.root)
        let plan = try await service.prepareMailPatches([f.mail])
        let result = try await service.executeMailPatches(plan)
        #expect(result.phase == .needsVerification)
        #expect(try await service.head() == f.originalHead)
        #expect(try await service.mailPatchRecord() == result)
    }
}

private struct MailFixture {
    let source: Fixture
    let target: Fixture
    let originalHead: String
    let commits: [String]
    let bytes: Data
    var mail: MailPatchSource { MailPatchSource(name: "ordered.mbox", bytes: bytes) }

    static func create(conflict: Bool = false) async throws -> MailFixture {
        let source = try await Fixture.create()
        let target = try await Fixture.create()
        do {
            for f in [source, target] {
                _ = try await f.engine.run(["config", "core.autocrlf", "false"], in: f.root)
                try f.write("file.txt", "base\r\nlast")
                _ = try await f.commit(f.root == source.root ? "Source base" : "Target base")
            }
            _ = try await source.engine.run(["config", "user.name", "邮件作者"], in: source.root)
            _ = try await source.engine.run(
                ["config", "user.email", "author@example.invalid"], in: source.root)
            try source.write("one.txt", "one\r\nlast")
            try source.write("tool.sh", "#!/bin/sh\nprintf fixture\n")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: source.root.appending(path: "tool.sh").path)
            try Data((0..<256).map { UInt8($0) }).write(to: source.root.appending(path: "data.bin"))
            let first = try await source.commit("创建文件\n\n正文 📬\n保留换行")
            try source.write("file.txt", "source\r\nlast")
            let second = try await source.commit("修改文件\n\n第二封邮件正文")
            if conflict {
                try target.write("file.txt", "target\r\nlast")
                _ = try await target.commit("Target divergence")
            }
            let original = try #require(await target.service.head())
            let bytes = try await source.service.exportMailPatches([first, second])
            return MailFixture(
                source: source, target: target, originalHead: original, commits: [first, second], bytes: bytes
            )
        } catch {
            source.remove()
            target.remove()
            throw error
        }
    }

    func remove() {
        source.remove()
        target.remove()
    }
}
