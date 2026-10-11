import Foundation
import Testing

@testable import WeGitCore

private struct RemoteFixture {
    let local: Fixture
    let peer: Fixture
    let bare: URL
    let base: String

    static func create(published: Bool = true) async throws -> RemoteFixture {
        let local = try await Fixture.create()
        let peer = try await Fixture.create()
        let bare = local.root.appendingPathExtension("remote.git")
        do {
            _ = try await local.engine.run(["init", "--bare", "-b", "main", bare.path])
            for fixture in [local, peer] {
                _ = try await fixture.engine.run(["remote", "add", "origin", bare.path], in: fixture.root)
            }
            try local.write("file", "base\n")
            try local.write("second", "base\n")
            let base = try await local.commit("Base")
            if published {
                _ = try await local.engine.run(["push", "--set-upstream", "origin", "main"], in: local.root)
                try await peer.service.fetch(remote: "origin")
                _ = try await peer.engine.run(["reset", "--hard", "refs/remotes/origin/main"], in: peer.root)
            }
            return RemoteFixture(local: local, peer: peer, bare: bare, base: base)
        } catch {
            local.remove()
            peer.remove()
            try? FileManager.default.removeItem(at: bare)
            throw error
        }
    }

    func remove() {
        local.remove()
        peer.remove()
        try? FileManager.default.removeItem(at: bare)
    }

    func remoteHead(_ ref: String = "refs/heads/main", at url: URL? = nil) async throws -> String? {
        let result = try await local.engine.run(
            ["rev-parse", "--verify", "--end-of-options", ref], in: url ?? bare, accepted: [0, 128])
        return result.exitCode == 0 ? result.text.removingLastNewline : nil
    }

    func publishPeer() async throws -> String {
        let head = try await peer.commit("Remote change")
        _ = try await peer.engine.run(["push", "origin", "main"], in: peer.root)
        return head
    }

    func temporaryRefs() async throws -> String {
        try await local.engine.run(["for-each-ref", "refs/wegit/pull"], in: local.root).text
    }
}

private actor RemoteInterference: ProcessRunning {
    enum Mode: Sendable, Equatable {
        case fetchHeadRace, cancelledFetch, upstreamFailure, switchBranch
        case rewrite(command: String, source: String, destination: String)
    }
    let mode: Mode
    private var interfered = false
    private(set) var pushes = 0

    init(_ mode: Mode) { self.mode = mode }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("push") { pushes += 1 }
        if !interfered, case .rewrite(let command, let source, let destination) = mode,
            request.arguments.contains(command)
        {
            interfered = true
            var other = request
            other.arguments = ["config", "--local", "url.\(destination).insteadOf", source]
            _ = try await ProcessRunner().run(other)
        }
        if mode == .upstreamFailure,
            request.arguments.contains(where: { $0.hasPrefix("--set-upstream-to=") })
        {
            throw ProcessFailure.launch(EACCES)
        }
        let result = try await ProcessRunner().run(request)
        if !interfered, request.arguments.contains("fetch"),
            request.arguments.contains(where: { $0.contains(":refs/wegit/pull/") })
        {
            interfered = true
            switch mode {
            case .fetchHeadRace:
                var other = request
                other.arguments = ["fetch", "--no-tags", "origin", "refs/heads/other"]
                _ = try await ProcessRunner().run(other)
            case .cancelledFetch: throw ProcessFailure.cancelled
            case .switchBranch:
                var other = request
                other.arguments = ["switch", "-c", "moved-during-fetch"]
                _ = try await ProcessRunner().run(other)
            case .upstreamFailure, .rewrite: break
            }
        }
        return result
    }
}

private actor LostPushReply: ProcessRunning {
    enum Mode: CaseIterable, Sendable {
        case timeout, cancellation, transportFailure, remoteFailure
    }
    let mode: Mode
    let failVerification: Bool
    private var lost = false
    private(set) var pushes = 0
    private(set) var queries = 0

    init(_ mode: Mode, failVerification: Bool = false) {
        self.mode = mode
        self.failVerification = failVerification
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let push = request.arguments.contains("push")
        if push { pushes += 1 }
        if request.arguments.contains("ls-remote") {
            queries += 1
            if lost && failVerification { throw ProcessFailure.timedOut }
        }
        let result = try await ProcessRunner().run(request)
        if push && result.exitCode == 0 && !lost {
            lost = true
            switch mode {
            case .timeout: throw ProcessFailure.timedOut
            case .cancellation:
                withUnsafeCurrentTask { $0?.cancel() }
                throw ProcessFailure.cancelled
            case .transportFailure:
                return ProcessResult(
                    stdout: Data(), stderr: Data("fatal: fixture lost the response\n".utf8),
                    exitCode: 128, duration: result.duration)
            case .remoteFailure:
                return ProcessResult(
                    stdout: Data(
                        "!\t\(request.arguments.last ?? "")\t[remote failure] (response lost)\n".utf8),
                    stderr: Data("error: fixture lost the response\n".utf8), exitCode: 1,
                    duration: result.duration)
            }
        }
        return result
    }
}

struct RemoteWorkflowTests {
    @Test(arguments: LostPushReply.Mode.allCases) fileprivate func lostPushRepliesRequireReadOnlyVerification(
        mode: LostPushReply.Mode
    ) async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        try f.local.write("local", "delivered before response loss\n")
        let head = try await f.local.commit()
        let runner = LostPushReply(mode)
        let service = RepositoryService(
            location: f.local.service.location, engine: TestGit.engine(runner: runner))
        let plan = try await service.preparePush(
            remote: "origin", branch: "main", forceWithLease: true, expectedHead: head)
        let operation = Task { try await service.push(plan) }
        let unknown: PushOutcomeUnknown
        do {
            _ = try await operation.value
            Issue.record("Missing unknown push outcome")
            return
        } catch { unknown = try #require(error as? PushOutcomeUnknown) }
        #expect(try await f.remoteHead() == head)
        #expect(await runner.pushes == 1)
        #expect(await runner.queries == 1)
        let bytes = try JSONEncoder().encode(unknown.receipt)
        #expect(!String(decoding: bytes, as: UTF8.self).contains(f.bare.path))
        let saved = try JSONDecoder().decode(PushReceipt.self, from: bytes)
        let restored = try await service.restorePushPlan(saved)
        let result = try await service.verifyPushOutcome(restored)
        #expect(result.matches && result.observedOID == head)
        #expect(await runner.pushes == 1)
        #expect(await runner.queries == 2)
        #expect(try await f.local.service.head() == head)
    }

    @Test func verificationKeepsTheOriginalDestinationAndDoesNotDependOnCurrentHead() async throws {
        let f = try await RemoteFixture.create()
        let other = f.bare.appendingPathExtension("other")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: other)
        }
        _ = try await f.local.engine.run(["clone", "--bare", "--", f.bare.path, other.path])
        try f.local.write("local", "confirmed delivery\n")
        let head = try await f.local.commit()
        let runner = LostPushReply(.timeout)
        let service = RepositoryService(
            location: f.local.service.location, engine: TestGit.engine(runner: runner))
        let plan = try await service.preparePush(remote: "origin", branch: "main", expectedHead: head)
        do {
            _ = try await service.push(plan)
            Issue.record("Missing unknown outcome")
        } catch { #expect(error is PushOutcomeUnknown) }
        _ = try await f.local.engine.run(["config", "remote.origin.url", other.path], in: f.local.root)
        try f.local.write("later", "new local head\n")
        let later = try await f.local.commit()
        #expect(later != head)
        let result = try await service.verifyPushOutcome(plan)
        #expect(result.matches)
        #expect(try await f.remoteHead(at: other) == f.base)
        let queries = await runner.queries
        await #expect(throws: ModelFailure.self) { _ = try await service.restorePushPlan(PushReceipt(plan)) }
        #expect(await runner.queries == queries)
        #expect(await runner.pushes == 1)
        #expect(try await f.local.service.head() == later)
    }

    @Test func remoteChangesAfterDeliveryStayUncertainAndVerificationCannotWrite() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        try f.local.write("local", "delivered\n")
        let head = try await f.local.commit()
        let runner = LostPushReply(.transportFailure)
        let service = RepositoryService(
            location: f.local.service.location, engine: TestGit.engine(runner: runner))
        let plan = try await service.preparePush(remote: "origin", branch: "main", expectedHead: head)
        do {
            _ = try await service.push(plan)
            Issue.record("Missing unknown outcome")
        } catch { #expect(error is PushOutcomeUnknown) }
        _ = try await f.local.engine.run(["update-ref", "refs/heads/main", f.base, head], in: f.bare)
        let result = try await service.verifyPushOutcome(plan)
        #expect(!result.matches && result.observedOID == f.base)
        _ = try await f.local.engine.run(["update-ref", "-d", "refs/heads/main", f.base], in: f.bare)
        let missing = try await service.verifyPushOutcome(plan)
        #expect(!missing.matches && missing.observedOID == nil)
        #expect(await runner.pushes == 1)
        #expect(try await f.remoteHead() == nil)
    }

    @Test func failedVerificationNeverRetriesTheWrite() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        try f.local.write("local", "delivered\n")
        let head = try await f.local.commit()
        let runner = LostPushReply(.timeout, failVerification: true)
        let service = RepositoryService(
            location: f.local.service.location, engine: TestGit.engine(runner: runner))
        let plan = try await service.preparePush(remote: "origin", branch: "main", expectedHead: head)
        do {
            _ = try await service.push(plan)
            Issue.record("Missing unknown outcome")
        } catch { #expect(error is PushOutcomeUnknown) }
        await #expect(throws: ProcessFailure.self) { _ = try await service.verifyPushOutcome(plan) }
        #expect(await runner.pushes == 1)
        #expect(try await f.remoteHead() == head)
    }

    @Test func commitAndPushRetainsTheDeliveredCommitWhenItsReplyIsLost() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        try f.local.write("local", "commit exactly once\n")
        try await f.local.service.stage(paths: ["local"], expectedHead: f.base)
        let runner = LostPushReply(.remoteFailure)
        let service = RepositoryService(
            location: f.local.service.location, engine: TestGit.engine(runner: runner))
        let remote = try await service.remoteDetails(name: "origin")
        let result = try await service.commitAndPush(
            message: "Delivered with missing reply", amend: false, remote: remote, branch: "main",
            expectedHead: f.base)
        let unknown = try #require(result.failure as? PushOutcomeUnknown)
        #expect(result.push == nil && unknown.receipt.head == result.commit)
        #expect(try await f.remoteHead() == result.commit)
        #expect(try await service.verifyPushOutcome(unknown.plan).matches)
        #expect(await runner.pushes == 1)
        #expect(
            try await f.local.engine.run(["rev-list", "--count", "HEAD"], in: f.local.root).text == "2\n")
    }

    @Test(arguments: [
        "https://user:fixture-password@example.invalid/repo?access_token=fixture-token",
        "ssh://user:fixture-password@example.invalid/repo",
        "https://example.invalid/repo?custom_key=fixture-token",
        "https://example.invalid/repo#fixture-token",
    ]) func receiptsNeverPersistCredentialBearingDestinations(destination: String) async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        let original = try await f.local.service.preparePush(
            remote: "origin", branch: "main", expectedHead: f.base)
        let remote = GitRemote(
            name: "origin", fetchURL: f.bare.path,
            pushURLs: [destination],
            rawURLs: [f.bare.path], rawPushURLs: [], fetchRefspecs: [])
        let plan = PushPlan(
            remote: remote, pushURLIndex: 0, targetRef: original.targetRef, localBranch: "main", head: f.base,
            expectedRemoteOID: f.base, forceWithLease: false, setUpstream: false,
            location: f.local.service.location)
        let receipt = PushReceipt(plan)
        let saved = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        #expect(receipt.destinationFingerprint == nil)
        #expect(
            !saved.contains("fixture-password") && !saved.contains("fixture-token")
                && !saved.contains("example.invalid"))
        await #expect(throws: ModelFailure.self) { _ = try await f.local.service.restorePushPlan(receipt) }
    }

    @Test func porcelainRemoteFailureAndPartialReportsCannotProveRejection() {
        let ref = String(repeating: "a", count: 40) + ":refs/heads/main"
        func parse(_ text: String) -> String? {
            GitEngine.rejectedPushRefspec(Data(text.utf8), requested: ref)
        }
        #expect(parse("!\t\(ref)\t[remote rejected] (hook declined)\n") == ref)
        #expect(parse("!\t\(ref)\t[rejected] (non-fast-forward)\n") == ref)
        #expect(parse("!\t\(ref)\t[remote failure] (response lost)\n") == nil)
        #expect(parse("!\t\(ref)\t[rejected] (reason)") == nil)
        #expect(parse("!\t\(ref)\t[rejected] (reason)\n*\tother:refs/heads/other\t[new branch]\n") == nil)
        #expect(parse("!\tother:refs/heads/other\t[rejected] (reason)\n") == nil)
        #expect(parse("!\t\(ref)\t[rejected] (incomplete\n") == nil)
    }

    @Test func restoredReceiptsRejectAnotherRepositoryBeforeQueryingItsRemote() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        let original = try await f.local.service.preparePush(
            remote: "origin", branch: "main", expectedHead: f.base)
        do {
            _ = try await f.peer.service.restorePushPlan(PushReceipt(original))
            Issue.record("A receipt was accepted in another repository")
        } catch {
            guard case ModelFailure.repositoryReplaced = error else { throw error }
        }
        #expect(try await f.remoteHead() == f.base)
    }

    @Test func relativeDestinationsCannotChangeAfterMovingTheRepository() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        _ = try await f.local.engine.run(
            [
                "config", "remote.origin.url", "../" + f.bare.lastPathComponent,
            ], in: f.local.root)
        let plan = try await f.local.service.preparePush(
            remote: "origin", branch: "main", expectedHead: f.base)
        let receipt = PushReceipt(plan)
        let moved = f.peer.root.appending(path: "moved-local")
        try FileManager.default.moveItem(at: f.local.root, to: moved)
        let location = try await RepositoryService.discover(moved, engine: f.local.engine)
        #expect(location.persistenceID == receipt.repositoryID)
        let service = RepositoryService(location: location, engine: f.local.engine)
        do {
            _ = try await service.restorePushPlan(receipt)
            Issue.record("A moved relative destination was accepted")
        } catch {
            #expect(error.localizedDescription.contains("地址已变化"))
        }
        #expect(try await f.remoteHead() == f.base)
    }

    @Test(arguments: [true, false]) func confirmedLocalDestinationsPreserveNewlines(relative: Bool)
        async throws
    {
        let f = try await RemoteFixture.create()
        let other = f.bare.appendingPathExtension("line\nbreak")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: other)
        }
        _ = try await f.local.engine.run(["clone", "--bare", "--", f.bare.path, other.path])
        let url = relative ? "../" + other.lastPathComponent : other.path
        _ = try await f.local.engine.run(["config", "remote.origin.url", url], in: f.local.root)
        try f.local.write("local", "newline destination\n")
        let head = try await f.local.commit()
        let plan = try await f.local.service.preparePush(
            remote: "origin", branch: "main", forceWithLease: true, expectedHead: head)
        #expect(plan.remote.pushURLs == [url])
        #expect(plan.expectedRemoteOID == f.base)
        _ = try await f.local.service.push(plan)
        #expect(try await f.remoteHead(at: other) == head)
        #expect(try await f.local.service.configValues("remote.origin.url") == [url])
    }

    @Test func configuredEmptyURLValuesClearEarlierDestinations() async throws {
        let f = try await RemoteFixture.create()
        let other = f.bare.appendingPathExtension("reset")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: other)
        }
        _ = try await f.local.engine.run(["clone", "--bare", "--", f.bare.path, other.path])
        for (key, value) in [
            ("remote.origin.url", ""), ("remote.origin.url", other.path),
            ("remote.origin.pushurl", f.bare.path), ("remote.origin.pushurl", ""),
        ] {
            _ = try await f.local.engine.run(["config", "--add", key, value], in: f.local.root)
        }
        try f.local.write("local", "last reset wins\n")
        let head = try await f.local.commit()
        let plan = try await f.local.service.preparePush(remote: "origin", branch: "main", expectedHead: head)
        #expect(plan.remote.fetchURL == other.path && plan.remote.pushURLs == [other.path])
        _ = try await f.local.service.push(plan)
        #expect(try await f.remoteHead() == f.base)
        #expect(try await f.remoteHead(at: other) == head)
    }

    @Test func pushCannotBeRedirectedAfterItsDestinationWasVerified() async throws {
        let f = try await RemoteFixture.create()
        let other = f.bare.appendingPathExtension("redirected")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: other)
        }
        _ = try await f.local.engine.run(["clone", "--bare", "--", f.bare.path, other.path])
        try f.local.write("local", "confirmed destination only\n")
        let head = try await f.local.commit()
        let plan = try await f.local.service.preparePush(
            remote: "origin", branch: "main", forceWithLease: true, expectedHead: head)
        #expect(plan.expectedRemoteOID == f.base)
        let runner = RemoteInterference(
            .rewrite(command: "push", source: f.bare.path, destination: other.path))
        let service = RepositoryService(
            location: f.local.service.location,
            engine: TestGit.engine(runner: runner, environment: f.local.engine.environment))
        _ = try await service.push(plan)
        #expect(try await f.remoteHead() == head)
        #expect(try await f.remoteHead(at: other) == f.base)
    }

    @Test func pullCannotBeRedirectedAfterItsDestinationWasVerified() async throws {
        let f = try await RemoteFixture.create()
        let other = f.bare.appendingPathExtension("redirected")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: other)
        }
        _ = try await f.local.engine.run(["clone", "--bare", "--", f.bare.path, other.path])
        try f.peer.write("remote", "confirmed source\n")
        let head = try await f.publishPeer()
        let plan = try await f.local.service.preparePull(
            remote: "origin", branch: "main", strategy: .fastForwardOnly, expectedHead: f.base)
        let runner = RemoteInterference(
            .rewrite(command: "fetch", source: f.bare.path, destination: other.path))
        let service = RepositoryService(
            location: f.local.service.location,
            engine: TestGit.engine(runner: runner, environment: f.local.engine.environment))
        _ = try await service.pull(plan)
        #expect(try await f.local.service.head() == head)
        #expect(try await f.remoteHead(at: other) == f.base)
    }

    @Test func anEffectiveURLIsNotRewrittenASecondTimeDuringLeaseLookup() async throws {
        let f = try await RemoteFixture.create()
        let other = f.bare.appendingPathExtension("second-rewrite")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: other)
        }
        _ = try await f.local.engine.run(["clone", "--bare", "--", f.bare.path, other.path])
        for (key, value) in [
            ("remote.origin.url", "wegit-fixture:"),
            ("url.\(f.bare.path).insteadOf", "wegit-fixture:"),
            ("url.\(other.path).insteadOf", f.bare.path),
        ] {
            _ = try await f.local.engine.run(["config", "--local", key, value], in: f.local.root)
        }
        try f.local.write("local", "one rewrite\n")
        let head = try await f.local.commit()
        let plan = try await f.local.service.preparePush(
            remote: "origin", branch: "main", forceWithLease: true, expectedHead: head)
        #expect(plan.expectedRemoteOID == f.base)
        _ = try await f.local.service.push(plan)
        #expect(try await f.remoteHead() == head)
        #expect(try await f.remoteHead(at: other) == f.base)
    }

    @Test func configuredNoFastForwardPullCreatesAnExplicitMergeCommit() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        _ = try await f.local.engine.run(["config", "pull.ff", "false"], in: f.local.root)
        let preference = try await f.local.service.pullPreference()
        #expect(preference.strategy == .merge && preference.createMergeCommit)
        #expect(preference.source.contains("pull.ff"))
        try f.peer.write("remote", "remote\n")
        let remote = try await f.publishPeer()
        let plan = try await f.local.service.preparePull(
            remote: "origin", branch: "main", strategy: .merge,
            createMergeCommit: preference.createMergeCommit, expectedHead: f.base)
        _ = try await f.local.service.pull(plan)
        let parents = try await f.local.engine.run(["show", "-s", "--format=%P", "HEAD"], in: f.local.root)
            .text.removingLastNewline
        #expect(parents == f.base + " " + remote)
    }

    @Test func commitThenPushFailureCanRetryOnlyThePush() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        try f.peer.write("remote", "remote\n")
        let remoteHead = try await f.publishPeer()
        try f.local.write("local", "local\n")
        try await f.local.service.stage(paths: ["local"], expectedHead: f.base)
        let remote = try await f.local.service.remoteDetails(name: "origin")
        let result = try await f.local.service.commitAndPush(
            message: "Commit exactly once", amend: false, remote: remote, branch: "main", expectedHead: f.base
        )
        #expect(result.push == nil && result.failure != nil && result.commit != f.base)
        #expect(try await f.local.service.head() == result.commit)
        #expect(try await f.remoteHead() == remoteHead)
        #expect(try await f.local.service.status().files.isEmpty)
        let retry = try await f.local.service.preparePush(
            remote: "origin", branch: "main", forceWithLease: true, expectedHead: result.commit)
        _ = try await f.local.service.push(retry)
        #expect(try await f.remoteHead() == result.commit)
        #expect(
            try await f.local.engine.run(["rev-list", "--count", "HEAD"], in: f.local.root).text == "2\n")
    }

    @Test func cancellingAfterCommitRetainsTheCommittedOutcome() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        try f.local.write("local", "local\n")
        try await f.local.service.stage(paths: ["local"], expectedHead: f.base)
        let remote = try await f.local.service.remoteDetails(name: "origin")
        let operation = Task {
            try await f.local.service.commitAndPush(
                message: "Keep this commit", amend: false, remote: remote, branch: "main",
                expectedHead: f.base
            ) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let result = try await operation.value
        #expect(result.commit != f.base && result.push == nil && result.failure != nil)
        #expect(try await f.local.service.head() == result.commit)
        #expect(try await f.remoteHead() == f.base)
    }

    @Test func invalidPushTargetDoesNotCreateAnAvoidableLocalCommit() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        try f.local.write("local", "local\n")
        try await f.local.service.stage(paths: ["local"], expectedHead: f.base)
        let remote = try await f.local.service.remoteDetails(name: "origin")
        await #expect(throws: ModelFailure.self) {
            _ = try await f.local.service.commitAndPush(
                message: "Not committed", amend: false, remote: remote, branch: "--invalid",
                expectedHead: f.base)
        }
        #expect(try await f.local.service.head() == f.base)
        #expect(try await f.local.service.status().files.contains { $0.staged })
    }

    @Test func firstPushCreatesOnlyTheSelectedBranchAndSetsItsUpstream() async throws {
        let f = try await RemoteFixture.create(published: false)
        defer { f.remove() }
        _ = try await f.local.engine.run(["tag", "unrequested-tag"], in: f.local.root)
        _ = try await f.local.engine.run(["config", "push.followTags", "true"], in: f.local.root)
        let plan = try await f.local.service.preparePush(
            remote: "origin", branch: "published", setUpstream: true, expectedHead: f.base)
        #expect(plan.expectedRemoteOID == nil)
        let result = try await f.local.service.push(plan)
        #expect(result.upstreamConfigured && result.warning == nil)
        #expect(try await f.remoteHead("refs/heads/published") == f.base)
        #expect(try await f.remoteHead() == nil)
        #expect(try await f.remoteHead("refs/tags/unrequested-tag") == nil)
        let branch = try #require(try await f.local.service.branches().first { $0.current })
        #expect(branch.upstreamRef == "refs/remotes/origin/published")
        #expect(branch.ahead == 0 && branch.behind == 0)
    }

    @Test(arguments: [true, false]) func multipleURLsPushToExactlyOneDestination(explicitPushURL: Bool)
        async throws
    {
        let f = try await RemoteFixture.create()
        let second = f.bare.appendingPathExtension("second")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: second)
        }
        _ = try await f.local.engine.run(["init", "--bare", "-b", "main", second.path])
        let key = explicitPushURL ? "remote.origin.pushurl" : "remote.origin.url"
        if explicitPushURL {
            _ = try await f.local.engine.run(["config", "--add", key, f.bare.path], in: f.local.root)
        }
        _ = try await f.local.engine.run(["config", "--add", key, second.path], in: f.local.root)
        try f.local.write("local", "local\n")
        let head = try await f.local.commit()
        let plan = try await f.local.service.preparePush(
            remote: "origin", branch: "main", pushURLIndex: 1, expectedHead: head)
        #expect(plan.remote.pushURLs == [f.bare.path, second.path])
        #expect(plan.expectedRemoteOID == nil)
        _ = try await f.local.service.push(plan)
        #expect(try await f.remoteHead() == f.base)
        #expect(try await f.remoteHead(at: second) == head)
        #expect(try await f.local.service.configValues(key) == [f.bare.path, second.path])
    }

    @Test func urlRewritingUsesTheEffectivePushDestinationForTheLease() async throws {
        let f = try await RemoteFixture.create()
        let second = f.bare.appendingPathExtension("push")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: second)
        }
        _ = try await f.local.engine.run(["init", "--bare", "-b", "main", second.path])
        for (key, value) in [
            ("remote.origin.url", "wegit-fixture:"),
            ("url.\(f.bare.path).insteadOf", "wegit-fixture:"),
            ("url.\(second.path).pushInsteadOf", "wegit-fixture:"),
        ] {
            _ = try await f.local.engine.run(["config", key, value], in: f.local.root)
        }
        let plan = try await f.local.service.preparePush(
            remote: "origin", branch: "main", forceWithLease: true, expectedHead: f.base)
        #expect(plan.remote.fetchURL == f.bare.path)
        #expect(plan.remote.pushURLs == [second.path])
        #expect(plan.expectedRemoteOID == nil)
        _ = try await f.local.service.push(plan)
        #expect(try await f.remoteHead(at: second) == f.base)
    }

    @Test func divergenceRejectsNormalPushAndFetchCannotRefreshAnExistingLease() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        try f.local.write("local", "local\n")
        let head = try await f.local.commit("Local change")
        let lease = try await f.local.service.preparePush(
            remote: "origin", branch: "main", forceWithLease: true, expectedHead: head)
        #expect(lease.expectedRemoteOID == f.base)
        try f.peer.write("remote", "remote\n")
        let remote = try await f.publishPeer()
        try await f.local.service.fetch(remote: "origin")
        await #expect(throws: GitFailure.self) { _ = try await f.local.service.push(lease) }
        let normal = try await f.local.service.preparePush(
            remote: "origin", branch: "main", expectedHead: head)
        await #expect(throws: GitFailure.self) { _ = try await f.local.service.push(normal) }
        #expect(try await f.remoteHead() == remote)
        let renewed = try await f.local.service.preparePush(
            remote: "origin", branch: "main", forceWithLease: true, expectedHead: head)
        #expect(renewed.expectedRemoteOID == remote)
        _ = try await f.local.service.push(renewed)
        #expect(try await f.remoteHead() == head)
    }

    @Test func missingBranchLeaseProtectsAgainstAConcurrentCreation() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        try f.local.write("local", "local\n")
        let head = try await f.local.commit()
        let plan = try await f.local.service.preparePush(
            remote: "origin", branch: "topic", forceWithLease: true, expectedHead: head)
        #expect(plan.expectedRemoteOID == nil)
        _ = try await f.peer.engine.run(["push", "origin", "HEAD:refs/heads/topic"], in: f.peer.root)
        await #expect(throws: GitFailure.self) { _ = try await f.local.service.push(plan) }
        #expect(try await f.remoteHead("refs/heads/topic") == f.base)
    }

    @Test func movedBranchAndChangedRemoteConfigurationInvalidatePushPlans() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        let plan = try await f.local.service.preparePush(
            remote: "origin", branch: "main", expectedHead: f.base)
        _ = try await f.local.engine.run(["switch", "-c", "other"], in: f.local.root)
        await #expect(throws: ModelFailure.self) { _ = try await f.local.service.push(plan) }
        _ = try await f.local.engine.run(["switch", "main"], in: f.local.root)
        _ = try await f.local.engine.run(
            ["config", "--add", "remote.origin.pushurl", f.peer.root.path], in: f.local.root)
        await #expect(throws: ModelFailure.self) { _ = try await f.local.service.push(plan) }
        #expect(try await f.remoteHead() == f.base)
    }

    @Test func firstPushRespectsCustomTrackingMappings() async throws {
        let f = try await RemoteFixture.create(published: false)
        defer { f.remove() }
        _ = try await f.local.engine.run(
            ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/custom/*"], in: f.local.root)
        let plan = try await f.local.service.preparePush(
            remote: "origin", branch: "topic", setUpstream: true, expectedHead: f.base)
        let result = try await f.local.service.push(plan)
        #expect(result.upstreamConfigured && result.warning == nil)
        #expect(
            try await f.local.service.branches().first { $0.current }?.upstreamRef
                == "refs/remotes/custom/topic")
        #expect(try await f.local.service.configValues("branch.main.remote") == ["origin"])
        #expect(try await f.local.service.configValues("branch.main.merge") == ["refs/heads/topic"])
    }

    @Test func upstreamFailureReportsTheSuccessfulPushWithoutRepeatingIt() async throws {
        let f = try await RemoteFixture.create(published: false)
        defer { f.remove() }
        let runner = RemoteInterference(.upstreamFailure)
        let service = RepositoryService(
            location: f.local.service.location,
            engine: TestGit.engine(runner: runner, environment: f.local.engine.environment))
        let plan = try await service.preparePush(
            remote: "origin", branch: "main", setUpstream: true, expectedHead: f.base)
        let result = try await service.push(plan)
        #expect(!result.upstreamConfigured && result.warning?.contains("推送已完成") == true)
        #expect(try await f.remoteHead() == f.base)
        #expect(await runner.pushes == 1)
    }

    @Test func pullPreferenceShowsItsConfigurationSourceAndRequiresExplicitUnsupportedChoices() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        #expect(try await f.local.service.pullPreference().strategy == .fastForwardOnly)
        _ = try await f.local.engine.run(["config", "pull.rebase", "true"], in: f.local.root)
        #expect(try await f.local.service.pullPreference().strategy == .rebase)
        _ = try await f.local.engine.run(["config", "branch.main.rebase", "false"], in: f.local.root)
        let preference = try await f.local.service.pullPreference()
        #expect(preference.strategy == .merge && preference.source.contains("local"))
        _ = try await f.local.engine.run(["config", "branch.main.rebase", "interactive"], in: f.local.root)
        #expect(try await f.local.service.pullPreference().strategy == nil)
        _ = try await f.local.engine.run(["config", "pull.ff", "only"], in: f.local.root)
        #expect(try await f.local.service.pullPreference().strategy == .fastForwardOnly)
    }

    @Test(arguments: PullStrategy.allCases) func pullAppliesTheChosenPolicy(strategy: PullStrategy)
        async throws
    {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        var localHead = f.base
        if strategy != .fastForwardOnly {
            try f.local.write("local", "local\n")
            localHead = try await f.local.commit("Local change")
            _ = try await f.local.engine.run(["branch", "side", localHead], in: f.local.root)
        }
        // Explicit UI policy wins over unrelated merge/rebase configuration.
        _ = try await f.local.engine.run(["config", "merge.ff", "only"], in: f.local.root)
        _ = try await f.local.engine.run(["config", "rebase.updateRefs", "true"], in: f.local.root)
        try f.peer.write("remote", "remote\n")
        let remoteHead = try await f.publishPeer()
        let plan = try await f.local.service.preparePull(
            remote: "origin", branch: "main", strategy: strategy, expectedHead: localHead)
        let result = try await f.local.service.pull(plan)
        #expect(result.warning == nil)
        #expect(try await f.local.service.status().files.isEmpty)
        #expect(try await f.temporaryRefs().isEmpty)
        let finalHead = try #require(try await f.local.service.head())
        let parents = try await f.local.engine.run(["show", "-s", "--format=%P", "HEAD"], in: f.local.root)
            .text
        switch strategy {
        case .fastForwardOnly: #expect(finalHead == remoteHead)
        case .merge: #expect(parents.removingLastNewline == localHead + " " + remoteHead)
        case .rebase:
            #expect(finalHead != localHead && parents.removingLastNewline == remoteHead)
            #expect(
                try await f.local.engine.run(["rev-parse", "refs/heads/side"], in: f.local.root).text
                    .removingLastNewline == localHead)
        }
    }

    @Test func fastForwardRejectionKeepsTheLocalTipAndCleansTheFetchReference() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        try f.local.write("local", "local\n")
        let head = try await f.local.commit()
        try f.peer.write("remote", "remote\n")
        _ = try await f.publishPeer()
        let plan = try await f.local.service.preparePull(
            remote: "origin", branch: "main", strategy: .fastForwardOnly, expectedHead: head)
        do {
            _ = try await f.local.service.pull(plan)
            Issue.record("A diverged branch must not fast-forward")
        } catch let error as PullFailure {
            #expect(error.fetched)
        }
        #expect(try await f.local.service.head() == head)
        #expect(try await f.local.service.status().sequencer == .none)
        #expect(try await f.temporaryRefs().isEmpty)
    }

    @Test func anotherFetchCannotReplaceTheCommitBeingPulled() async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        _ = try await f.peer.engine.run(["push", "origin", "HEAD:refs/heads/other"], in: f.peer.root)
        try f.peer.write("remote", "remote\n")
        let remoteHead = try await f.publishPeer()
        let runner = RemoteInterference(.fetchHeadRace)
        let service = RepositoryService(
            location: f.local.service.location,
            engine: TestGit.engine(runner: runner, environment: f.local.engine.environment))
        let plan = try await service.preparePull(
            remote: "origin", branch: "main", strategy: .fastForwardOnly, expectedHead: f.base)
        _ = try await service.pull(plan)
        #expect(try await service.head() == remoteHead)
        #expect(
            try await f.local.engine.run(["rev-parse", "FETCH_HEAD"], in: f.local.root).text
                .removingLastNewline == f.base)
        #expect(try await f.temporaryRefs().isEmpty)
    }

    @Test(arguments: [RemoteInterference.Mode.cancelledFetch, .switchBranch])
    fileprivate func failedOrInterruptedFetchCleansOnlyItsOwnRef(mode: RemoteInterference.Mode) async throws {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        try f.peer.write("remote", "remote\n")
        _ = try await f.publishPeer()
        let runner = RemoteInterference(mode)
        let service = RepositoryService(
            location: f.local.service.location,
            engine: TestGit.engine(runner: runner, environment: f.local.engine.environment))
        let plan = try await service.preparePull(
            remote: "origin", branch: "main", strategy: .fastForwardOnly, expectedHead: f.base)
        await #expect(throws: PullFailure.self) { _ = try await service.pull(plan) }
        #expect(try await service.head() == f.base)
        #expect(try await f.temporaryRefs().isEmpty)
    }

    @Test(arguments: [false, true]) func pullRebaseHandlesRepeatedConflictsAndAbort(abort: Bool) async throws
    {
        let f = try await RemoteFixture.create()
        defer { f.remove() }
        try f.local.write("file", "local first\n")
        _ = try await f.local.commit("First local change")
        try f.local.write("second", "local second\n")
        let localHead = try await f.local.commit("Second local change")
        try f.peer.write("file", "remote first\n")
        try f.peer.write("second", "remote second\n")
        let remoteHead = try await f.publishPeer()
        let plan = try await f.local.service.preparePull(
            remote: "origin", branch: "main", strategy: .rebase, expectedHead: localHead)
        await #expect(throws: PullFailure.self) { _ = try await f.local.service.pull(plan) }
        var state = try await f.local.service.status()
        #expect(state.sequencer == .rebase && state.conflicts.map(\.path) == ["file"])
        try f.local.write("file", "resolved first\n")
        try await f.local.service.markResolved(path: "file", expectedHead: state.head)
        await #expect(throws: GitFailure.self) {
            try await f.local.service.sequencer(continueOperation: true, expected: .rebase)
        }
        state = try await f.local.service.status()
        #expect(state.sequencer == .rebase && state.conflicts.map(\.path) == ["second"])
        if abort {
            try await f.local.service.sequencer(continueOperation: false, expected: .rebase)
            #expect(try await f.local.service.head() == localHead)
            #expect(
                try String(contentsOf: f.local.root.appending(path: "file"), encoding: .utf8)
                    == "local first\n")
        } else {
            try f.local.write("second", "resolved second\n")
            try await f.local.service.markResolved(path: "second", expectedHead: state.head)
            try await f.local.service.sequencer(continueOperation: true, expected: .rebase)
            let ancestor = try await f.local.engine.run(["rev-parse", "HEAD~2"], in: f.local.root).text
                .removingLastNewline
            #expect(ancestor == remoteHead)
        }
        state = try await f.local.service.status()
        #expect(state.sequencer == .none && state.branch == "main" && state.files.isEmpty)
        #expect(try await f.temporaryRefs().isEmpty)
    }
}
