import Foundation
import Testing

@testable import WeGitCore

struct RebaseTests {
    @Test func batchedLinearTreesMatchFreshMetadataIncludingEmptyChanges() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("a", "original\n")
        let base = try await f.commit("Base")
        try f.write("a", "changed\n")
        let path = "中文\nsource"
        try f.write(path, "new bytes\n")
        let added = try await f.commit("Add and modify")
        try FileManager.default.removeItem(at: f.root.appending(path: "a"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: f.root.appending(path: path).path)
        let removed = try await f.commit("Delete and change mode")
        _ = try await f.engine.run(["commit", "--allow-empty", "-m", "Empty changes"], in: f.root)
        let empty = try #require(try await f.service.head())
        let ids = [added, removed, empty]
        let commits = try await f.service.rebaseCommits(ids)
        let metadata = RebaseTreeMetadata(root: f.root)
        #expect(try await metadata.preloadLinear(commits, base: base, target: base, engine: f.engine))
        let fresh = RebaseTreeMetadata(root: f.root)
        for id in [base] + ids {
            #expect(try await metadata.entries(id, engine: f.engine) == fresh.entries(id, engine: f.engine))
        }
    }

    @Test func sharedBlobMetadataRetainsEmptyBinarySymlinkAndLiteralPaths() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let bytes = Data([0, 255, 10, 13, 1, 128])
        let copy = "copy\n中文"
        try bytes.write(to: f.root.appending(path: "binary"))
        try bytes.write(to: f.root.appending(path: copy))
        try f.write("empty", "")
        try FileManager.default.createSymbolicLink(
            atPath: f.root.appending(path: "link").path, withDestinationPath: "binary")
        let base = try await f.commit("Shared binary metadata")
        let metadata = RebaseTreeMetadata(root: f.root)
        let entries = try await metadata.entries(base, engine: f.engine)
        #expect(entries.count == 4)
        #expect(entries["binary"]?.bytes == bytes.count && entries[copy] == entries["binary"])
        #expect(entries["empty"]?.bytes == 0 && entries["empty"]?.mode == "100644")
        #expect(entries["link"]?.mode == "120000")
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: f.root.appending(path: "link").path)
        #expect(entries["link"]?.bytes == destination.utf8.count)
        var changed = bytes
        changed.append(contentsOf: [2, 3, 4])
        try changed.write(to: f.root.appending(path: "binary"))
        let next = try await f.commit("New blob alongside reused objects")
        let refreshed = try await metadata.entries(next, engine: f.engine)
        #expect(refreshed["binary"]?.bytes == changed.count)
        #expect(refreshed[copy] == entries[copy] && refreshed["link"] == entries["link"])
    }

    @Test func freshPreparationRefusesMissingPreviouslyReadBlobWithoutWrites() async throws {
        let (f, target, original, _) = try await fork()
        defer { f.remove() }
        _ = try await f.service.prepareRebase(target: target)
        let object = try await f.engine.run(["rev-parse", original + ":file"], in: f.root)
            .text.removingLastNewline
        let objectPath = f.root.appending(path: ".git/objects")
            .appending(path: String(object.prefix(2))).appending(path: String(object.dropFirst(2)))
        try FileManager.default.removeItem(at: objectPath)
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        await #expect(throws: ModelFailure.self) { _ = try await f.service.prepareRebase(target: target) }
        #expect(try await f.service.head() == original)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("base\n".utf8))
    }

    @Test func emptyTargetTreeCanReplayAnAdditionWithoutChangingPreviewIndex() async throws {
        let (f, _, original, _) = try await fork()
        defer { f.remove() }
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        _ = try await f.engine.run(["rm", "-r", "--", "."], in: f.root)
        _ = try await f.engine.run(["commit", "-m", "Empty target tree"], in: f.root)
        _ = try await f.engine.run(["switch", "feature"], in: f.root)
        let target = try #require(try await f.service.branches().first { $0.name == "main" })
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let plan = try await f.service.prepareRebase(target: target)
        #expect(plan.head == original && plan.commits.count == 1 && plan.conflictPaths.isEmpty)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        guard case .completed(let head) = try await f.service.executeRebase(plan) else {
            throw ModelFailure.changed
        }
        #expect(try await f.service.readCommit(head).parents == [target.oid])
        #expect(try Data(contentsOf: f.root.appending(path: "feature")) == Data("feature\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "file").path))
    }

    @Test func boundedTreeDeltaMatchesFreshMetadataForAddDeleteAndModeChanges() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("a", "original\n")
        let base = try await f.commit("Base")
        try f.write("a", "changed\n")
        try f.write("中文\nnew", "new bytes\n")
        let changed = try await f.commit("Add and change")
        let changedTree = try await f.service.singleCommitTree(changed, engine: f.engine)
        let metadata = RebaseTreeMetadata(root: f.root)
        _ = try await metadata.entries(base, engine: f.engine)
        try await metadata.derive(changedTree, from: base, engine: f.engine)
        let direct = RebaseTreeMetadata(root: f.root)
        #expect(
            try await metadata.entries(changedTree, engine: f.engine)
                == direct.entries(changedTree, engine: f.engine))
        try FileManager.default.removeItem(at: f.root.appending(path: "a"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: f.root.appending(path: "中文\nnew").path)
        let removed = try await f.commit("Delete and mode")
        let removedTree = try await f.service.singleCommitTree(removed, engine: f.engine)
        try await metadata.derive(removedTree, from: changedTree, engine: f.engine)
        #expect(
            try await metadata.entries(removedTree, engine: f.engine)
                == direct.entries(removedTree, engine: f.engine))
    }

    private func fork(conflict: Bool = false, author: String = "WeGit Tests") async throws
        -> (Fixture, GitBranch, String, String)
    {
        let f = try await Fixture.create()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.root.path)
        _ = try await f.engine.run(["config", "user.name", author], in: f.root)
        try f.write("file", "base\n")
        try f.write(".gitignore", "onto\n")
        let base = try await f.commit("Base")
        _ = try await f.engine.run(["switch", "-c", "feature"], in: f.root)
        try f.write(conflict ? "file" : "feature", "feature\n")
        let original = try await f.commit("Feature")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        try f.write(conflict ? "file" : "onto", "target\n")
        _ = try await f.engine.run(["add", "-f", conflict ? "file" : "onto"], in: f.root)
        _ = try await f.engine.run(["commit", "-m", "Target"], in: f.root)
        _ = try await f.engine.run(["switch", "feature"], in: f.root)
        let target = try #require(try await f.service.branches().first { $0.name == "main" })
        return (f, target, original, base)
    }

    @Test func fixedPreviewPreservesObjectsAndActualExecutionProtectsOriginal() async throws {
        let (f, target, original, base) = try await fork()
        defer { f.remove() }
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let objects =
            (FileManager.default.enumerator(atPath: f.root.appending(path: ".git/objects").path)?.allObjects
            as? [String])?.sorted()
        let plan = try await f.service.prepareRebase(target: target)
        #expect(plan.head == original && plan.startingPoint == base && plan.commits.map(\.id) == [original])
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(
            (FileManager.default.enumerator(atPath: f.root.appending(path: ".git/objects").path)?.allObjects
                as? [String])?.sorted() == objects)
        guard case .completed(let head) = try await f.service.executeRebase(plan) else {
            throw ModelFailure.changed
        }
        #expect(try await f.service.readCommit(head).parents == [target.oid])
        #expect(try await f.service.status().branch == "feature")
        #expect(
            try await f.engine.run(
                ["for-each-ref", "--format=%(objectname)", "refs/wegit/rebase/"], in: f.root
            ).text.removingLastNewline == original)
        let contained = try await f.service.prepareRebase(target: target)
        guard case .unchanged = try await f.service.executeRebase(contained) else {
            throw ModelFailure.changed
        }
        #expect(try await f.service.head() == head)
    }

    @Test(arguments: ["target", "branch", "index"])
    func changedConfirmationNeverWrites(kind: String) async throws {
        let (f, target, original, base) = try await fork()
        defer { f.remove() }
        let plan = try await f.service.prepareRebase(target: target)
        switch kind {
        case "target": _ = try await f.engine.run(["update-ref", target.id, base, target.oid], in: f.root)
        case "branch": _ = try await f.engine.run(["switch", "-c", "same-tip"], in: f.root)
        default: _ = try await f.engine.run(["update-index", "--assume-unchanged", "file"], in: f.root)
        }
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        await #expect(throws: ModelFailure.self) { _ = try await f.service.executeRebase(plan) }
        #expect(try await f.service.head() == original)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(
            try await f.engine.run(["for-each-ref", "--format=%(refname)", "refs/wegit/rebase/"], in: f.root)
                .stdout.isEmpty)
    }

    @Test func cleanStatusDoesNotAuthorizeIgnoredOverwrite() async throws {
        let (f, target, original, _) = try await fork()
        defer { f.remove() }
        let privateBytes = Data("private ignored contents\n".utf8)
        try privateBytes.write(to: f.root.appending(path: "onto"))
        #expect(try await f.service.status().files.isEmpty)
        await #expect(throws: ModelFailure.self) { _ = try await f.service.prepareRebase(target: target) }
        #expect(try Data(contentsOf: f.root.appending(path: "onto")) == privateBytes)
        #expect(try await f.service.head() == original)
    }

    @Test(arguments: [false, true])
    func conflictRecoverySurvivesReopening(abort: Bool) async throws {
        let (f, target, original, _) = try await fork(conflict: true, author: "WeGit 'Quoted' Tests")
        defer { f.remove() }
        let plan = try await f.service.prepareRebase(target: target)
        guard case .conflicts(let recovery, 1) = try await f.service.executeRebase(plan) else {
            throw ModelFailure.changed
        }
        #expect(recovery.originalHead == original && recovery.branchRef == "refs/heads/feature")
        let reopened = RepositoryService(
            location: try await RepositoryService.discover(f.root, engine: f.engine), engine: f.engine)
        if abort {
            let expected = try #require(try await reopened.rebaseRecovery())
            guard
                case .aborted(let head) = try await reopened.recoverRebase(
                    continueOperation: false, expected: expected)
            else { throw ModelFailure.changed }
            #expect(head == original)
            #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("feature\n".utf8))
        } else {
            try f.write("file", "resolved\n")
            try await reopened.markResolved(path: "file", expectedHead: recovery.head)
            let expected = try #require(try await reopened.rebaseRecovery())
            #expect(expected.canContinue)
            let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
            let ready = try await reopened.prepareRebaseRecovery(.continueOperation, expected: expected)
            #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
            guard case .completed(let head) = try await reopened.executeRebaseRecovery(ready) else {
                throw ModelFailure.changed
            }
            #expect(try await reopened.readCommit(head).parents == [target.oid])
            #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("resolved\n".utf8))
        }
        #expect(try await reopened.status().sequencer == .none)
        #expect(try await reopened.status().branch == "feature")
    }

    @Test func externalAuthorCommandsAreNotExecutedAndConflictsStayReadable() async throws {
        let (f, target, original, _) = try await fork(conflict: true)
        defer { f.remove() }
        guard case .conflicts = try await f.service.executeRebase(f.service.prepareRebase(target: target))
        else { throw ModelFailure.changed }
        let script = f.root.appending(path: ".git/rebase-merge/author-script")
        let marker = f.root.appending(path: "unexpected-author-program")
        var bytes = try Data(contentsOf: script)
        bytes.append(Data(("\n/usr/bin/touch '" + marker.path + "'\n").utf8))
        try bytes.write(to: script)
        let state = try await f.service.status()
        let expected = try #require(state.rebaseRecovery)
        #expect(state.conflicts.map(\.path) == ["file"] && !expected.canContinue && expected.canAbort)
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.recoverRebase(continueOperation: true, expected: expected)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        guard
            case .aborted(let head) = try await f.service.recoverRebase(
                continueOperation: false, expected: expected)
        else { throw ModelFailure.changed }
        #expect(head == original)
    }

    @Test func previewDoesNotLaunchConfiguredMergeDrivers() async throws {
        let (f, target, original, _) = try await fork(conflict: true)
        defer { f.remove() }
        try f.write(".gitattributes", "file merge=probe\n")
        _ = try await f.commit("Configure merge attribute")
        let driver = f.root.appending(path: ".git/rebase-probe-driver")
        try FileManager.default.createDirectory(
            at: driver.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = f.root.appending(path: "unexpected-driver")
        try Data(("#!/bin/sh\n/usr/bin/touch '" + marker.path + "'\nexit 1\n").utf8).write(to: driver)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: driver.path)
        _ = try await f.engine.run(["config", "merge.probe.driver", driver.path], in: f.root)
        let before = try await f.service.head()
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        _ = try await f.service.prepareRebase(target: target)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try await f.service.head() == before)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(before != original)
    }

    @Test func rescheduledSigningFailureCannotEraseAdditionalEdits() async throws {
        let (f, target, _, _) = try await fork()
        defer { f.remove() }
        _ = try await f.engine.run(["config", "commit.gpgsign", "true"], in: f.root)
        _ = try await f.engine.run(["config", "gpg.program", "/usr/bin/false"], in: f.root)
        guard
            case .paused(let paused, _) = try await f.service.executeRebase(
                f.service.prepareRebase(target: target))
        else { throw ModelFailure.changed }
        #expect(paused.rescheduledCommit != nil)
        let edited = Data("feature with manual edits\n".utf8)
        try edited.write(to: f.root.appending(path: "feature"))
        try await f.service.markResolved(path: "feature", expectedHead: paused.head)
        let expected = try #require(try await f.service.rebaseRecovery())
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.prepareRebaseRecovery(.continueOperation, expected: expected)
        }
        #expect(try Data(contentsOf: f.root.appending(path: "feature")) == edited)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
    }
}
