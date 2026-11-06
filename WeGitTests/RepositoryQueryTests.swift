import Foundation
import Testing

@testable import WeGitCore

struct RepositoryQueryTests {
    @Test func exactTagNavigationSurvivesListTruncationAndRejectsMovedReference() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("tracked.txt", "base")
        let head = try await fixture.commit("Initial")
        let references = (0..<201).map { String(format: "update refs/tags/a-%03d-chosen ", $0) + head + "\n" }
            .joined()
        _ = try await fixture.engine.run(
            ["update-ref", "--stdin"], in: fixture.root, input: Data(references.utf8))
        _ = try await fixture.engine.run(["tag", "chosen"], in: fixture.root)
        let all = try await fixture.service.tags(query: "chosen", limit: 10_000)
        let target = try #require(all.entries.first { $0.name == "chosen" })
        let page = try await fixture.service.tags(query: "chosen", limit: 200)
        #expect(!page.entries.contains(target))
        let indexBytes = try Data(contentsOf: fixture.root.appending(path: ".git/index"))
        #expect(try await fixture.service.readTag(target) == target)
        #expect(try Data(contentsOf: fixture.root.appending(path: ".git/index")) == indexBytes)
        #expect(target.objectID == head)
        _ = try await fixture.engine.run(
            ["-c", "tag.gpgsign=false", "tag", "-a", "inner", "-m", "Inner", head], in: fixture.root)
        _ = try await fixture.engine.run(
            ["-c", "tag.gpgsign=false", "tag", "-a", "outer", "-m", "Outer", "inner"], in: fixture.root)
        let anchor = try await fixture.service.repositoryQueryAnchor(scope: .tags, query: "outer")
        let result = try #require(try await fixture.service.repositoryQueryPage(anchor).results.first)
        guard case .tag(let nested) = result else { throw ModelFailure.changed }
        let canonical = try await fixture.service.readTag(nested)
        #expect(canonical.reference == nested.reference && canonical.objectID == nested.objectID)
        #expect(canonical.targetCommit == head)
        try fixture.write("tracked.txt", "later")
        let later = try await fixture.commit("Later")
        _ = try await fixture.engine.run(["update-ref", "refs/tags/chosen", later, head], in: fixture.root)
        await #expect(throws: ModelFailure.self) { _ = try await fixture.service.readTag(target) }
    }

    @Test func unifiedQueryIncludesEveryScopeAndKeepsDisabledCommandReason() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("tracked.txt", "base")
        _ = try await fixture.commit("Initial query")
        _ = try await fixture.engine.run(["tag", "query-tag"], in: fixture.root)
        try fixture.write("tracked.txt", "changed")
        _ = try await fixture.engine.run(["stash", "push", "-m", "query-stash"], in: fixture.root)
        let anchor = try await fixture.service.repositoryQueryAnchor(commands: [
            .init(id: "stage", title: "Stage", symbol: "plus.circle", enabled: false, reason: "No files")
        ])
        let page = try await fixture.service.repositoryQueryPage(anchor)
        #expect(Set(page.results.map(\.scope)) == Set(RepositoryQueryScope.allCases.filter { $0 != .all }))
        #expect(page.results.count <= 100)
        let command = try #require(page.results.first { $0.scope == .commands })
        #expect(!command.enabled)
        #expect(command.detail == "No files")
        #expect(page.next == nil)
    }

    @Test func trackedPathPagesAreStableAndNeverReadUntrackedFilesOrFileText() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        for index in 0..<205 { try fixture.write(String(format: "path-%03d.txt", index), "secret needle") }
        try fixture.write("中文\nfile.txt", "kept")
        _ = try await fixture.commit("Initial")
        try fixture.write("untracked-needle.txt", "unknown")
        let anchor = try await fixture.service.repositoryQueryAnchor(scope: .trackedPaths)
        let first = try await fixture.service.repositoryQueryPage(anchor)
        #expect(first.results.count == 100)
        let cursor = try #require(first.next)
        try fixture.write("later.txt", "later")
        _ = try await fixture.engine.run(["add", "later.txt"], in: fixture.root)
        let second = try await fixture.service.repositoryQueryPage(anchor, after: cursor)
        let secondCursor = try #require(second.next)
        let third = try await fixture.service.repositoryQueryPage(anchor, after: secondCursor)
        let results = first.results + second.results + third.results
        #expect(results.count == 206)
        #expect(Set(results.map(\.id)).count == 206)
        #expect(results.contains { $0.title == "中文\nfile.txt" })
        #expect(!results.contains { $0.title == "later.txt" })
        #expect(third.next == nil)
        let needle = try await fixture.service.repositoryQueryAnchor(scope: .trackedPaths, query: "needle")
        #expect(try await fixture.service.repositoryQueryPage(needle).results.isEmpty)
        await #expect(throws: ModelFailure.self) {
            _ = try await fixture.service.repositoryQueryPage(needle, after: cursor)
        }
    }

    @Test func fixedCommitTipsDoNotIncludeLaterCommitsAcrossPages() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        for index in 0..<5 {
            try fixture.write("tracked.txt", "\(index)")
            _ = try await fixture.commit("query-\(index)")
        }
        let anchor = try await fixture.service.repositoryQueryAnchor(scope: .commits, query: "query")
        let first = try await fixture.service.repositoryQueryPage(anchor, count: 2)
        try fixture.write("tracked.txt", "later")
        _ = try await fixture.commit("query-later")
        let firstCursor = try #require(first.next)
        let second = try await fixture.service.repositoryQueryPage(anchor, after: firstCursor, count: 2)
        let secondCursor = try #require(second.next)
        let third = try await fixture.service.repositoryQueryPage(anchor, after: secondCursor, count: 2)
        let results = first.results + second.results + third.results
        #expect(results.count == 5)
        #expect(Set(results.map(\.id)).count == 5)
        #expect(!results.contains { $0.title == "query-later" })
        #expect(third.next == nil)
    }

    @Test func cancelledQueryNeverProducesResultsAndInvalidLimitsAreRejected() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service.repositoryQueryAnchor(scope: .trackedPaths)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let anchor = try await fixture.service.repositoryQueryAnchor(scope: .commands)
        await #expect(throws: ModelFailure.self) {
            _ = try await fixture.service.repositoryQueryPage(anchor, count: 101)
        }
        await #expect(throws: ModelFailure.self) {
            _ = try await fixture.service.repositoryQueryAnchor(
                scope: .commands, query: String(repeating: "x", count: 1025))
        }
    }
}
