import Darwin
import Foundation
import Testing

@testable import WeGitCore

struct PatchTests {
    @Test func workingPatchRoundTripPreservesBinaryCRLFAndUnrelatedIndexAndRecovery() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let old = Data("a\r\nb\r\nlast".utf8)
        let new = Data("a\r\nB\r\nlast".utf8)
        let oldBinary = Data([0, 1, 2, 255])
        let newBinary = Data([0, 7, 8, 254])
        try old.write(to: f.root.appending(path: "file"))
        try oldBinary.write(to: f.root.appending(path: "binary"))
        try f.write("other", "old\n")
        let head = try await f.commit()
        try new.write(to: f.root.appending(path: "file"))
        try newBinary.write(to: f.root.appending(path: "binary"))
        let patch = try await f.service.exportPatch(layer: .unstaged)
        try old.write(to: f.root.appending(path: "file"))
        try oldBinary.write(to: f.root.appending(path: "binary"))
        try f.write("other", "staged\n")
        try await f.service.stage(paths: ["other"], expectedHead: head)
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let plan = try await f.service.preparePatch(patch)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        let record = try await f.service.executePatch(plan)
        #expect(record.state == .succeeded)
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == new)
        #expect(try Data(contentsOf: f.root.appending(path: "binary")) == newBinary)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        _ = try await f.service.executeRecoveryRestore(
            f.service.prepareRecoveryRestore(record, layer: .worktree))
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == old)
        #expect(try Data(contentsOf: f.root.appending(path: "binary")) == oldBinary)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(try await f.service.head() == head)
    }

    @Test func cachedRenameWithQuotedUnicodeAndNewlinePathsProtectsBothEndsAndOriginalIndexObjects()
        async throws
    {
        let f = try await Fixture.create()
        defer { f.remove() }
        let old = "old 中文\nname"
        let new = "new 中文\nname"
        let bytes = Data("one\r\ntwo\r\nlast".utf8)
        try bytes.write(to: f.root.appending(path: old))
        try f.write("other", "original\n")
        let head = try await f.commit()
        try FileManager.default.moveItem(at: f.root.appending(path: old), to: f.root.appending(path: new))
        _ = try await f.engine.run(["add", "--all"], in: f.root)
        let patch = try await f.service.exportPatch(layer: .staged)
        _ = try await f.engine.run(["reset", "--hard", head], in: f.root)
        try f.write("other", "unique staged bytes\n")
        try await f.service.stage(paths: ["other"], expectedHead: head)
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let plan = try await f.service.preparePatch(patch, layer: .index)
        #expect(plan.files.contains { $0.path == new && $0.oldPath == old })
        let record = try await f.service.executePatch(plan)
        #expect(try await f.engine.run(["show", ":" + new], in: f.root).stdout == bytes)
        #expect(try Data(contentsOf: f.root.appending(path: old)) == bytes)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: new).path))
        #expect(record.pendingIndexTree == nil && record.pendingObjectBytes == nil)
        _ = try await f.engine.run(["gc", "--prune=now"], in: f.root)
        _ = try await f.service.executeRecoveryRestore(
            f.service.prepareRecoveryRestore(record, layer: .index))
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(
            try await f.engine.run(["show", ":other"], in: f.root).stdout
                == Data("unique staged bytes\n".utf8))
    }

    @Test func bothLayersIncludeExecutableModeAndRequireAConsistentSource() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "old\n")
        let head = try await f.commit()
        try f.write("file", "new\n")
        #expect(chmod(f.root.appending(path: "file").path, 0o755) == 0)
        try await f.service.stage(paths: ["file"], expectedHead: head)
        let patch = try await f.service.exportPatch(layer: .staged)
        _ = try await f.engine.run(["reset", "--hard", head], in: f.root)
        let plan = try await f.service.preparePatch(patch, layer: .both)
        _ = try await f.service.executePatch(plan)
        var mode = stat()
        #expect(lstat(f.root.appending(path: "file").path, &mode) == 0 && mode.st_mode & 0o777 == 0o755)
        #expect(
            try await f.engine.run(["ls-files", "--stage", "--", "file"], in: f.root).text.hasPrefix(
                "100755 "))
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("new\n".utf8))
        #expect(try await f.service.head() == head)
    }

    @Test func externalEditRejectsPatchBeforeAnyBackupOrFileInstallation() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "old\n")
        _ = try await f.commit()
        try f.write("file", "new\n")
        let patch = try await f.service.exportPatch(layer: .unstaged)
        try f.write("file", "old\n")
        let plan = try await f.service.preparePatch(patch)
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        try f.write("file", "external\n")
        await #expect(throws: ModelFailure.self) { try await f.service.executePatch(plan) }
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("external\n".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(try await f.service.recoveryRecords().isEmpty)
    }

    @Test func traversalAndConfiguredFiltersAreRejectedWithoutExecutingTheFilter() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "old\n")
        _ = try await f.commit()
        let outside = Data(
            "diff --git a/../../outside b/../../outside\n--- a/../../outside\n+++ b/../../outside\n@@ -1 +1 @@\n-old\n+new\n"
                .utf8)
        await #expect(throws: ModelFailure.self) { try await f.service.preparePatch(outside) }
        try f.write(".gitattributes", "file filter=probe\n")
        let marker = f.root.appending(path: "filter-executed")
        _ = try await f.engine.run(
            ["config", "--local", "filter.probe.clean", "touch '" + marker.path + "'; cat"], in: f.root)
        let patch = Data("diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n".utf8)
        await #expect(throws: ModelFailure.self) { try await f.service.preparePatch(patch) }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("old\n".utf8))
    }

    @Test func changedPendingIndexProtectionPreventsAllRecoveryReferenceCleanup() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "old\n")
        let head = try await f.commit()
        try f.write("file", "new\n")
        let patch = try await f.service.exportPatch(layer: .unstaged)
        try f.write("file", "old\n")
        var record = try await f.service.executePatch(f.service.preparePatch(patch))
        let tree = try await f.engine.run(["rev-parse", head + "^{tree}"], in: f.root).text
            .removingLastNewline
        record.pendingIndexTree = tree
        record.pendingObjectBytes = 0
        try RecoveryStore(location: f.service.location).save(record)
        let pending = "refs/wegit/recovery-target/" + record.id.uuidString.lowercased()
        _ = try await f.engine.run(["update-ref", pending, tree], in: f.root)
        _ = try await f.engine.run(["update-ref", pending, head, tree], in: f.root)
        await #expect(throws: ModelFailure.self) { try await f.service.removeRecoveryRecord(record) }
        #expect(
            try await f.engine.run(
                ["rev-parse", "refs/wegit/recovery/" + record.id.uuidString.lowercased()], in: f.root
            ).text.removingLastNewline == head)
        #expect(try await f.service.recoveryRecords().contains { $0.id == record.id })
    }
}
