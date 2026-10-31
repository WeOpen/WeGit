import Foundation
import Testing

@testable import WeGitCore

struct InteractiveRebaseTests {
    @Test func prepareRejectsMergeHistoryAndCapturesLinearSteps() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file", "base\n")
        _ = try await fixture.commit("Base")
        _ = try await fixture.engine.run(["switch", "-c", "topic"], in: fixture.root)
        try fixture.write("file", "first\n")
        let first = try await fixture.commit("First")
        try fixture.write("file", "second\n")
        let second = try await fixture.commit("Second")
        _ = try await fixture.engine.run(["switch", "main"], in: fixture.root)
        let upstream = try #require(try await fixture.service.branches().first { $0.name == "main" })
        _ = try await fixture.engine.run(["switch", "topic"], in: fixture.root)
        let plan = try await fixture.service.prepareInteractiveRebase(upstream: upstream)
        #expect(plan.steps.map(\.id) == [first, second])
        #expect(plan.steps.allSatisfy { $0.action == .pick })
        #expect(plan.branch == "topic")
    }

    @Test func dropAndRewordExecuteFromAConfirmedLinearPlan() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file", "base\n")
        _ = try await fixture.commit("Base")
        _ = try await fixture.engine.run(["switch", "-c", "topic"], in: fixture.root)
        try fixture.write("file", "first\n")
        let first = try await fixture.commit("First")
        try fixture.write("file", "second\n")
        let second = try await fixture.commit("Second")
        _ = try await fixture.engine.run(["switch", "main"], in: fixture.root)
        let upstream = try #require(try await fixture.service.branches().first { $0.name == "main" })
        _ = try await fixture.engine.run(["switch", "topic"], in: fixture.root)
        let original = try #require(try await fixture.service.head())
        let prepared = try await fixture.service.prepareInteractiveRebase(upstream: upstream)
        let steps = prepared.steps.map { step in
            InteractiveRebaseStep(
                id: step.id, subject: step.subject, author: step.author,
                action: step.id == first ? .reword : .drop,
                message: step.id == first ? "Renamed first\n" : nil)
        }
        let plan = InteractiveRebasePlan(
            branch: prepared.branch, head: prepared.head, upstream: prepared.upstream, steps: steps,
            location: prepared.location, index: prepared.index, writePaths: prepared.writePaths)
        guard case .completed(let head) = try await fixture.service.executeInteractiveRebase(plan) else {
            throw ModelFailure.changed
        }
        #expect(head != original)
        #expect(
            try await fixture.engine.run(["rev-list", "--count", upstream.oid + "..HEAD"], in: fixture.root)
                .text.removingLastNewline == "1")
        #expect(
            try await fixture.engine.run(["log", "-1", "--format=%s"], in: fixture.root).text
                .removingLastNewline == "Renamed first")
        #expect(try await fixture.engine.run(["show", "HEAD:file"], in: fixture.root).text == "first\n")
        _ = second
    }

    @Test func staleHeadAndIndexRejectAnEditedSequenceBeforeExecution() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file", "base\n")
        _ = try await fixture.commit("Base")
        _ = try await fixture.engine.run(["switch", "-c", "topic"], in: fixture.root)
        try fixture.write("file", "topic\n")
        _ = try await fixture.commit("Topic")
        _ = try await fixture.engine.run(["switch", "main"], in: fixture.root)
        let upstream = try #require(try await fixture.service.branches().first { $0.name == "main" })
        _ = try await fixture.engine.run(["switch", "topic"], in: fixture.root)
        let prepared = try await fixture.service.prepareInteractiveRebase(upstream: upstream)
        try fixture.write("other", "new staged path\n")
        try await fixture.service.stage(paths: ["other"], expectedHead: prepared.head)
        await #expect(throws: ModelFailure.self) {
            _ = try await fixture.service.executeInteractiveRebase(prepared)
        }
        #expect(
            try await fixture.engine.run(["symbolic-ref", "HEAD"], in: fixture.root).text
                .trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/topic")
        #expect(
            try await fixture.engine.run(["status", "--porcelain"], in: fixture.root).text.contains("other"))
    }

    @Test func mergeHistoryIsRejected() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file", "base\n")
        _ = try await fixture.commit("Base")
        let base = try #require(try await fixture.service.head())
        _ = try await fixture.engine.run(["branch", "upstream", base], in: fixture.root)
        _ = try await fixture.engine.run(["switch", "-c", "side"], in: fixture.root)
        try fixture.write("side", "side\n")
        _ = try await fixture.commit("Side")
        _ = try await fixture.engine.run(["switch", "main"], in: fixture.root)
        try fixture.write("main", "main\n")
        _ = try await fixture.commit("Main")
        _ = try await fixture.engine.run(["merge", "side"], in: fixture.root)
        let upstream = try #require(try await fixture.service.branches().first { $0.name == "upstream" })
        await #expect(throws: ModelFailure.self) {
            _ = try await fixture.service.prepareInteractiveRebase(upstream: upstream)
        }
    }
}
