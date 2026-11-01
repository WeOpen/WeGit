import Foundation
import Testing

@testable import WeGitCore

private struct FailStashDrop: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("stash") && request.arguments.contains("drop") {
            throw ProcessFailure.timedOut
        }
        return try await ProcessRunner().run(request)
    }
}

struct StashTests {
    @Test func reflogOnlyExternalDeletionRefreshesStashBrowser() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let location = fixture.service.location
        let scope = RepositoryRefreshScope.events(
            paths: [location.gitDirectory.appending(path: "logs/refs/stash").path], flags: [0],
            location: location)
        #expect(scope.contains(.status))
    }

    @Test func saveAndRestorePreserveIndexWorktreeAndSpecialUntrackedPaths() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file", "base\n")
        let head = try await fixture.commit()
        try fixture.write("file", "index\n")
        try await fixture.service.stage(paths: ["file"], expectedHead: head)
        try fixture.write("file", "working\n")
        let special = "新文件\n[1].txt"
        try fixture.write(special, "untracked\n")
        let expected = try await fixture.service.status().files
        let entry = try await fixture.service.createStash(
            message: "Named record", includeUntracked: true, expectedHead: head, expectedFiles: expected)
        #expect(try await fixture.service.status().files.isEmpty)
        let list = try await fixture.service.stashes()
        let contents = try await fixture.service.stashContents(entry, in: list)
        #expect(contents.index.parents == [head])
        #expect(contents.untracked != nil)
        #expect(entry.branch == "main")
        #expect(entry.message.contains("Named record"))
        _ = try await fixture.service.restoreStash(
            entry, in: list, restoreIndex: true, pop: false, expectedHead: head)
        let restored = try await fixture.service.status()
        #expect(restored.files.contains { $0.path == "file" && $0.staged && $0.unstaged })
        #expect(try Data(contentsOf: fixture.root.appending(path: special)) == Data("untracked\n".utf8))
        #expect(try Data(contentsOf: fixture.root.appending(path: "file")) == Data("working\n".utf8))
        #expect(try await fixture.service.stashes().entries == list.entries)
        #expect(try await fixture.service.head() == head)
    }

    @Test func staleListAndStaleSaveScopeRejectWithoutMutation() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file", "base\n")
        let head = try await fixture.commit()
        try fixture.write("file", "first\n")
        let first = try await fixture.service.createStash(
            message: "First", includeUntracked: false, expectedHead: head)
        let firstList = try await fixture.service.stashes()
        try fixture.write("file", "second\n")
        _ = try await fixture.service.createStash(
            message: "Second", includeUntracked: false, expectedHead: head)
        do {
            try await fixture.service.deleteStash(first, in: firstList, expectedHead: head)
            Issue.record("Changed reflog must reject an old selector")
        } catch ModelFailure.changed {}
        #expect(try await fixture.service.stashes().entries.count == 2)
        try fixture.write("file", "pending\n")
        let snapshot = try await fixture.service.status().files
        try fixture.write("extra", "new scope\n")
        do {
            _ = try await fixture.service.createStash(
                message: "Stale", includeUntracked: true, expectedHead: head, expectedFiles: snapshot)
            Issue.record("A changed save preview must be rejected")
        } catch ModelFailure.changed {}
        #expect(try Data(contentsOf: fixture.root.appending(path: "file")) == Data("pending\n".utf8))
        #expect(try await fixture.service.stashes().entries.count == 2)
        let page = try await fixture.service.stashes(limit: 1)
        #expect(page.entries.count == 1 && page.hasMore)
    }

    @Test func ignoredRenameSourceAndRestoreObstructionsArePreserved() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("a", "base\n")
        try fixture.write(".gitignore", "a/\nnew-file/\n")
        let head = try await fixture.commit()
        _ = try await fixture.engine.run(["mv", "a", "b"], in: fixture.root)
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "a"), withIntermediateDirectories: true)
        try fixture.write("a/child", "private bytes\n")
        do {
            _ = try await fixture.service.createStash(
                message: "Must reject", includeUntracked: true, expectedHead: head)
            Issue.record("Ignored rename source must not be erased by stash reset")
        } catch ModelFailure.unsupported {}
        #expect(try Data(contentsOf: fixture.root.appending(path: "a/child")) == Data("private bytes\n".utf8))
        try FileManager.default.removeItem(at: fixture.root.appending(path: "a"))
        _ = try await fixture.engine.run(["reset", "--hard", "HEAD"], in: fixture.root)
        try fixture.write("new-file", "saved\n")
        try await fixture.service.stage(paths: ["new-file"], expectedHead: head)
        let entry = try await fixture.service.createStash(
            message: "Restore", includeUntracked: false, expectedHead: head)
        let list = try await fixture.service.stashes()
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "new-file"), withIntermediateDirectories: true)
        try fixture.write("new-file/child", "ignored private bytes\n")
        #expect(try await fixture.service.status().files.isEmpty)
        do {
            _ = try await fixture.service.restoreStash(
                entry, in: list, restoreIndex: true, pop: true, expectedHead: head)
            Issue.record("Pop must not erase ignored contents")
        } catch ModelFailure.unsupported {}
        #expect(
            try Data(contentsOf: fixture.root.appending(path: "new-file/child"))
                == Data("ignored private bytes\n".utf8))
        #expect(try await fixture.service.stashes().entries == list.entries)
    }

    @Test func failedDropAfterApplyNeverAsksTheCallerToApplyAgain() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file", "base\n")
        let head = try await fixture.commit()
        try fixture.write("file", "saved\n")
        let entry = try await fixture.service.createStash(
            message: "Pending drop", includeUntracked: false, expectedHead: head)
        let list = try await fixture.service.stashes()
        let engine = TestGit.engine(runner: FailStashDrop(), environment: fixture.engine.environment)
        let service = RepositoryService(location: fixture.service.location, engine: engine)
        let result = try await service.restoreStash(
            entry, in: list, restoreIndex: false, pop: true, expectedHead: head)
        guard case .appliedNeedsReview = result else {
            Issue.record("An uncertain deletion must be a distinct post-apply outcome")
            return
        }
        #expect(try Data(contentsOf: fixture.root.appending(path: "file")) == Data("saved\n".utf8))
        #expect(try await service.stashes().entries == list.entries)
    }

    @Test func stashParserRejectsTruncationAndNonCanonicalSelectors() throws {
        #expect(try StashParser.parse(Data()).isEmpty)
        let object = String(repeating: "a", count: 64)
        let record = "stash@{0}\0\(object)\01700000000\0On main: 名称\0"
        let parsed = try StashParser.parse(Data(record.utf8))
        #expect(parsed.first?.objectID == object)
        #expect(parsed.first?.branch == "main")
        #expect(throws: (any Error).self) { try StashParser.parse(Data(record.dropLast().utf8)) }
        let invalid = record.replacingOccurrences(of: "stash@{0}", with: "stash@{-1}")
        #expect(throws: (any Error).self) { try StashParser.parse(Data(invalid.utf8)) }
    }
}
