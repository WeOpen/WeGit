import Darwin
import Foundation
import Testing

@testable import WeGitCore

struct Fixture {
    let root: URL
    let engine: GitEngine
    let service: RepositoryService
    static func create() async throws -> Fixture {
        try await TestGitIsolationGate.shared.verify(TestGit.executable)
        let root = FileManager.default.temporaryDirectory.appending(path: "WeGitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = TestGit.engine()
        _ = try await engine.run(["init", "-b", "main"], in: root)
        for (name, value) in [
            ("user.name", "WeGit Tests"), ("user.email", "tests@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", root.appending(path: "no-hooks").path),
        ] {
            _ = try await engine.run(["config", name, value], in: root)
        }
        let location = try await RepositoryService.discover(root, engine: engine)
        return Fixture(
            root: root, engine: engine, service: RepositoryService(location: location, engine: engine))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ contents: String) throws {
        try Data(contents.utf8).write(to: root.appending(path: path))
    }
    func commit(_ message: String = "Initial") async throws -> String {
        let state = try await service.status()
        try await service.stage(paths: state.files.map(\.path), expectedHead: state.head)
        return try await service.commit(message: message, amend: false, expectedHead: state.head)
    }
}

struct ProcessTests {
    @Test(.timeLimit(.minutes(1))) func concurrentProcessesDoNotStarveTheirPipeReaders() async throws {
        let input = Data(repeating: 65, count: 200_000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            // This exceeds Dispatch's 64-thread soft limit. Every child must consume
            // stdin and drain both pipes, using separate default runner instances.
            for _ in 0..<128 {
                group.addTask {
                    let result = try await ProcessRunner().run(
                        ProcessRequest(
                            executable: URL(fileURLWithPath: "/usr/bin/perl"),
                            arguments: [
                                "-e",
                                "local $/; my $input = <STDIN>; print STDOUT $input; print STDERR 'e' x 200000;",
                            ],
                            input: input, timeout: 10))
                    #expect(result.exitCode == 0)
                    #expect(result.stdout == input)
                    #expect(result.stderr == Data(repeating: 101, count: 200_000))
                }
            }
            try await group.waitForAll()
        }
    }

    @Test(.timeLimit(.minutes(1))) func queuedProcessCancellationNeverLaunchesAndReturnsCapacity()
        async throws
    {
        let capacity = ProcessCapacity(limit: 1)
        let trace = Trace()
        let marker = FileManager.default.temporaryDirectory.appending(
            path: "WeGitCancelled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let owner = Task {
            try await capacity.perform {
                await trace.add(1)
                try await Task.sleep(for: .seconds(30))
            }
        }
        defer { owner.cancel() }
        while await trace.events.isEmpty { await Task.yield() }
        let queued = Task {
            try await ProcessRunner(capacity: capacity).run(
                ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path]))
        }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        await #expect(throws: CancellationError.self) { _ = try await queued.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        owner.cancel()
        await #expect(throws: CancellationError.self) { try await owner.value }
        // Release after cancellation must allow another process, not leak a permit.
        let result = try await ProcessRunner(capacity: capacity).run(
            ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []))
        #expect(result.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func drainsBothPipesAndClosesInput() async throws {
        let runner = ProcessRunner()
        let data = Data(repeating: 65, count: 200_000)
        let result = try await runner.run(
            ProcessRequest(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: data))
        #expect(result.stdout == data)
        let simultaneous = try await runner.run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: ["-e", "print STDOUT 'x' x 200000; print STDERR 'y' x 200000;"]))
        #expect(simultaneous.stdout.count == 200_000)
        #expect(simultaneous.stderr.count == 200_000)
    }

    @Test func timeoutTerminatesProcessGroup() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ProcessFailure.self) {
            _ = try await ProcessRunner().run(
                ProcessRequest(
                    executable: URL(fileURLWithPath: "/usr/bin/perl"),
                    arguments: ["-e", "if (fork() == 0) { sleep 30 } else { sleep 30 }"], timeout: 0.1))
        }
        #expect(start.duration(to: clock.now) < .seconds(3))
    }

    @Test func spawnedChildReceivesUnblockedTerminationSignals() async throws {
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [
                    "-e",
                    """
                    use POSIX qw(SIG_BLOCK SIGTERM SIGINT SIGHUP SIGQUIT);
                    my $mask = POSIX::SigSet->new();
                    defined(POSIX::sigprocmask(SIG_BLOCK, POSIX::SigSet->new(), $mask)) or die "mask query failed";
                    print join(',', map { $mask->ismember($_) } (SIGTERM, SIGINT, SIGHUP, SIGQUIT));
                    """,
                ]))
        #expect(result.exitCode == 0)
        #expect(result.text == "0,0,0,0")
    }

    @Test(.timeLimit(.minutes(1))) func executingGroupCancellationDeliversTermAndReturnsCapacity()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appending(path: "WeGitProcessTerm-\(UUID())")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appending(path: "ready")
        let trapped = root.appending(path: "term")
        var environment = ProcessInfo.processInfo.environment
        environment["WEGIT_PROCESS_READY"] = ready.path
        environment["WEGIT_PROCESS_TERM"] = trapped.path
        let runner = ProcessRunner(capacity: ProcessCapacity(limit: 1))
        let task = Task {
            try await runner.run(
                ProcessRequest(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        """
                        /bin/sleep 30 &
                        child=$!
                        trap 'wait "$child" 2>/dev/null; printf handled > "$WEGIT_PROCESS_TERM"; exit 143' TERM
                        printf '%s\\n%s\\n' "$$" "$child" > "$WEGIT_PROCESS_READY"
                        wait "$child"
                        """,
                    ], environment: environment, timeout: 5))
        }
        defer { task.cancel() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: ready.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            task.cancel()
            _ = await task.result
            Issue.record("The cancellation fixture never reached an executing process")
            return
        }
        let ids = try String(contentsOf: ready, encoding: .utf8)
            .split(separator: "\n").compactMap { Int32($0) }
        let processID = try #require(ids.first)
        #expect(ids.count == 2)
        #expect(ids.allSatisfy { Darwin.kill($0, 0) == 0 })
        let start = clock.now
        task.cancel()
        switch await task.result {
        case .success: Issue.record("An executing cancelled process returned success")
        case .failure(let error):
            guard case .cancelled? = error as? ProcessFailure else {
                Issue.record("Unexpected cancellation result: \(error)")
                return
            }
        }
        #expect(start.duration(to: clock.now) < .milliseconds(500))
        let groupGone = Darwin.kill(-processID, 0) == -1 && errno == ESRCH
        #expect(groupGone)
        #expect(try Data(contentsOf: trapped) == Data("handled".utf8))
        let next = try await runner.run(
            ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []))
        #expect(next.exitCode == 0)
    }

    @Test func cancellationAndOutputLimit() async throws {
        let task = Task {
            try await ProcessRunner().run(
                ProcessRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]))
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        await #expect(throws: ProcessFailure.self) {
            _ = try await ProcessRunner().run(
                ProcessRequest(
                    executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], outputLimit: 1024))
        }
    }

    @Test func launchFailureAndClosedStdinDoNotCrash() async throws {
        await #expect(throws: ProcessFailure.self) {
            _ = try await ProcessRunner().run(
                ProcessRequest(executable: URL(fileURLWithPath: "/does/not/exist"), arguments: []))
        }
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                input: Data(repeating: 1, count: 200_000)))
        #expect(result.exitCode == 0)
    }
}

private actor Trace {
    var events: [Int] = []
    func add(_ n: Int) { events.append(n) }
}

struct QueueTests {
    @Test func ownsPermitAcrossSuspension() async throws {
        let queue = RepositoryOperationQueue()
        let trace = Trace()
        let first = Task {
            try await queue.perform {
                await trace.add(1)
                try await Task.sleep(for: .milliseconds(150))
                await trace.add(2)
            }
        }
        while await trace.events.isEmpty { await Task.yield() }
        let second = Task { try await queue.perform { await trace.add(3) } }
        try await first.value
        try await second.value
        #expect(await trace.events == [1, 2, 3])
    }

    @Test func cancelledWaiterNeverExecutesAndPermitRecovers() async throws {
        let queue = RepositoryOperationQueue()
        let trace = Trace()
        let first = Task {
            try await queue.perform {
                await trace.add(1)
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        while await trace.events.isEmpty { await Task.yield() }
        let cancelled = Task { try await queue.perform { await trace.add(99) } }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        try await first.value
        await #expect(throws: (any Error).self) { try await cancelled.value }
        try await queue.perform { await trace.add(2) }
        #expect(await trace.events == [1, 2])
    }
}

struct RepositoryTests {
    @Test func literalPathsUnbornUnstageAndPartialCommit() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("literal[1].txt", "one\ntwo\nthree\n")
        try f.write("literal1.txt", "leave me untracked\n")
        try f.write("空 格\nfile.txt", "special\n")
        let initial = try await f.service.status()
        #expect(initial.head == nil)
        #expect(initial.branch == "main")
        #expect(initial.files.count == 3)
        try await f.service.stage(paths: ["literal[1].txt"], expectedHead: nil)
        #expect(try await f.service.status().files.filter(\.staged).map(\.path) == ["literal[1].txt"])
        try await f.service.unstage(paths: ["literal[1].txt"], expectedHead: nil)
        #expect(FileManager.default.fileExists(atPath: f.root.appending(path: "literal[1].txt").path))
        try await f.service.stage(paths: ["literal[1].txt"], expectedHead: nil)
        let oid = try await f.service.commit(message: "First", amend: false, expectedHead: nil)
        #expect(oid.count >= 40)
        #expect(try await f.service.status().files.count == 2)
    }

    @Test func hunkStageStalePatchAndMessageOnlyAmend() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("code.txt", (1...30).map { "line \($0)\n" }.joined())
        let oid = try await f.commit()
        try f.write(
            "code.txt", (1...30).map { $0 == 2 || $0 == 28 ? "edited \($0)\n" : "line \($0)\n" }.joined())
        let diff = try await f.service.diff(path: "code.txt", layer: .unstaged)
        #expect(diff.hunks.count == 2)
        try await f.service.apply(hunk: diff.hunks[0], from: diff)
        let state = try await f.service.status()
        #expect(state.files[0].staged && state.files[0].unstaged)
        await #expect(throws: ModelFailure.self) {
            try await f.service.apply(hunk: diff.hunks[1], from: diff)
        }
        try await f.service.unstage(paths: ["code.txt"], expectedHead: oid)
        let amended = try await f.service.commit(message: "Message only", amend: true, expectedHead: oid)
        #expect(amended != oid)
        #expect(try await f.service.status().files[0].unstaged)
    }

    @Test func historyUsesLengthDelimitedObjects() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("test.txt", "hello\n")
        let oid = try await f.commit("Subject\n\nBody with separators \u{1e} and \u{1f}")
        let history = try await f.service.history()
        #expect(history.count == 1)
        #expect(history[0].id == oid)
        #expect(history[0].message.contains("\u{1e}"))
        #expect(history[0].parents.isEmpty)
        #expect(try await f.service.commitDiff(history[0]).contains("+hello"))
    }

    @Test func mergeConflictCanBeResolvedAndContinued() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("shared.txt", "base\n")
        let base = try await f.commit()
        try await f.service.createBranch("feature", expectedHead: base)
        try f.write("shared.txt", "feature\n")
        let feature = try await f.commit("Feature")
        let main = try #require(try await f.service.branches().first { $0.name == "main" })
        try await f.service.switchBranch(main, expectedHead: feature)
        try f.write("shared.txt", "main\n")
        let mainHead = try await f.commit("Main")
        let branch = try #require(try await f.service.branches().first { $0.name == "feature" })
        await #expect(throws: GitFailure.self) { try await f.service.merge(branch, expectedHead: mainHead) }
        let conflict = try await f.service.status()
        #expect(conflict.sequencer == .merge)
        #expect(conflict.conflicts.count == 1)
        try f.write("shared.txt", "resolved\n")
        try await f.service.markResolved(path: "shared.txt", expectedHead: mainHead)
        try await f.service.sequencer(continueOperation: true, expected: .merge)
        #expect(try await f.service.status().sequencer == .none)
        #expect(try await f.service.history()[0].parents.count == 2)
    }

    @Test func rejectsWrongHeadAndInvalidPaths() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file.txt", "hello")
        _ = try await f.commit()
        await #expect(throws: ModelFailure.self) {
            try await f.service.stage(paths: ["file.txt"], expectedHead: nil)
        }
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.diff(path: "../outside", layer: .untracked)
        }
    }

    @Test func hookFailurePreservesIndexAndMessage() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let hooks = f.root.appending(path: "no-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appending(path: "pre-commit")
        try Data("#!/bin/sh\nprintf 'Hook intentionally failed\\n' >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try f.write("file.txt", "content")
        try await f.service.stage(paths: ["file.txt"], expectedHead: nil)
        await #expect(throws: GitFailure.self) {
            _ = try await f.service.commit(message: "Keep draft", amend: false, expectedHead: nil)
        }
        #expect(try await f.service.head() == nil)
        #expect(try await f.service.status().files[0].staged)
    }
}

struct ContextAndWatcherTests {
    @Test func rejectsSameCommitOnDifferentBranch() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file.txt", "base")
        let oid = try await f.commit()
        let pinned = f.service.expectingBranch("main")
        _ = try await f.engine.run(["switch", "-c", "other"], in: f.root)
        try f.write("file.txt", "changed")
        await #expect(throws: ModelFailure.self) {
            try await pinned.stage(paths: ["file.txt"], expectedHead: oid)
        }
        #expect(try await f.service.status().files[0].unstaged)
    }

    @Test func receivesExternalFileEvents() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let watcher = try RepositoryWatcher(paths: [f.root.path]) { continuation.yield(()) }
        defer {
            watcher.stop()
            continuation.finish()
        }
        try f.write("external.txt", "changed outside the application")
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in events { return true }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return false
            }
            let received = try await group.next()
            group.cancelAll()
            #expect(received == true)
        }
    }
}

struct DiffPresentationTests {
    @Test func preservesCRLFAndNoFinalNewlineInPatch() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("windows.txt", "one\r\ntwo\r\nlast")
        let oid = try await f.commit()
        try f.write("windows.txt", "one\r\nupdated\r\nlast")
        let diff = try await f.service.diff(path: "windows.txt", layer: .unstaged)
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].lines.contains { $0.kind == "\\" })
        try await f.service.apply(hunk: diff.hunks[0], from: diff)
        let staged = try await f.engine.run(["show", ":windows.txt"], in: f.root).stdout
        #expect(staged == Data("one\r\nupdated\r\nlast".utf8))
        try await f.service.unstage(paths: ["windows.txt"], expectedHead: oid)
    }

    @Test func alignsReplacementsAndUnequalSides() throws {
        let patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,2 +1,3 @@\n-old\n+new\n+extra\n context\n"
        let diff = try DiffParser.parse(Data(patch.utf8), path: "a", layer: .unstaged, head: nil)
        let rows = DiffAlignment.rows(diff.hunks[0].lines)
        #expect(rows.count == 3)
        #expect(rows[0].old?.content == "old" && rows[0].new?.content == "new")
        #expect(rows[1].old == nil && rows[1].new?.content == "extra")
        #expect(rows[2].old?.oldLine == 2 && rows[2].new?.newLine == 3)
    }

    @Test func rejectsTruncatedRenameAndNonUTF8Paths() {
        #expect(throws: ModelFailure.self) {
            _ = try StatusParser.parse(Data("2 R. N... 100644 100644 100644 abc def R100 new\0".utf8))
        }
        #expect(throws: ModelFailure.self) { _ = try StatusParser.parse(Data([63, 32, 255, 0])) }
    }
}

struct CompatibilityTests {
    @Test func detectsInstalledGitAndRejectsInvalidPreference() async throws {
        let installation = try await GitInstallation.detect()
        #expect(installation.version.hasPrefix("git version "))
        await #expect(throws: ModelFailure.self) {
            _ = try await GitInstallation.detect(preferred: URL(fileURLWithPath: "/invalid/git"))
        }
    }

    @Test func respectsExistingSSHSigningConfiguration() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let key = f.root.appending(path: ".git/signing-test")
        _ = try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                arguments: ["-q", "-t", "ed25519", "-N", "", "-f", key.path]))
        for (name, value) in [
            ("gpg.format", "ssh"), ("user.signingkey", key.path), ("commit.gpgsign", "true"),
        ] {
            _ = try await f.engine.run(["config", name, value], in: f.root)
        }
        try f.write("signed.txt", "signed content")
        _ = try await f.commit("Signed test commit")
        let object = try await f.engine.run(["cat-file", "-p", "HEAD"], in: f.root).text
        #expect(object.contains("gpgsig -----BEGIN SSH SIGNATURE-----"))
    }
}
