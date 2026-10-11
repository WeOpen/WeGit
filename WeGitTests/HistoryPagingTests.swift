import Foundation
import Testing

@testable import WeGitCore

struct HistoryPagingTests {
    @Test func graphEndsAtRootsAndDoesNotInventAnIncomingEdgeForNewTips() {
        let commits = [
            GitCommit(id: "left", parents: ["base"], author: "A", date: .distantPast, message: "Left"),
            GitCommit(id: "right", parents: ["base"], author: "A", date: .distantPast, message: "Right"),
            GitCommit(id: "base", parents: [], author: "A", date: .distantPast, message: "Root"),
        ]
        var graph = CommitGraphLayoutEngine()
        let first = graph.append([commits[0]])
        let rest = graph.append(Array(commits.dropFirst()))
        #expect(first[0].incomingColumns.isEmpty)
        #expect(!rest[0].incomingColumns.contains(rest[0].column))
        #expect(rest[1].incomingColumns.contains(rest[1].column))
        #expect(rest[1].connections.isEmpty)
    }

    @Test func messageAndAuthorSearchUseLiteralQueriesAndFixedTips() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try await history(f, count: 8)
        let author = try await f.service.historyAnchor(query: "AUTHOR@EXAMPLE.INVALID", searchField: .author)
        #expect(try await f.service.historyPage(author).commits.count == 8)
        let literal = try await f.service.historyAnchor(query: "^Author", searchField: .author)
        #expect(try await f.service.historyPage(literal).commits.isEmpty)
        let message = try await f.service.historyAnchor(query: "commit 4", searchField: .message)
        #expect(try await f.service.historyPage(message).commits.map(\.subject) == ["Commit 4"])
    }

    @Test func shaSearchIgnoresRefNameAmbiguityAndHonorsTheChosenRange() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try await history(f, count: 4)
        let old = try await f.engine.run(["rev-parse", "HEAD~1"], in: f.root).text.removingLastNewline
        let prefix = String(old.prefix(8))
        _ = try await f.engine.run(["tag", prefix, "HEAD"], in: f.root)
        let bySHA = try await f.service.historyAnchor(query: prefix.uppercased(), searchField: .sha)
        #expect(try await f.service.historyPage(bySHA).commits.map(\.id) == [old])
        _ = try await f.engine.run(["update-ref", "refs/heads/main", "HEAD~2"], in: f.root)
        let currentOnly = try await f.service.historyAnchor(
            scope: .currentBranch, query: old, searchField: .sha)
        #expect(try await f.service.historyPage(currentOnly).commits.isEmpty)
        #expect(try await f.service.historyPage(bySHA).commits.map(\.id) == [old])
        for invalid in ["HEAD", "--all", "abc", "main~1"] {
            await #expect(throws: ModelFailure.self) {
                _ = try await f.service.historyAnchor(query: invalid, searchField: .sha)
            }
        }
    }

    @Test func historicalBranchStartAndDetachedCheckoutUseExactCommits() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try await history(f, count: 4)
        _ = try await f.engine.run(["reset", "--hard", "HEAD"], in: f.root)
        let head = try #require(try await f.service.head())
        let old = try await f.engine.run(["rev-parse", "HEAD~2"], in: f.root).text.removingLastNewline
        try await f.service.createBranch("from-history", start: old, switchTo: false, expectedHead: head)
        #expect(try await f.service.head() == head)
        #expect(
            try await f.engine.run(["rev-parse", "refs/heads/from-history"], in: f.root).text
                .removingLastNewline == old)
        try await f.service.checkoutCommit(old, expectedHead: head)
        #expect(try await f.service.status().isDetached)
        #expect(try await f.service.head() == old)
    }
    private func history(_ f: Fixture, count: Int) async throws {
        var stream = "blob\nmark :1\ndata 5\nhello\n"
        for index in 1...count {
            let message = "Commit \(index)"
            stream +=
                "commit refs/heads/main\nmark :\(index + 1)\nauthor Author <author@example.invalid> 1700000000 +0000\ncommitter Committer <committer@example.invalid> 1700000001 +0000\ndata \(message.utf8.count)\n\(message)\n"
            if index > 1 { stream += "from :\(index)\n" }
            stream += "M 100644 :1 file.txt\n\n"
        }
        stream += "done\n"
        _ = try await f.engine.run(["fast-import", "--quiet"], in: f.root, input: Data(stream.utf8))
    }

    @Test func pagesKeepFixedTipsAfterReferencesMove() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try await history(f, count: 430)
        let anchor = try await f.service.historyAnchor()
        let first = try await f.service.historyPage(anchor)
        #expect(first.commits.count == 200 && first.next != nil)
        #expect(first.commits.first?.subject == "Commit 430")
        let expected = try await f.engine.run(
            ["rev-list", "--topo-order"] + anchor.tips + ["--"], in: f.root
        ).text.split(separator: "\n").map(String.init)
        _ = try await f.engine.run(
            [
                "-c", "user.name=New", "-c", "user.email=new@example.invalid", "-c", "commit.gpgsign=false",
                "commit", "--allow-empty", "-m", "After anchor",
            ], in: f.root)
        let second = try await f.service.historyPage(anchor, after: first.next)
        let third = try await f.service.historyPage(anchor, after: second.next)
        let combined = first.commits + second.commits + third.commits
        #expect(combined.map(\.id) == expected)
        #expect(third.commits.count == 30 && third.next == nil)
        let newer = try await f.service.historyAnchor()
        #expect(newer.tips != anchor.tips)
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.historyPage(newer, after: first.next)
        }
        #expect(first.commits[0].authorEmail == "author@example.invalid")
        #expect(
            first.commits[0].committer == "Committer"
                && first.commits[0].committerEmail == "committer@example.invalid")
        #expect(first.commits[0].committedAt.timeIntervalSince1970 == 1_700_000_001)
    }

    @Test func defaultRangeIncludesTagOnlyHistoryAndCurrentBranchCanBeSelected() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try await history(f, count: 4)
        let tagged = try #require(try await f.service.head())
        _ = try await f.engine.run(["tag", "-a", "release", "-m", "Annotated"], in: f.root)
        let older = try await f.engine.run(["rev-parse", "HEAD~2"], in: f.root).text.removingLastNewline
        _ = try await f.engine.run(["update-ref", "refs/heads/main", older], in: f.root)
        let all = try await f.service.historyAnchor()
        #expect(all.references.contains { $0.kind == .tag && $0.target == tagged && $0.name == "release" })
        #expect(try await f.service.historyPage(all).commits.count == 4)
        let current = try await f.service.historyAnchor(scope: .currentBranch)
        #expect(try await f.service.historyPage(current).commits.count == 2)
        let blob = try await f.engine.run(
            ["hash-object", "-w", "--stdin"], in: f.root, input: Data("blob".utf8)
        ).text.removingLastNewline
        _ = try await f.engine.run(["update-ref", "refs/tags/blob-tag", blob], in: f.root)
        #expect(try await f.service.historyAnchor().references.allSatisfy { $0.id != "refs/tags/blob-tag" })
    }

    @Test func shallowHistoryRetainsRealParentIDsAndMarksTheBoundary() async throws {
        let f = try await Fixture.create()
        let shallow = f.root.appendingPathExtension("shallow")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: shallow)
        }
        try await history(f, count: 8)
        _ = try await f.engine.run(["clone", "--depth=3", f.root.absoluteString, shallow.path])
        let service = RepositoryService(
            location: try await RepositoryService.discover(shallow, engine: f.engine), engine: f.engine)
        let anchor = try await service.historyAnchor()
        let page = try await service.historyPage(anchor)
        #expect(anchor.isShallow && page.commits.count == 3)
        let boundary = try #require(page.commits.last)
        #expect(boundary.shallowBoundary && !boundary.parents.isEmpty)
        var graph = CommitGraphLayoutEngine()
        let rows = graph.append(page.commits)
        #expect(rows.last?.connections.isEmpty == true && graph.lanes.isEmpty)
    }

    @Test func graphLanesContinueAcrossMergePages() {
        func commit(_ id: String, _ parents: [String]) -> GitCommit {
            GitCommit(id: id, parents: parents, author: "A", date: .distantPast, message: id)
        }
        let commits = [
            commit("merge", ["left", "right"]), commit("left", ["base"]), commit("right", ["base"]),
            commit("base", []),
        ]
        let whole = GraphLayout.rows(commits)
        var graph = CommitGraphLayoutEngine()
        let first = graph.append(Array(commits.prefix(2)))
        #expect(!graph.lanes.isEmpty)
        let second = graph.append(Array(commits.suffix(2)))
        let paged = first + second
        #expect(paged.map(\.column) == whole.map(\.column))
        #expect(paged.map(\.width) == whole.map(\.width))
        #expect(
            paged.map { $0.connections.map { "\($0.0):\($0.1)" } }
                == whole.map { $0.connections.map { "\($0.0):\($0.1)" } })
        #expect(graph.lanes.isEmpty)
    }

    @Test func parserPreservesControlCharactersAndRejectsIncompleteObjects() throws {
        let id = String(repeating: "a", count: 40)
        let object = Data(
            "tree \(String(repeating: "b", count: 40))\nauthor A <a@example.invalid> 1 +0000\ncommitter C <c@example.invalid> 2 +0000\n\nSubject\n\nBody\0with control\n"
                .utf8)
        let complete = Data("\(id) commit \(object.count)\n".utf8) + object + Data([10])
        #expect(
            try CommitParser.batch(complete, expected: [id])[0].message.contains("\0with control") == true)
        #expect(throws: ModelFailure.self) {
            _ = try CommitParser.batch(Data(complete.dropLast()), expected: [id])
        }
        #expect(throws: ModelFailure.self) {
            _ = try CommitParser.batch(complete + Data([0]), expected: [id])
        }
        #expect(throws: ModelFailure.self) {
            _ = try CommitParser.batch(Data("\(id) commit 999999999999999999999\n".utf8), expected: [id])
        }
    }
}
