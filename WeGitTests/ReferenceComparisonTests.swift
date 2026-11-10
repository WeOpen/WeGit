import Foundation
import Testing

@testable import WeGitCore

struct ReferenceComparisonTests {
    @Test func twoPointAndMergeBaseComparisonsPinTheirObjectsAndHaveDifferentFileRanges() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("base", "base\n")
        let common = try await f.commit("Common")
        _ = try await f.engine.run(["branch", "target", common], in: f.root)
        try f.write("left", "left\n")
        let left = try await f.commit("Left")
        _ = try await f.engine.run(["switch", "target"], in: f.root)
        try f.write("right", "right\n")
        let right = try await f.commit("Right")
        let points = try await f.service.prepareReferenceComparison(base: "main", target: "target")
        let range = try await f.service.prepareReferenceComparison(
            base: "main", target: "target", kind: .mergeBase)
        _ = try await f.engine.run(["update-ref", "refs/heads/main", common, left], in: f.root)
        let diff = try await f.service.referenceComparison(points)
        #expect(points.base.id == left && points.target.id == right)
        #expect(Set(diff.comparison.files.map(\.path)) == ["left", "right"])
        let changes = try await f.service.referenceComparison(range)
        #expect(changes.effectiveBase == common && changes.comparison.files.map(\.path) == ["right"])
        let commits = try await f.service.comparisonCommits(range, count: 1)
        #expect(commits.commits.map(\.id) == [right] && commits.nextOffset == nil)
        let file = try #require(changes.comparison.files.first)
        if case .loaded(let content) = try await f.service.readCommitFile(
            file, comparison: changes.comparison)
        {
            #expect(content.path == "right" && !content.hunks.isEmpty)
        } else {
            Issue.record("Expected a bounded text comparison")
        }
    }

    @Test func crissCrossHistoryRequiresAnExplicitCommonAncestor() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let root = try await f.commit("Root")
        let tree = try await f.engine.run(["rev-parse", root + "^{tree}"], in: f.root).text
            .removingLastNewline
        func commit(_ parents: [String], _ message: String) async throws -> String {
            try await f.engine.run(
                ["commit-tree", tree] + parents.flatMap { ["-p", $0] }, in: f.root,
                input: Data((message + "\n").utf8)
            ).text.removingLastNewline
        }
        let first = try await commit([root], "First")
        let second = try await commit([root], "Second")
        let left = try await commit([first, second], "Left merge")
        let right = try await commit([second, first], "Right merge")
        let plan = try await f.service.prepareReferenceComparison(base: left, target: right, kind: .mergeBase)
        #expect(Set(plan.mergeBases) == [first, second])
        await #expect(throws: ModelFailure.self) { _ = try await f.service.referenceComparison(plan) }
        let selected = try await f.service.referenceComparison(plan, mergeBase: first)
        #expect(selected.effectiveBase == first)
    }
}
