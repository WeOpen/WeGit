import Foundation
import Testing

@testable import WeGitCore

struct InteractiveRebaseTests {
    @Test(arguments: [InteractiveRebaseAction.squash, .fixup])
    func foldedCommitsPreserveBothTreesAndTheChosenMessage(_ action: InteractiveRebaseAction) async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("base", "base\n")
        _ = try await fixture.commit("Base")
        _ = try await fixture.engine.run(["switch", "-c", "topic"], in: fixture.root)
        try fixture.write("one", "one\n")
        _ = try await fixture.commit("First")
        try fixture.write("two", "two\n")
        _ = try await fixture.commit("Second")
        let upstream = try #require(try await fixture.service.branches().first { $0.name == "main" })
        let plan = try await fixture.service.prepareInteractiveRebase(upstream: upstream)
        let steps = plan.steps.enumerated().map { index, step in
            InteractiveRebaseStep(
                id: step.id, subject: step.subject, author: step.author,
                action: index == 0 ? .pick : action,
                message: index == 1 && action == .squash ? "Combined message" : nil)
        }
        guard
            case .completed = try await fixture.service.executeInteractiveRebase(plan.replacing(steps: steps))
        else { throw ModelFailure.changed }
        #expect(
            try await fixture.engine.run(["rev-list", "--count", upstream.oid + "..HEAD"], in: fixture.root)
                .text.removingLastNewline == "1")
        #expect(
            try await fixture.engine.run(["log", "-1", "--format=%s"], in: fixture.root).text
                .removingLastNewline == (action == .squash ? "Combined message" : "First"))
        #expect(try await fixture.engine.run(["show", "HEAD:one"], in: fixture.root).text == "one\n")
        #expect(try await fixture.engine.run(["show", "HEAD:two"], in: fixture.root).text == "two\n")
        #expect(try await fixture.service.status().files.isEmpty)
    }

    @Test func editAmendAndPrivateMessageEditorSurviveReopenedService() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("base", "base\n")
        _ = try await fixture.commit("Base")
        _ = try await fixture.engine.run(["switch", "-c", "topic"], in: fixture.root)
        try fixture.write("one", "one\n")
        _ = try await fixture.commit("First")
        try fixture.write("two", "two\n")
        _ = try await fixture.commit("Second")
        let upstream = try #require(try await fixture.service.branches().first { $0.name == "main" })
        let plan = try await fixture.service.prepareInteractiveRebase(upstream: upstream)
        let steps = plan.steps.enumerated().map { index, step in
            InteractiveRebaseStep(
                id: step.id, subject: step.subject, author: step.author,
                action: index == 0 ? .edit : .reword, message: index == 0 ? nil : "Reword after reopen")
        }
        guard
            case .paused(let paused) = try await fixture.service.executeInteractiveRebase(
                plan.replacing(steps: steps))
        else { throw ModelFailure.changed }
        #expect(paused.interactiveEditPause && paused.canContinue)
        try fixture.write("amended", "saved during edit\n")
        try await fixture.service.stage(paths: ["amended"], expectedHead: paused.head)
        _ = try await fixture.service.commit(message: "Amended first", amend: true, expectedHead: paused.head)
        let reopened = RepositoryService(
            location: try await RepositoryService.discover(fixture.root, engine: fixture.engine),
            engine: fixture.engine)
        let fresh = try #require(try await reopened.rebaseRecovery())
        #expect(fresh.head != paused.head)
        await #expect(throws: ModelFailure.self) {
            _ = try await reopened.recoverRebase(continueOperation: true, expected: paused)
        }
        guard case .completed = try await reopened.recoverRebase(continueOperation: true, expected: fresh)
        else { throw ModelFailure.changed }
        #expect(
            try await fixture.engine.run(
                ["log", "--reverse", "--format=%s", upstream.oid + "..HEAD"], in: fixture.root
            ).text.trimmingCharacters(in: .newlines) == "Amended first\nReword after reopen")
        #expect(
            try await fixture.engine.run(["show", "HEAD:amended"], in: fixture.root).text
                == "saved during edit\n")
        #expect(try await reopened.status().sequencer == .none)
    }

    @Test func externalTodoChangeRefusesContinueButStillAllowsConfirmedAbort() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("base", "base\n")
        _ = try await fixture.commit("Base")
        _ = try await fixture.engine.run(["switch", "-c", "topic"], in: fixture.root)
        try fixture.write("one", "one\n")
        _ = try await fixture.commit("First")
        try fixture.write("two", "two\n")
        _ = try await fixture.commit("Second")
        let upstream = try #require(try await fixture.service.branches().first { $0.name == "main" })
        let plan = try await fixture.service.prepareInteractiveRebase(upstream: upstream)
        let steps = plan.steps.enumerated().map { index, step in
            InteractiveRebaseStep(
                id: step.id, subject: step.subject, author: step.author, action: index == 0 ? .edit : .pick)
        }
        guard case .paused = try await fixture.service.executeInteractiveRebase(plan.replacing(steps: steps))
        else { throw ModelFailure.changed }
        let todo = fixture.service.location.gitDirectory.appending(path: "rebase-merge/git-rebase-todo")
        try Data(("drop " + plan.steps[1].id + "\n").utf8).write(to: todo)
        let changed = try #require(try await fixture.service.rebaseRecovery())
        #expect(!changed.canContinue && changed.canAbort)
        await #expect(throws: ModelFailure.self) {
            _ = try await fixture.service.recoverRebase(continueOperation: true, expected: changed)
        }
        guard
            case .aborted(let head) = try await fixture.service.recoverRebase(
                continueOperation: false, expected: changed)
        else { throw ModelFailure.changed }
        #expect(head == plan.head)
        #expect(try await fixture.service.status().files.isEmpty)
    }

    @Test func publishedHistoryChangeInvalidatesTheOldConfirmation() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("base", "base\n")
        _ = try await fixture.commit("Base")
        _ = try await fixture.engine.run(["switch", "-c", "topic"], in: fixture.root)
        try fixture.write("one", "one\n")
        let first = try await fixture.commit("First")
        try fixture.write("two", "two\n")
        let second = try await fixture.commit("Second")
        _ = try await fixture.engine.run(
            ["update-ref", "refs/remotes/origin/topic", first], in: fixture.root)
        let upstream = try #require(try await fixture.service.branches().first { $0.name == "main" })
        let plan = try await fixture.service.prepareInteractiveRebase(upstream: upstream)
        #expect(plan.publishedCommits == [first])
        _ = try await fixture.engine.run(
            ["update-ref", "refs/remotes/origin/topic", second], in: fixture.root)
        await #expect(throws: ModelFailure.self) {
            _ = try await fixture.service.executeInteractiveRebase(plan)
        }
        #expect(try await fixture.service.head() == plan.head)
        #expect(try await fixture.service.status().sequencer == .none)
    }

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
            publishedCommits: prepared.publishedCommits,
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

    @Test func rejectsDropAllThenReordersIndependentCommits() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("base.txt", "base\n")
        _ = try await fixture.commit("Base")
        _ = try await fixture.engine.run(["switch", "-c", "topic"], in: fixture.root)
        try fixture.write("first.txt", "first\n")
        _ = try await fixture.commit("First")
        try fixture.write("second.txt", "second\n")
        _ = try await fixture.commit("Second")
        _ = try await fixture.engine.run(["switch", "main"], in: fixture.root)
        let upstream = try #require(try await fixture.service.branches().first { $0.name == "main" })
        _ = try await fixture.engine.run(["switch", "topic"], in: fixture.root)
        let originalHead = try #require(try await fixture.service.head())
        let plan = try await fixture.service.prepareInteractiveRebase(upstream: upstream)
        let allDropped = plan.replacing(
            steps: plan.steps.map {
                InteractiveRebaseStep(id: $0.id, subject: $0.subject, author: $0.author, action: .drop)
            })
        await #expect(throws: ModelFailure.self) {
            _ = try await fixture.service.executeInteractiveRebase(allDropped)
        }
        #expect(try await fixture.service.head() == originalHead)
        #expect(try await fixture.service.status().sequencer == .none)
        #expect(try await fixture.engine.run(["status", "--porcelain"], in: fixture.root).text.isEmpty)

        guard
            case .completed = try await fixture.service.executeInteractiveRebase(
                plan.replacing(steps: Array(plan.steps.reversed())))
        else { throw ModelFailure.changed }
        #expect(
            try await fixture.engine.run(
                ["log", "--reverse", "--format=%s", upstream.oid + "..HEAD"], in: fixture.root
            )
            .text.trimmingCharacters(in: .whitespacesAndNewlines) == "Second\nFirst")
        #expect(try await fixture.engine.run(["show", "HEAD:first.txt"], in: fixture.root).text == "first\n")
        #expect(
            try await fixture.engine.run(["show", "HEAD:second.txt"], in: fixture.root).text == "second\n")
        #expect(try await fixture.engine.run(["status", "--porcelain"], in: fixture.root).text.isEmpty)
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
