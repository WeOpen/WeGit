import Foundation

@testable import WeGitCore

@MainActor @main struct InteractiveRebaseExtendedChecks {
    enum Failure: Error { case assertion(String) }
    private static var passed = 0

    static func main() async throws {
        try await runSquash(message: "Squashed result")
        try await runSquash(message: nil)
        try await runFixup()
        try await runEditPause()
        try await runCombination(
            actions: [.pick, .squash, .fixup], messages: [nil, "Combined group", nil],
            expected: "Combined group")
        try await runCombination(
            actions: [.pick, .squash, .squash], messages: [nil, nil, "Final combined message"],
            expected: "Final combined message")
        try await runCombination(
            actions: [.reword, .squash, .pick], messages: ["Reword first", "Group message", nil],
            expected: "Group message\nThird")
        try await runLastEditAndReopen()
        try await runMutatedTodoRefusal()
        try await runPrivateMessageRefusal()
        try await runRepeatedConflicts()
        try await runQueuedCancellation()
        try await runHookFailure()
        try await runInterruptedReply(.cancel)
        try await runInterruptedReply(.timeout)
        try await runInterruptedReply(.unknown)
        print(
            "PASS interactive rebase actions, combinations, repeated conflicts, reopen, stale recovery, cancellation and hooks (\(passed) checks)"
        )
    }

    private static func runSquash(message: String?) async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let (service, upstream, first, second) = try await fixture.makeRange()
        let prepared = try await service.prepareInteractiveRebase(upstream: upstream)
        let steps = prepared.steps.map {
            InteractiveRebaseStep(
                id: $0.id, subject: $0.subject, author: $0.author,
                action: $0.id == first ? .pick : .squash,
                message: $0.id == second ? message : nil)
        }
        let outcome: InteractiveRebaseOutcome
        outcome = try await service.executeInteractiveRebase(prepared.replacing(steps: steps))
        guard case .completed = outcome
        else { throw Failure.assertion("squash did not complete") }
        try require(
            try await fixture.git(["rev-list", "--count", upstream.oid + "..HEAD"]).text.trimmed == "1",
            "squash count")
        try require(
            try await fixture.git(["log", "-1", "--format=%B"]).text.trimmed
                == (message ?? "First\n\nSecond"), "squash message")
        try require(try await fixture.git(["show", "HEAD:one.txt"]).text == "one\n", "squash first tree")
        try require(try await fixture.git(["show", "HEAD:two.txt"]).text == "two\n", "squash second tree")
    }

    private static func runFixup() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let (service, upstream, first, _) = try await fixture.makeRange()
        let prepared = try await service.prepareInteractiveRebase(upstream: upstream)
        let steps = prepared.steps.map {
            InteractiveRebaseStep(
                id: $0.id, subject: $0.subject, author: $0.author,
                action: $0.id == first ? .pick : .fixup)
        }
        let outcome: InteractiveRebaseOutcome
        outcome = try await service.executeInteractiveRebase(prepared.replacing(steps: steps))
        guard case .completed = outcome
        else { throw Failure.assertion("fixup did not complete") }
        try require(
            try await fixture.git(["rev-list", "--count", upstream.oid + "..HEAD"]).text.trimmed == "1",
            "fixup count")
        try require(
            try await fixture.git(["log", "-1", "--format=%s"]).text.trimmed == "First", "fixup message")
        try require(try await fixture.git(["status", "--porcelain"]).text.isEmpty, "fixup clean")
    }

    private static func runEditPause() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let (service, upstream, first, _) = try await fixture.makeRange()
        let prepared = try await service.prepareInteractiveRebase(upstream: upstream)
        let steps = prepared.steps.map {
            InteractiveRebaseStep(
                id: $0.id, subject: $0.subject, author: $0.author,
                action: $0.id == first ? .edit : .pick)
        }
        let outcome: InteractiveRebaseOutcome
        outcome = try await service.executeInteractiveRebase(prepared.replacing(steps: steps))
        guard case .paused(let recovery) = outcome
        else { throw Failure.assertion("edit did not pause") }
        try require(recovery.interactiveSequence && recovery.interactiveEditPause, "edit recovery metadata")
        try fixture.write("amended.txt", "edited at pause\n")
        try await fixture.git(["add", "amended.txt"])
        _ = try await service.commit(
            message: "First amended in WeGit", amend: true, expectedHead: recovery.head)
        let reopened = try await fixture.reopen()
        let fresh = try await reopened.rebaseRecovery()
        try require(fresh != nil && fresh?.head != recovery.head, "reopen observes amended edit HEAD")
        var staleRejected = false
        do {
            _ = try await reopened.recoverRebase(continueOperation: true, expected: recovery)
        } catch is ModelFailure { staleRejected = true }
        try require(staleRejected, "stale pre-amend recovery cannot write")
        guard case .completed = try await reopened.recoverRebase(continueOperation: true, expected: fresh!)
        else { throw Failure.assertion("edit continuation did not complete") }
        try require(
            try await fixture.git(["rev-list", "--count", upstream.oid + "..HEAD"]).text.trimmed == "2",
            "edit count")
        try require(try await fixture.git(["status", "--porcelain"]).text.isEmpty, "edit clean")
        try require(
            try await fixture.git(["show", "HEAD:amended.txt"]).text == "edited at pause\n",
            "edit amendment preserved")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.assertion(message) }
        passed += 1
    }

    private static func runCombination(
        actions: [InteractiveRebaseAction], messages: [String?], expected: String
    ) async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let (service, upstream, _, _) = try await fixture.makeRange(third: true)
        let prepared = try await service.prepareInteractiveRebase(upstream: upstream)
        let steps = prepared.steps.enumerated().map { index, step in
            InteractiveRebaseStep(
                id: step.id, subject: step.subject, author: step.author, action: actions[index],
                message: messages[index])
        }
        guard case .completed = try await service.executeInteractiveRebase(prepared.replacing(steps: steps))
        else { throw Failure.assertion("combination did not complete") }
        try require(
            try await fixture.git(["log", "--reverse", "--format=%s", upstream.oid + "..HEAD"]).text.trimmed
                == expected, "combination message order")
        for (path, bytes) in [("one.txt", "one\n"), ("two.txt", "two\n"), ("three.txt", "three\n")] {
            try require(
                try await fixture.git(["show", "HEAD:" + path]).text == bytes, "combination tree " + path)
        }
        try require(try await fixture.git(["status", "--porcelain"]).text.isEmpty, "combination clean")
    }

    private static func runLastEditAndReopen() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let (service, _, _, last) = try await fixture.makeRange()
        let prepared = try await service.prepareInteractiveRebase(upstream: try await fixture.upstream())
        let steps = prepared.steps.map {
            InteractiveRebaseStep(
                id: $0.id, subject: $0.subject, author: $0.author, action: $0.id == last ? .edit : .pick)
        }
        guard case .paused = try await service.executeInteractiveRebase(prepared.replacing(steps: steps))
        else { throw Failure.assertion("last edit did not pause") }
        let reopened = try await fixture.reopen()
        guard let recovery = try await reopened.rebaseRecovery() else {
            throw Failure.assertion("last edit missing after reopen")
        }
        try require(
            recovery.interactiveEditPause && recovery.remainingSteps == 0 && recovery.canContinue,
            "last edit stays resumable with empty todo")
        guard case .completed = try await reopened.recoverRebase(continueOperation: true, expected: recovery)
        else { throw Failure.assertion("last edit continue") }
        try require(try await fixture.git(["status", "--porcelain"]).text.isEmpty, "last edit clean")
    }

    private static func runMutatedTodoRefusal() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let (service, upstream, first, second) = try await fixture.makeRange()
        let plan = try await service.prepareInteractiveRebase(upstream: upstream)
        let steps = plan.steps.map {
            InteractiveRebaseStep(
                id: $0.id, subject: $0.subject, author: $0.author, action: $0.id == first ? .edit : .pick)
        }
        guard
            case .paused(let before) = try await service.executeInteractiveRebase(
                plan.replacing(steps: steps))
        else { throw Failure.assertion("todo mutation setup") }
        let todo = service.location.gitDirectory.appending(path: "rebase-merge/git-rebase-todo")
        try Data(("drop " + second + "\n").utf8).write(to: todo)
        guard let changed = try await service.rebaseRecovery() else {
            throw Failure.assertion("changed todo missing recovery")
        }
        try require(!changed.canContinue && changed.canAbort, "mutated todo restricts continuation")
        var rejected = false
        do {
            _ = try await service.recoverRebase(continueOperation: true, expected: before)
        } catch is ModelFailure { rejected = true }
        try require(rejected, "old todo confirmation rejects mutation")
        guard
            case .aborted(let head) = try await service.recoverRebase(
                continueOperation: false, expected: changed)
        else { throw Failure.assertion("mutated todo abort") }
        try require(head == plan.head, "mutated todo abort restores original")
        try require(
            try await fixture.git(["status", "--porcelain"]).text.isEmpty, "mutated todo abort clean")
    }

    private static func runPrivateMessageRefusal() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let (service, upstream, first, _) = try await fixture.makeRange()
        let plan = try await service.prepareInteractiveRebase(upstream: upstream)
        let steps = plan.steps.map {
            InteractiveRebaseStep(
                id: $0.id, subject: $0.subject, author: $0.author, action: $0.id == first ? .edit : .reword,
                message: $0.id == first ? nil : "Confirmed later message")
        }
        guard
            case .paused(let before) = try await service.executeInteractiveRebase(
                plan.replacing(steps: steps)), let descriptor = before.interactiveSession
        else { throw Failure.assertion("message mutation setup") }
        let directory = descriptor.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("external changed message".utf8).write(to: directory.appending(path: "message-1"))
        guard let changed = try await service.rebaseRecovery() else {
            throw Failure.assertion("changed message missing recovery")
        }
        try require(!changed.canContinue, "private message mutation refuses continuation")
        guard case .aborted = try await service.recoverRebase(continueOperation: false, expected: changed)
        else { throw Failure.assertion("private message abort") }
        try require(
            try await fixture.git(["rev-parse", "HEAD"]).text.trimmed == plan.head,
            "message mutation abort original")
    }

    private static func runRepeatedConflicts() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("file", "base\n")
        try await fixture.git(["add", "."])
        try await fixture.git(["commit", "-m", "Base"])
        try await fixture.git(["switch", "-c", "topic"])
        try fixture.write("file", "first\n")
        try await fixture.git(["add", "."])
        try await fixture.git(["commit", "-m", "First"])
        try fixture.write("file", "second\n")
        try await fixture.git(["add", "."])
        try await fixture.git(["commit", "-m", "Second"])
        let plan = try await fixture.service.prepareInteractiveRebase(upstream: try await fixture.upstream())
        guard
            case .conflicts(let first, let count) = try await fixture.service.executeInteractiveRebase(
                plan.replacing(steps: Array(plan.steps.reversed())))
        else { throw Failure.assertion("reordered conflict setup") }
        try require(count == 1 && first.canAbort, "first conflict observed")
        try fixture.write("file", "resolved second\n")
        try await fixture.git(["add", "file"])
        let reopened = try await fixture.reopen()
        guard let firstReady = try await reopened.rebaseRecovery() else {
            throw Failure.assertion("first conflict reopen")
        }
        guard
            case .conflicts(_, let count) = try await reopened.recoverRebase(
                continueOperation: true, expected: firstReady)
        else { throw Failure.assertion("second conflict not preserved") }
        try require(count == 1, "second conflict observed")
        try fixture.write("file", "final resolution\n")
        try await fixture.git(["add", "file"])
        guard let last = try await reopened.rebaseRecovery() else {
            throw Failure.assertion("last conflict recovery")
        }
        guard case .completed = try await reopened.recoverRebase(continueOperation: true, expected: last)
        else { throw Failure.assertion("repeated conflict completion") }
        try require(
            try await fixture.git(["show", "HEAD:file"]).text == "final resolution\n",
            "repeated conflict final bytes")
        try require(
            try await fixture.git(["log", "--reverse", "--format=%s", plan.upstream.oid + "..HEAD"]).text
                .trimmed == "Second\nFirst", "repeated conflict order")
        try require(try await fixture.git(["status", "--porcelain"]).text.isEmpty, "repeated conflict clean")
    }

    private static func runQueuedCancellation() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let (service, upstream, _, _) = try await fixture.makeRange()
        let plan = try await service.prepareInteractiveRebase(upstream: upstream)
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await service.sharedQueue.perform {
                started.continuation.yield(())
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
        }
        var ready = started.stream.makeAsyncIterator()
        _ = await ready.next()
        let pending = Task { try await service.executeInteractiveRebase(plan) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await service.sharedQueue.pendingOperationCountForTesting != 1, ContinuousClock.now < deadline {
            await Task.yield()
        }
        try require(
            await service.sharedQueue.pendingOperationCountForTesting == 1, "interactive write really queued")
        pending.cancel()
        var cancelled = false
        do { _ = try await pending.value } catch is CancellationError { cancelled = true }
        release.continuation.yield(())
        _ = try await holder.value
        try require(cancelled, "queued interactive write cancelled")
        try require(
            try await fixture.git(["rev-parse", "HEAD"]).text.trimmed == plan.head,
            "queued cancel HEAD unchanged")
        try require(
            try await fixture.git(["for-each-ref", "refs/wegit/rebase/"]).stdout.isEmpty,
            "queued cancel does not execute protected-ref write")
    }

    private static func runHookFailure() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let (service, upstream, _, _) = try await fixture.makeRange()
        let plan = try await service.prepareInteractiveRebase(upstream: upstream)
        let hook = service.location.gitDirectory.appending(path: "hooks/pre-rebase")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        var failed = false
        do { _ = try await service.executeInteractiveRebase(plan) } catch is GitFailure { failed = true }
        try require(failed, "pre-rebase hook failure is surfaced")
        try require(
            try await fixture.git(["rev-parse", "HEAD"]).text.trimmed == plan.head,
            "hook failure HEAD unchanged")
        try require(
            try await fixture.git(["status", "--porcelain"]).stdout.isEmpty,
            "hook failure index and worktree clean")
    }

    private enum Interruption { case cancel, timeout, unknown }

    private static func runInterruptedReply(_ interruption: Interruption) async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let (_, upstream, first, _) = try await fixture.makeRange()
        let marker = fixture.root.deletingLastPathComponent().appending(
            path: "WeGitInteractiveStarted-\(UUID())")
        let wrapper = fixture.root.deletingLastPathComponent().appending(
            path: "WeGitInteractiveGit-\(UUID())")
        defer {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: wrapper)
        }
        let body: String
        if interruption == .unknown {
            body = """
                #!/bin/sh
                real=\(shellLiteral(fixture.engine.executable.path))
                "$real" "$@"
                result=$?
                case " $* " in
                  *" rebase --interactive "*) if test "$result" -eq 0; then exit 75; fi ;;
                esac
                exit "$result"
                """
        } else {
            body = """
                #!/bin/sh
                case " $* " in
                  *" rebase --interactive "*)
                    printf '%s' "$GIT_SEQUENCE_EDITOR" > \(shellLiteral(marker.path))
                    sleep 30
                    ;;
                esac
                exec \(shellLiteral(fixture.engine.executable.path)) "$@"
                """
        }
        try Data(body.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let engine = GitEngine(executable: wrapper, environment: fixture.engine.environment)
        let service = RepositoryService(location: fixture.service.location, engine: engine)
        let plan = try await service.prepareInteractiveRebase(upstream: upstream)
        let steps = plan.steps.map {
            InteractiveRebaseStep(
                id: $0.id, subject: $0.subject, author: $0.author,
                action: $0.id == first ? .reword : .pick, message: $0.id == first ? "Confirmed rewrite" : nil)
        }
        let operation = Task {
            try await service.executeInteractiveRebase(
                plan.replacing(steps: steps), timeout: interruption == .timeout ? 0.5 : 120)
        }
        if interruption == .cancel {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try require(
                FileManager.default.fileExists(atPath: marker.path),
                "running cancellation reached actual Git process")
            operation.cancel()
        }
        var matched = false
        do { _ = try await operation.value } catch is CancellationError {
            matched = interruption == .cancel
        } catch ProcessFailure.cancelled { matched = interruption == .cancel } catch ProcessFailure.timedOut {
            matched = interruption == .timeout
        } catch is RebaseOutcomeUnknown { matched = interruption == .unknown }
        try require(matched, "interrupted reply has authoritative outcome")
        let state = try await fixture.service.status()
        try require(
            state.sequencer == .none && state.files.isEmpty, "interrupted reply leaves observed clean state")
        if interruption == .unknown {
            try require(state.head != plan.head, "unknown reply retains actually applied rewrite")
            try require(
                try await fixture.git(["log", "--reverse", "--format=%s", upstream.oid + "..HEAD"]).text
                    .trimmed == "Confirmed rewrite\nSecond", "unknown reply actual commits inspected")
            var staleRejected = false
            do { _ = try await service.executeInteractiveRebase(plan) } catch is ModelFailure {
                staleRejected = true
            }
            try require(staleRejected, "unknown write is not retried from old plan")
        } else {
            try require(state.head == plan.head, "cancelled or timed-out Git process did not rewrite HEAD")
            let script = try String(contentsOf: marker, encoding: .utf8)
            try require(
                !FileManager.default.fileExists(
                    atPath: URL(fileURLWithPath: script).deletingLastPathComponent().path),
                "known no-write interruption removes private session")
        }
    }

    private static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct Fixture {
        let root: URL
        let engine: GitEngine
        let service: RepositoryService

        static func create() async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "WeGitInteractiveExtended-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
            let engine = GitEngine(environment: environment)
            _ = try await engine.run(["init", "-b", "main"], in: root)
            for (key, value) in [
                ("user.name", "Interactive Extended"), ("user.email", "extended@example.invalid"),
                ("commit.gpgsign", "false"),
            ] {
                _ = try await engine.run(["config", key, value], in: root)
            }
            let location = try await RepositoryService.discover(root, engine: engine)
            return Fixture(
                root: root, engine: engine, service: RepositoryService(location: location, engine: engine))
        }

        func makeRange(third: Bool = false) async throws -> (RepositoryService, GitBranch, String, String) {
            try write("base.txt", "base\n")
            try await git(["add", "."])
            try await git(["commit", "-m", "Base"])
            try await git(["switch", "-c", "topic"])
            try write("one.txt", "one\n")
            try await git(["add", "."])
            try await git(["commit", "-m", "First"])
            let first = try await git(["rev-parse", "HEAD"]).text.trimmed
            try write("two.txt", "two\n")
            try await git(["add", "."])
            try await git(["commit", "-m", "Second"])
            let second = try await git(["rev-parse", "HEAD"]).text.trimmed
            if third {
                try write("three.txt", "three\n")
                try await git(["add", "."])
                try await git(["commit", "-m", "Third"])
            }
            try await git(["switch", "main"])
            let upstream = try await service.branches().first { $0.name == "main" }!
            try await git(["switch", "topic"])
            return (service, upstream, first, second)
        }

        func upstream() async throws -> GitBranch {
            guard let value = try await service.branches().first(where: { $0.name == "main" }) else {
                throw Failure.assertion("missing upstream")
            }
            return value
        }
        func reopen() async throws -> RepositoryService {
            RepositoryService(
                location: try await RepositoryService.discover(root, engine: engine), engine: engine)
        }
        @discardableResult func git(_ args: [String]) async throws -> ProcessResult {
            try await engine.run(args, in: root)
        }
        func write(_ path: String, _ value: String) throws {
            try Data(value.utf8).write(to: root.appending(path: path))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
