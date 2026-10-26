import Foundation
import Testing

@testable import WeGitCore

private struct LostOperationReply: ProcessRunning {
    let operation: SingleCommitOperation
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await ProcessRunner().run(request)
        let committed =
            request.arguments.contains(operation.rawValue)
            && (operation == .cherryPick || request.arguments.contains("--continue"))
        if committed, result.exitCode == 0 { throw ProcessFailure.timedOut }
        return result
    }
}

private actor SingleCommitPermit {
    var entered = false
    func enter() { entered = true }
}

struct SingleCommitTests {
    @Test func previewAndRevertPreserveOriginalObjectsAndRawBytes() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("base", "base\n")
        let base = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "source"], in: f.root)
        let path = "中文\n[path].txt"
        try f.write(path, "CRLF\r\nlast line")
        let source = try await f.commit("Source")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let objectPaths =
            FileManager.default.enumerator(atPath: f.root.appending(path: ".git/objects").path)?.allObjects
            as? [String]
        let plan = try await f.service.prepareSingleCommit(.cherryPick, target: source)
        #expect(plan.files.map(\.path) == [path])
        #expect(try await f.service.head() == base)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(
            (FileManager.default.enumerator(atPath: f.root.appending(path: ".git/objects").path)?.allObjects
                as? [String])?.sorted() == objectPaths?.sorted())
        guard case .committed(let picked) = try await f.service.executeSingleCommit(plan) else {
            throw ModelFailure.changed
        }
        #expect(try Data(contentsOf: f.root.appending(path: path)) == Data("CRLF\r\nlast line".utf8))
        let undo = try await f.service.prepareSingleCommit(.revert, target: picked)
        guard case .committed(let reverted) = try await f.service.executeSingleCommit(undo) else {
            throw ModelFailure.changed
        }
        #expect(try await f.service.readCommit(reverted).parents == [picked])
        #expect(try await f.service.readCommit(picked).id == picked)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: path).path))
        #expect(try await f.service.status().files.isEmpty)
    }

    @Test(arguments: SingleCommitOperation.allCases, [false, true])
    func conflictsRemainRecoverableAfterReopening(operation: SingleCommitOperation, abort: Bool) async throws
    {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let base = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "source"], in: f.root)
        try f.write("file", "selected\n")
        let source = try await f.commit("Selected")
        if operation == .cherryPick { _ = try await f.engine.run(["switch", "main"], in: f.root) }
        try f.write("file", "current\n")
        let before = try await f.commit("Current")
        let plan = try await f.service.prepareSingleCommit(operation, target: source)
        #expect(plan.conflictPaths == ["file"])
        guard case .conflicts(1) = try await f.service.executeSingleCommit(plan) else {
            throw ModelFailure.changed
        }
        let reopened = try await RepositoryService(
            location: RepositoryService.discover(f.root, engine: f.engine), engine: f.engine)
        let recovery = try #require(try await reopened.status().singleCommitRecovery)
        #expect(recovery.target == source && recovery.head == before)
        if abort {
            try await reopened.recoverSingleCommit(continueOperation: false, expected: recovery)
            #expect(try await reopened.head() == before)
            #expect(try String(contentsOf: f.root.appending(path: "file"), encoding: .utf8) == "current\n")
        } else {
            await #expect(throws: ModelFailure.self) {
                try await reopened.recoverSingleCommit(continueOperation: true, expected: recovery)
            }
            try f.write("file", "resolution\n")
            try await reopened.markResolved(path: "file", expectedHead: before)
            try await reopened.recoverSingleCommit(continueOperation: true, expected: recovery)
            let head = try #require(try await reopened.head())
            #expect(try await reopened.readCommit(head).parents == [before])
            #expect(try String(contentsOf: f.root.appending(path: "file"), encoding: .utf8) == "resolution\n")
        }
        #expect(try await reopened.status().sequencer == .none)
        #expect(try await reopened.readCommit(base).id == base)
        #expect(try await reopened.readCommit(source).id == source)
    }

    @Test func ignoredRelocatedDestinationsCannotBeOverwritten() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("old/base", "base\n")
        _ = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "source"], in: f.root)
        try f.write("old/private", "selected\n")
        let source = try await f.commit("Selected")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        _ = try await f.engine.run(["mv", "old", "new"], in: f.root)
        let before = try await f.service.commit(
            message: "Rename directory", amend: false, expectedHead: f.service.head())
        try f.write(".git/info/exclude", "new/private\n")
        try f.write("new/private", "uncommitted ignored data\n")
        #expect(try await f.service.status().files.isEmpty)
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.prepareSingleCommit(.cherryPick, target: source)
        }
        #expect(try await f.service.head() == before)
        #expect(
            try String(contentsOf: f.root.appending(path: "new/private"), encoding: .utf8)
                == "uncommitted ignored data\n")
    }

    @Test func confirmedBranchAndHeadAndIgnoredFilesAreRevalidated() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("base", "base\n")
        let base = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "source"], in: f.root)
        try f.write("added", "incoming\n")
        let source = try await f.commit("Source")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        let plan = try await f.service.prepareSingleCommit(.cherryPick, target: source)
        _ = try await f.engine.run(["switch", "-c", "same-head"], in: f.root)
        await #expect(throws: ModelFailure.self) { _ = try await f.service.executeSingleCommit(plan) }
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        try f.write(".git/info/exclude", "added\n")
        try f.write("added", "private\n")
        await #expect(throws: ModelFailure.self) { _ = try await f.service.executeSingleCommit(plan) }
        #expect(try await f.service.head() == base)
        #expect(try String(contentsOf: f.root.appending(path: "added"), encoding: .utf8) == "private\n")
        try f.write("base", "another change\n")
        _ = try await f.commit("Another commit")
        await #expect(throws: ModelFailure.self) { _ = try await f.service.executeSingleCommit(plan) }
    }

    @Test(arguments: SingleCommitOperation.allCases, [false, true])
    func failedHooksAndSigningRetainGitRecovery(operation: SingleCommitOperation, signing: Bool) async throws
    {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("base", "base\n")
        _ = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "source"], in: f.root)
        try f.write("added", "incoming\n")
        let source = try await f.commit("Source")
        if operation == .cherryPick { _ = try await f.engine.run(["switch", "main"], in: f.root) }
        let plan = try await f.service.prepareSingleCommit(operation, target: source)
        if signing {
            for (key, value) in [
                ("commit.gpgsign", "true"), ("gpg.program", "/usr/bin/false"), ("gpg.format", "openpgp"),
            ] {
                _ = try await f.engine.run(["config", key, value], in: f.root)
            }
        } else {
            try f.write(".git/fixture-hooks/prepare-commit-msg", "#!/bin/sh\nexit 29\n")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: f.root.appending(path: ".git/fixture-hooks/prepare-commit-msg").path)
            _ = try await f.engine.run(
                ["config", "core.hooksPath", f.root.appending(path: ".git/fixture-hooks").path], in: f.root)
        }
        guard case .pending = try await f.service.executeSingleCommit(plan) else {
            throw ModelFailure.changed
        }
        #expect(try await f.service.head() == plan.head)
        let recovery = try #require(try await f.service.status().singleCommitRecovery)
        if signing {
            _ = try await f.engine.run(["config", "commit.gpgsign", "false"], in: f.root)
        } else {
            try f.write(".git/fixture-hooks/prepare-commit-msg", "#!/bin/sh\nexit 0\n")
        }
        try await f.service.recoverSingleCommit(continueOperation: true, expected: recovery)
        #expect(try await f.service.status().sequencer == .none)
        let after = try #require(try await f.service.head())
        #expect(try await f.service.readCommit(after).parents == [plan.head])
    }

    @Test(arguments: SingleCommitOperation.allCases)
    func lostRepliesCannotProduceSuccessOrDuplicateWrites(operation: SingleCommitOperation) async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("base", "base\n")
        _ = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "source"], in: f.root)
        try f.write("added", "incoming\n")
        let source = try await f.commit("Source")
        if operation == .cherryPick { _ = try await f.engine.run(["switch", "main"], in: f.root) }
        let plan = try await f.service.prepareSingleCommit(operation, target: source)
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(
                runner: LostOperationReply(operation: operation), environment: f.engine.environment))
        await #expect(throws: SingleCommitOutcomeUnknown.self) {
            _ = try await service.executeSingleCommit(plan)
        }
        let head = try #require(try await f.service.head())
        #expect(head != plan.head)
        await #expect(throws: ModelFailure.self) { _ = try await service.executeSingleCommit(plan) }
        #expect(try await f.service.head() == head)
    }

    @Test func replacedRecoveryMarkerAndExternalQueuesAreNotDriven() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        _ = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "source"], in: f.root)
        try f.write("file", "source\n")
        let first = try await f.commit("First")
        try f.write("second", "second\n")
        let second = try await f.commit("Second")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        try f.write("file", "main\n")
        let before = try await f.commit("Main")
        let plan = try await f.service.prepareSingleCommit(.cherryPick, target: first)
        _ = try await f.service.executeSingleCommit(plan)
        let recovery = try #require(try await f.service.status().singleCommitRecovery)
        try Data((first + "\n").utf8).write(
            to: f.root.appending(path: ".git/CHERRY_PICK_HEAD"), options: .atomic)
        await #expect(throws: ModelFailure.self) {
            try await f.service.recoverSingleCommit(continueOperation: false, expected: recovery)
        }
        #expect(try await f.service.head() == before)
        _ = try await f.engine.run(["cherry-pick", "--abort"], in: f.root)
        _ = try await f.engine.run(["cherry-pick", first, second], in: f.root, accepted: [1])
        let state = try await f.service.status()
        #expect(state.sequencer == .cherryPick)
        #expect(state.singleCommitRecovery == nil)
    }

    @Test func cancellingAQueuedCommitNeverAcquiresAWritePermit() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("base", "base\n")
        let base = try await f.commit("Base")
        try f.write("added", "added\n")
        let target = try await f.commit("Added")
        let plan = try await f.service.prepareSingleCommit(.revert, target: target)
        let gate = SingleCommitPermit()
        let holder = Task {
            try await f.service.sharedQueue.perform {
                await gate.enter()
                try await Task.sleep(for: .seconds(30))
            }
        }
        defer { holder.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.entered), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.entered)
        let pending = Task { try await f.service.executeSingleCommit(plan) }
        try await Task.sleep(for: .milliseconds(30))
        pending.cancel()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        holder.cancel()
        _ = await holder.result
        #expect(try await f.service.head() == target)
        #expect(try await f.service.status().sequencer == .none)
        #expect(try await f.service.readCommit(base).id == base)
    }
}
