import Darwin
import Foundation
import WeGitCore

struct LostRebaseReceipt: ProcessRunning {
    let externalCommit: Bool
    let base = ProcessRunner()
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await base.run(request)
        if request.arguments.contains("rebase"), request.arguments.contains("--merge"), result.exitCode == 0 {
            if externalCommit {
                let engine = GitEngine(
                    executable: request.executable, runner: base, environment: request.environment)
                _ = try await engine.run(
                    ["commit", "--allow-empty", "-m", "External commit after completion"],
                    in: request.directory)
            }
            throw ProcessFailure.timedOut
        }
        return result
    }
}

@main struct RebaseChecks {
    enum Failure: Error { case assertion(String) }
    static var checks = 0
    static func require(_ value: Bool, _ text: String) throws {
        guard value else { throw Failure.assertion(text) }
        checks += 1
        print("PASS: " + text)
    }

    static func rebaseStateSnapshot(_ root: URL) throws -> [String: Data] {
        let git = root.appending(path: ".git")
        var result: [String: Data] = [:]
        func capture(_ url: URL, relative: String) throws {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isDirectory == true {
                result[relative] = Data("directory".utf8)
                for case let child as URL in FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])!
                {
                    let path = String(child.path.dropFirst(git.path.count + 1))
                    let childValues = try child.resourceValues(
                        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                    if childValues.isDirectory == true {
                        result[path] = Data("directory".utf8)
                    } else if childValues.isSymbolicLink == true {
                        result[path] = Data(
                            ("symlink:"
                                + (try FileManager.default.destinationOfSymbolicLink(
                                    atPath: child.path)))
                                .utf8)
                    } else if childValues.isRegularFile == true {
                        result[path] = Data("file:".utf8) + (try Data(contentsOf: child))
                    }
                }
            } else if values.isSymbolicLink == true {
                result[relative] = Data(
                    ("symlink:"
                        + (try FileManager.default.destinationOfSymbolicLink(
                            atPath: url.path)))
                        .utf8)
            } else if values.isRegularFile == true {
                result[relative] = Data("file:".utf8) + (try Data(contentsOf: url))
            }
        }
        for name in ["HEAD", "index", "packed-refs", "refs", "rebase-merge"] {
            let url = git.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { try capture(url, relative: name) }
        }
        return result
    }

    static func main() async {
        do { try await run() } catch {
            let details = (error as? GitFailure)?.details ?? String(describing: error)
            FileHandle.standardError.write(
                Data(("Rebase check failed after \(checks) assertions: " + details + "\n").utf8))
            if let output = CommandLine.arguments.dropFirst().first {
                let report: [String: Any] = ["checks": checks, "passed": false, "error": details]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: output), options: .atomic)
            }
            exit(1)
        }
    }

    static func run() async throws {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let engine = GitEngine(
            executable: URL(fileURLWithPath: environment["WEGIT_TEST_GIT"] ?? "/usr/bin/git"),
            environment: environment)
        let parent = FileManager.default.temporaryDirectory.appending(path: "WeGitRebaseChecks-\(UUID())")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var finished = false
        defer {
            if finished {
                try? FileManager.default.removeItem(at: parent)
            } else {
                print("Rebase fixture retained: " + parent.path)
            }
        }
        func fixture(_ name: String, conflict: Bool) async throws -> (RepositoryService, String, String) {
            let root = parent.appending(path: name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            @discardableResult func git(_ args: [String]) async throws -> Data {
                try await engine.run(args, in: root).stdout
            }
            try await git(["init", "-b", "main"])
            for (key, value) in [
                ("user.name", "Rebase Checks"), ("user.email", "fixture@example.invalid"),
                ("commit.gpgsign", "false"), ("core.hooksPath", parent.appending(path: "no-hooks").path),
            ] { try await git(["config", key, value]) }
            try Data("base\n".utf8).write(to: root.appending(path: "file"))
            try Data("target\n".utf8).write(to: root.appending(path: ".gitignore"))
            try await git(["add", "."])
            try await git(["commit", "-m", "Base"])
            let base = String(decoding: try await git(["rev-parse", "HEAD"]), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            try await git(["switch", "-c", "feature"])
            try Data("feature\n".utf8).write(to: root.appending(path: conflict ? "file" : "feature"))
            try await git(["add", "."])
            try await git(["commit", "-m", "Feature"])
            let original = String(decoding: try await git(["rev-parse", "HEAD"]), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            try await git(["switch", "main"])
            try Data("target bytes\n".utf8).write(to: root.appending(path: conflict ? "file" : "target"))
            try await git(["add", "-f", conflict ? "file" : "target"])
            try await git(["commit", "-m", "Target"])
            try await git(["switch", "feature"])
            let location = try await RepositoryService.discover(root, engine: engine)
            return (RepositoryService(location: location, engine: engine), base, original)
        }

        let (service, base, original) = try await fixture("preview", conflict: false)
        let target = try await service.branches().first { $0.name == "main" }!
        let indexPath = service.location.gitDirectory.appending(path: "index")
        let index = try Data(contentsOf: indexPath)
        let plan = try await service.prepareRebase(target: target)
        try require(
            plan.head == original && plan.startingPoint == base, "Preview pins original HEAD and base")
        try require(
            plan.target == target && plan.commits.map(\.id) == [original],
            "Preview orders fixed commit objects")
        try require(plan.disposition == .replay && plan.hasWork, "Divergence requires replay")
        try require(
            try await service.head() == original && Data(contentsOf: indexPath) == index,
            "Preview preserves HEAD/index")
        let ignored = service.location.root.appending(path: "target")
        let privateBytes = Data("private ignored bytes\n".utf8)
        try privateBytes.write(to: ignored)
        do {
            _ = try await service.prepareRebase(target: target)
            throw Failure.assertion("Ignored collision accepted")
        } catch is ModelFailure {}
        try require(
            try Data(contentsOf: ignored) == privateBytes,
            "Ignored target collision is refused without overwrite")
        try FileManager.default.removeItem(at: ignored)
        let applied = try await service.executeRebase(plan)
        guard case .completed(let appliedHead) = applied else {
            throw Failure.assertion("Rebase did not complete")
        }
        let appliedCommit = try await service.readCommit(appliedHead)
        try require(
            appliedHead != original && appliedCommit.parents == [target.oid],
            "Actual rebase rewrites the feature commit onto the pinned target")
        let appliedStatus = try await service.status()
        try require(
            appliedStatus.branch == "feature" && appliedStatus.files.isEmpty
                && appliedStatus.sequencer == .none,
            "Completed rebase restores the named clean branch")
        try require(
            try Data(contentsOf: service.location.root.appending(path: "feature")) == Data("feature\n".utf8)
                && Data(contentsOf: ignored) == Data("target bytes\n".utf8),
            "Actual result retains both sides' independent files")
        let originalRefs = try await engine.run(
            ["for-each-ref", "--format=%(objectname)", "refs/wegit/rebase/"], in: service.location.root
        ).text
        try require(
            originalRefs.trimmingCharacters(in: .newlines) == original,
            "Original commit remains reachable through a durable local ref")
        let contained = try await service.prepareRebase(target: target)
        guard case .unchanged = try await service.executeRebase(contained) else {
            throw Failure.assertion("Contained target wrote history")
        }
        let unchangedHead = try await service.head()
        try require(
            contained.disposition == .upToDate && unchangedHead == appliedHead,
            "Contained target reports no work and preserves the actual HEAD")

        let (fastForward, ffBase, _) = try await fixture("fast-forward", conflict: false)
        _ = try await engine.run(["reset", "--hard", ffBase], in: fastForward.location.root)
        let ffTarget = try await fastForward.branches().first { $0.name == "main" }!
        let ffPlan = try await fastForward.prepareRebase(target: ffTarget)
        guard case .completed(let ffHead) = try await fastForward.executeRebase(ffPlan) else {
            throw Failure.assertion("Fast-forward failed")
        }
        try require(
            ffPlan.disposition == .fastForward && ffPlan.commits.isEmpty && ffHead == ffTarget.oid,
            "Fast-forward uses the exact target without inventing replay commits")

        let (stale, staleBase, staleHead) = try await fixture("stale-target", conflict: false)
        let staleTarget = try await stale.branches().first { $0.name == "main" }!
        let stalePlan = try await stale.prepareRebase(target: staleTarget)
        let staleIndex = try Data(contentsOf: stale.location.gitDirectory.appending(path: "index"))
        _ = try await engine.run(
            ["update-ref", "refs/heads/main", staleBase, staleTarget.oid], in: stale.location.root)
        do {
            _ = try await stale.executeRebase(stalePlan)
            throw Failure.assertion("Moved target accepted")
        } catch is ModelFailure {}
        try require(
            try await stale.head() == staleHead
                && Data(contentsOf: stale.location.gitDirectory.appending(path: "index")) == staleIndex,
            "A moved target rejects confirmation without changing HEAD/index")

        let (hookFailure, _, hookHead) = try await fixture("hook-failure", conflict: false)
        let hooks = parent.appending(path: "hook-failure-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
        let hook = hooks.appending(path: "pre-rebase")
        try Data("#!/bin/sh\nexit 42\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try await engine.run(["config", "core.hooksPath", hooks.path], in: hookFailure.location.root)
        let hookTarget = try await hookFailure.branches().first { $0.name == "main" }!
        let hookPlan = try await hookFailure.prepareRebase(target: hookTarget)
        do {
            _ = try await hookFailure.executeRebase(hookPlan)
            throw Failure.assertion("Hook was bypassed")
        } catch is GitFailure {}
        let hookStatus = try await hookFailure.status()
        try require(
            hookStatus.head == hookHead && hookStatus.sequencer == .none,
            "A real pre-rebase hook failure remains unchanged and is reported")

        let (rounds, _, _) = try await fixture("two-rounds", conflict: true)
        try Data("feature second\n".utf8).write(to: rounds.location.root.appending(path: "second"))
        _ = try await engine.run(["add", "second"], in: rounds.location.root)
        _ = try await engine.run(["commit", "-m", "Second feature"], in: rounds.location.root)
        let roundsOriginal = try await rounds.head()!
        _ = try await engine.run(["branch", "unrelated", roundsOriginal], in: rounds.location.root)
        _ = try await engine.run(["config", "rebase.updateRefs", "true"], in: rounds.location.root)
        _ = try await engine.run(["switch", "main"], in: rounds.location.root)
        try Data("target second\n".utf8).write(to: rounds.location.root.appending(path: "second"))
        _ = try await engine.run(["add", "second"], in: rounds.location.root)
        _ = try await engine.run(["commit", "-m", "Second target"], in: rounds.location.root)
        _ = try await engine.run(["switch", "feature"], in: rounds.location.root)
        let roundsTarget = try await rounds.branches().first { $0.name == "main" }!
        let roundsPlan = try await rounds.prepareRebase(target: roundsTarget)
        try require(
            roundsPlan.commits.count == 2 && roundsPlan.conflictPaths == ["file"],
            "Preview lists the full fixed range and the next actual conflict")
        guard case .conflicts(let firstRecovery, 1) = try await rounds.executeRebase(roundsPlan) else {
            throw Failure.assertion("First conflict missing")
        }
        try require(
            firstRecovery.originalHead == roundsOriginal && firstRecovery.onto == roundsTarget.oid,
            "Started sequence identifies the original branch tip and immutable onto")
        try Data("resolved first\n".utf8).write(to: rounds.location.root.appending(path: "file"))
        try await rounds.markResolved(path: "file", expectedHead: firstRecovery.head)
        let readyFirst = try await rounds.rebaseRecovery()!
        let beforeRecoveryPreview = try Data(
            contentsOf: rounds.location.gitDirectory.appending(path: "index"))
        let firstContinue = try await rounds.prepareRebaseRecovery(.continueOperation, expected: readyFirst)
        try require(
            try Data(contentsOf: rounds.location.gitDirectory.appending(path: "index"))
                == beforeRecoveryPreview,
            "Continue preview keeps every original index byte unchanged")
        guard case .conflicts(let secondRecovery, 1) = try await rounds.executeRebaseRecovery(firstContinue)
        else { throw Failure.assertion("Second conflict missing") }
        try require(
            secondRecovery.head != firstRecovery.head && secondRecovery.originalHead == roundsOriginal,
            "Continue commits the first resolution and recovers the second conflict")
        try Data("resolved second\n".utf8).write(to: rounds.location.root.appending(path: "second"))
        try await rounds.markResolved(path: "second", expectedHead: secondRecovery.head)
        let reopened = RepositoryService(
            location: try await RepositoryService.discover(rounds.location.root, engine: engine),
            engine: engine)
        let reopenedRecovery = try await reopened.rebaseRecovery()!
        guard
            case .completed(let finalRoundHead) = try await reopened.recoverRebase(
                continueOperation: true, expected: reopenedRecovery)
        else {
            throw Failure.assertion("Reopened sequence did not finish")
        }
        try require(
            (try await reopened.status()).branch == "feature" && finalRoundHead != roundsOriginal,
            "A newly opened service finishes the actual recovered sequence")
        try require(
            try Data(contentsOf: rounds.location.root.appending(path: "file"))
                == Data("resolved first\n".utf8)
                && Data(contentsOf: rounds.location.root.appending(path: "second"))
                    == Data("resolved second\n".utf8),
            "Repeated conflict resolutions survive the final tree")
        let unrelated = try await engine.run(["rev-parse", "refs/heads/unrelated"], in: rounds.location.root)
            .text
        try require(
            unrelated.trimmingCharacters(in: .newlines) == roundsOriginal,
            "Explicit no-update-refs preserves other branches despite repository configuration")

        let (conflict, _, oldHead) = try await fixture("recovery", conflict: true)
        let onto = try await conflict.branches().first { $0.name == "main" }!
        let failed = try await engine.run(
            ["rebase", "--no-autostash", "--no-update-refs", "--no-rebase-merges", onto.oid],
            in: conflict.location.root, accepted: [0, 1])
        try require(failed.exitCode == 1, "Real Git fixture reaches a conflict")
        let recovery = try await conflict.rebaseRecovery()
        try require(
            recovery?.originalHead == oldHead && recovery?.onto == onto.oid,
            "Recovery pins original and onto objects")
        try require(
            recovery?.branchRef == "refs/heads/feature" && recovery?.stoppedCommit == oldHead,
            "Recovery identifies branch and stopped commit")
        let todo = conflict.location.gitDirectory.appending(path: "rebase-merge/git-rebase-todo")
        var bytes = try Data(contentsOf: todo)
        bytes.append(Data("\n# external edit\n".utf8))
        try bytes.write(to: todo)
        let changed = try await conflict.rebaseRecovery()
        try require(changed != recovery, "External todo edit changes the action fingerprint")
        do {
            _ = try await conflict.prepareRebaseRecovery(.abort, expected: recovery!)
            throw Failure.assertion("Edited sequence accepted old confirmation")
        } catch is ModelFailure {}
        try require(try await conflict.head() == recovery?.head, "Stale recovery confirmation refuses writes")
        guard
            case .aborted(let abortedHead) = try await conflict.recoverRebase(
                continueOperation: false, expected: changed!)
        else {
            throw Failure.assertion("Abort did not restore original branch")
        }
        let abortedStatus = try await conflict.status()
        try require(
            abortedHead == oldHead && abortedStatus.branch == "feature",
            "Confirmed abort of an externally started sequence restores the original HEAD/branch")
        try require(
            try Data(contentsOf: conflict.location.root.appending(path: "file")) == Data("feature\n".utf8),
            "Abort restores original tracked bytes")

        let (signedConflict, _, signedConflictOriginal) = try await fixture(
            "signed-conflict", conflict: true)
        _ = try await engine.run(["config", "commit.gpgsign", "true"], in: signedConflict.location.root)
        _ = try await engine.run(
            ["config", "gpg.program", "/usr/bin/false"], in: signedConflict.location.root)
        let signedConflictTarget = try await signedConflict.branches().first { $0.name == "main" }!
        guard
            case .conflicts = try await signedConflict.executeRebase(
                signedConflict.prepareRebase(target: signedConflictTarget))
        else {
            throw Failure.assertion("Signed rebase fixture did not stop at its ordinary conflict")
        }
        let signedConflictRecovery = try await signedConflict.rebaseRecovery()!
        try require(
            signedConflictRecovery.rescheduledCommit == nil
                && signedConflictRecovery.stoppedCommit == signedConflictOriginal,
            "A signed conflict is not confused with a failed signed commit")
        try Data("resolved signed conflict\n".utf8)
            .write(to: signedConflict.location.root.appending(path: "file"))
        try await signedConflict.markResolved(path: "file", expectedHead: signedConflictRecovery.head)
        let resolvedSignedConflict = try await signedConflict.rebaseRecovery()!
        let conflictReady = try await signedConflict.prepareRebaseRecovery(
            .continueOperation, expected: resolvedSignedConflict)
        let signingKey = parent.appending(path: "private-conflict-signing-key")
        _ = try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                arguments: ["-q", "-t", "ed25519", "-N", "", "-f", signingKey.path], environment: environment)
        )
        _ = try await engine.run(["config", "gpg.format", "ssh"], in: signedConflict.location.root)
        _ = try await engine.run(
            ["config", "user.signingkey", signingKey.path], in: signedConflict.location.root)
        guard case .completed = try await signedConflict.executeRebaseRecovery(conflictReady) else {
            throw Failure.assertion("Signed conflict could not continue after its resolution")
        }
        let signedConflictStatus = try await signedConflict.status()
        try require(
            signedConflictStatus.conflicts.isEmpty && signedConflictStatus.sequencer == .none,
            "A signed conflict keeps the ordinary resolved-conflict Continue path")

        let (signing, _, _) = try await fixture("signing-failure", conflict: false)
        try Data("later feature\n".utf8).write(to: signing.location.root.appending(path: "later"))
        _ = try await engine.run(["add", "later"], in: signing.location.root)
        _ = try await engine.run(["commit", "-m", "Later Feature"], in: signing.location.root)
        let signingOriginal = try await signing.head()!
        let signingFirstCommit = try await engine.run(["rev-parse", "HEAD~1"], in: signing.location.root)
            .text.trimmingCharacters(in: .newlines)
        _ = try await engine.run(["config", "commit.gpgsign", "true"], in: signing.location.root)
        _ = try await engine.run(["config", "gpg.program", "/usr/bin/false"], in: signing.location.root)
        let signingTarget = try await signing.branches().first { $0.name == "main" }!
        let signingPlan = try await signing.prepareRebase(target: signingTarget)
        guard
            case .paused(let signingRecovery, let signingDetails) = try await signing.executeRebase(
                signingPlan)
        else {
            throw Failure.assertion("Signing failure lost its sequence")
        }
        try require(
            signingRecovery.originalHead == signingOriginal && !signingDetails.isEmpty,
            "A real signing failure reports a recoverable pause and retains original HEAD")
        try require(
            signingRecovery.rescheduledCommit == signingFirstCommit
                && signingRecovery.remainingSteps == 2,
            "A signing failure identifies the failed commit across Git rebase metadata layouts")
        let rebaseSigningKey = parent.appending(path: "private-rebase-signing-key")
        let manualBytes = Data("feature with manual edits\n".utf8)
        try manualBytes.write(to: signing.location.root.appending(path: "feature"))
        try await signing.markResolved(path: "feature", expectedHead: signingRecovery.head)
        let protected = try rebaseStateSnapshot(signing.location.root)
        let editedIndex = try Data(contentsOf: signing.location.gitDirectory.appending(path: "index"))
        let manualRecovery = try await signing.rebaseRecovery()!
        do {
            _ = try await signing.prepareRebaseRecovery(.continueOperation, expected: manualRecovery)
            throw Failure.assertion("Manual edits after a failed signing attempt were accepted")
        } catch is ModelFailure {}
        try require(
            try Data(contentsOf: signing.location.root.appending(path: "feature")) == manualBytes
                && Data(contentsOf: signing.location.gitDirectory.appending(path: "index")) == editedIndex
                && rebaseStateSnapshot(signing.location.root) == protected,
            "A signing retry refuses extra edits without changing files, index, refs or rebase metadata")
        try Data("feature\n".utf8).write(to: signing.location.root.appending(path: "feature"))
        try await signing.markResolved(path: "feature", expectedHead: signingRecovery.head)
        _ = try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                arguments: ["-q", "-t", "ed25519", "-N", "", "-f", rebaseSigningKey.path],
                environment: environment)
        )
        _ = try await engine.run(["config", "gpg.format", "ssh"], in: signing.location.root)
        _ = try await engine.run(
            ["config", "user.signingkey", rebaseSigningKey.path], in: signing.location.root)
        let repairedSigning = try await signing.rebaseRecovery()!
        guard
            case .completed = try await signing.recoverRebase(
                continueOperation: true, expected: repairedSigning)
        else {
            throw Failure.assertion("Signing failure could not be continued")
        }
        let completedSigningStatus = try await signing.status()
        let rebasedCommitCount = try await engine.run(
            ["rev-list", "--count", "main..HEAD"], in: signing.location.root
        ).text.trimmingCharacters(in: .newlines)
        try require(
            completedSigningStatus.files.isEmpty && rebasedCommitCount == "2",
            "Explicit continuation commits the staged retry and remaining todo after repairing signing")

        for external in [false, true] {
            let (receipt, _, receiptOriginal) = try await fixture(
                external ? "foreign-receipt" : "lost-receipt", conflict: false)
            let receiptEngine = GitEngine(
                executable: engine.executable, runner: LostRebaseReceipt(externalCommit: external),
                environment: environment)
            let uncertain = RepositoryService(location: receipt.location, engine: receiptEngine)
            let receiptTarget = try await uncertain.branches().first { $0.name == "main" }!
            let receiptPlan = try await uncertain.prepareRebase(target: receiptTarget)
            if external {
                do {
                    _ = try await uncertain.executeRebase(receiptPlan)
                    throw Failure.assertion("An extra external commit was attributed to rebase")
                } catch let unknown as RebaseOutcomeUnknown {
                    try require(
                        unknown.previousHead == receiptOriginal && unknown.observedHead != nil
                            && unknown.originalReference != nil,
                        "An extra external commit produces an uncertain result with the original ref")
                }
            } else {
                guard case .completed(let verified) = try await uncertain.executeRebase(receiptPlan) else {
                    throw Failure.assertion("Verified completion with a lost receipt was misreported")
                }
                try require(
                    try await receipt.head() == verified,
                    "Lost receipt is reconciled from the actual complete matching history")
            }
        }

        let (merges, mergeBase, _) = try await fixture("preserve-merges", conflict: false)
        _ = try await engine.run(["switch", "-c", "side", mergeBase], in: merges.location.root)
        try Data("side bytes\n".utf8).write(to: merges.location.root.appending(path: "side"))
        _ = try await engine.run(["add", "side"], in: merges.location.root)
        _ = try await engine.run(["commit", "-m", "Side branch"], in: merges.location.root)
        _ = try await engine.run(["switch", "feature"], in: merges.location.root)
        _ = try await engine.run(
            ["merge", "--no-ff", "-m", "Preserved merge", "side"], in: merges.location.root)
        let mergeTarget = try await merges.branches().first { $0.name == "main" }!
        let mergePlan = try await merges.prepareRebase(target: mergeTarget, preserveMerges: true)
        guard case .completed(let mergedHead) = try await merges.executeRebase(mergePlan) else {
            throw Failure.assertion("Preserve-merges rebase failed")
        }
        let mergedCommit = try await merges.readCommit(mergedHead)
        try require(
            mergedCommit.parents.count == 2 && mergedCommit.subject == "Preserved merge",
            "Supported merge-preserving rebase keeps both actual parent lines and merge message")

        let (legacy, _, _) = try await fixture("legacy-pull-recovery", conflict: true)
        let legacyTarget = try await legacy.branches().first { $0.name == "main" }!
        _ = try await engine.run(
            ["rebase", "--no-autostash", "--no-update-refs", "--no-rebase-merges", legacyTarget.oid],
            in: legacy.location.root, accepted: [0, 1])
        let legacyStatus = try await legacy.status()
        try Data("legacy resolved\n".utf8).write(to: legacy.location.root.appending(path: "file"))
        try await legacy.markResolved(path: "file", expectedHead: legacyStatus.head)
        try await legacy.sequencer(continueOperation: true, expected: .rebase)
        try require(
            (try await legacy.status()).sequencer == .none,
            "Existing externally started Pull Rebase continue remains usable")

        let (slow, _, slowHead) = try await fixture("running-cancel", conflict: false)
        let slowHooks = parent.appending(path: "slow-hooks")
        try FileManager.default.createDirectory(at: slowHooks, withIntermediateDirectories: false)
        let ready = slowHooks.appending(path: "ready")
        let slowHook = slowHooks.appending(path: "pre-rebase")
        let script =
            "#!/bin/sh\ntrap 'exit 143' TERM\n/bin/sleep 10 &\nchild=$!\nprintf '%s %s %s\\n' \"$PPID\" \"$$\" \"$child\" > \"\(ready.path)\"\nwait \"$child\"\n"
        try Data(script.utf8).write(to: slowHook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slowHook.path)
        _ = try await engine.run(["config", "core.hooksPath", slowHooks.path], in: slow.location.root)
        let slowTarget = try await slow.branches().first { $0.name == "main" }!
        let slowPlan = try await slow.prepareRebase(target: slowTarget)
        let operation = Task { try await slow.executeRebase(slowPlan) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pids = try String(contentsOf: ready, encoding: .utf8).split(whereSeparator: \.isWhitespace)
            .compactMap { pid_t($0) }
        try require(
            pids.count == 3 && pids.allSatisfy { kill($0, 0) == 0 },
            "Cancellation begins only after the actual Git, hook and child processes are alive")
        let cancelledAt = Date()
        operation.cancel()
        do {
            _ = try await operation.value
            throw Failure.assertion("Running operation ignored cancellation")
        } catch ProcessFailure.cancelled {} catch is CancellationError {}
        let cancelMilliseconds = Date().timeIntervalSince(cancelledAt) * 1000
        try require(
            cancelMilliseconds < 500,
            "Running cancellation plus actual state reconciliation stays below 500ms")
        let cancelStatus = try await slow.status()
        try require(
            cancelStatus.head == slowHead && cancelStatus.branch == "feature" && cancelStatus.files.isEmpty,
            "Cancelled real pre-rebase hook preserves the original clean branch")
        try require(
            kill(-pids[0], 0) == -1 && errno == ESRCH,
            "Cancelled Git process group is gone before the queue is reused")
        let (authorGuard, _, _) = try await fixture("author-guard", conflict: true)
        let authorTarget = try await authorGuard.branches().first { $0.name == "main" }!
        _ = try await authorGuard.executeRebase(authorGuard.prepareRebase(target: authorTarget))
        let authorScript = authorGuard.location.gitDirectory.appending(path: "rebase-merge/author-script")
        let authorMarker = authorGuard.location.root.appending(path: "unexpected-author-command")
        var authorBytes = try Data(contentsOf: authorScript)
        authorBytes.append(Data(("\n/usr/bin/touch '" + authorMarker.path + "'\n").utf8))
        try authorBytes.write(to: authorScript)
        let guardedStatus = try await authorGuard.status()
        let guardedRecovery = guardedStatus.rebaseRecovery!
        try require(
            !guardedRecovery.canContinue && guardedRecovery.canAbort && guardedStatus.conflicts.count == 1,
            "External author commands restrict Continue without hiding actual conflicts")
        do {
            _ = try await authorGuard.recoverRebase(continueOperation: true, expected: guardedRecovery)
            throw Failure.assertion("External author script executed")
        } catch is ModelFailure {}
        try require(
            !FileManager.default.fileExists(atPath: authorMarker.path),
            "Unverified author script never launches its external command")
        let (driverGuard, _, _) = try await fixture("driver-guard", conflict: true)
        try Data("file merge=probe\n".utf8).write(
            to: driverGuard.location.root.appending(path: ".gitattributes"))
        _ = try await engine.run(["add", ".gitattributes"], in: driverGuard.location.root)
        _ = try await engine.run(["commit", "-m", "Merge attribute"], in: driverGuard.location.root)
        let driver = driverGuard.location.gitDirectory.appending(path: "private-driver")
        let driverMarker = driverGuard.location.root.appending(path: "unexpected-driver-command")
        try Data(("#!/bin/sh\n/usr/bin/touch '" + driverMarker.path + "'\nexit 1\n").utf8).write(to: driver)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: driver.path)
        _ = try await engine.run(
            ["config", "merge.probe.driver", driver.path], in: driverGuard.location.root)
        let driverTarget = try await driverGuard.branches().first { $0.name == "main" }!
        let driverIndex = try Data(contentsOf: driverGuard.location.gitDirectory.appending(path: "index"))
        _ = try await driverGuard.prepareRebase(target: driverTarget)
        try require(
            !FileManager.default.fileExists(atPath: driverMarker.path)
                && (try Data(contentsOf: driverGuard.location.gitDirectory.appending(path: "index")))
                    == driverIndex,
            "Read-only preview does not execute a configured merge driver or change the index")
        let (delta, _, _) = try await fixture("tree-delta", conflict: false)
        try FileManager.default.removeItem(at: delta.location.root.appending(path: "file"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: delta.location.root.appending(path: "feature").path)
        let deltaPath = "中文\n[delta]"
        try Data("new delta bytes\n".utf8).write(to: delta.location.root.appending(path: deltaPath))
        _ = try await engine.run(["add", "-A"], in: delta.location.root)
        _ = try await engine.run(["commit", "-m", "Delete, add and mode"], in: delta.location.root)
        _ = try await engine.run(
            ["commit", "--allow-empty", "-m", "Empty source delta"], in: delta.location.root)
        let deltaTarget = try await delta.branches().first { $0.name == "main" }!
        let deltaPlan = try await delta.prepareRebase(target: deltaTarget)
        try require(
            deltaPlan.commits.count == 3, "Batched source metadata pins an empty commit in the fixed replay")
        guard case .completed = try await delta.executeRebase(deltaPlan) else {
            throw Failure.assertion("Tree delta result did not match actual Git")
        }
        try require(
            !FileManager.default.fileExists(atPath: delta.location.root.appending(path: "file").path)
                && (try Data(contentsOf: delta.location.root.appending(path: deltaPath)))
                    == Data("new delta bytes\n".utf8),
            "Derived tree metadata preserves additions, deletions and literal newline paths")
        let mode =
            try FileManager.default.attributesOfItem(
                atPath: delta.location.root.appending(path: "feature").path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o755, "Derived tree metadata preserves actual executable mode")
        let (blobMetadata, _, _) = try await fixture("shared-blob-metadata", conflict: false)
        let binary = Data([0, 255, 10, 13, 1, 128])
        let copiedPath = "copy\n中文"
        try binary.write(to: blobMetadata.location.root.appending(path: "feature"))
        try binary.write(to: blobMetadata.location.root.appending(path: copiedPath))
        try Data().write(to: blobMetadata.location.root.appending(path: "empty"))
        try FileManager.default.createSymbolicLink(
            atPath: blobMetadata.location.root.appending(path: "link").path, withDestinationPath: "feature")
        _ = try await engine.run(["add", "-A"], in: blobMetadata.location.root)
        _ = try await engine.run(
            ["commit", "-m", "Shared binary, empty and symlink"], in: blobMetadata.location.root)
        let blobTarget = try await blobMetadata.branches().first { $0.name == "main" }!
        let blobIndex = try Data(contentsOf: blobMetadata.location.gitDirectory.appending(path: "index"))
        let blobPlan = try await blobMetadata.prepareRebase(target: blobTarget)
        try require(
            try Data(contentsOf: blobMetadata.location.gitDirectory.appending(path: "index")) == blobIndex,
            "Batched shared blob metadata preparation preserves original index bytes")
        guard case .completed = try await blobMetadata.executeRebase(blobPlan) else {
            throw Failure.assertion("Shared blob metadata replay did not complete")
        }
        try require(
            try Data(contentsOf: blobMetadata.location.root.appending(path: "feature")) == binary
                && Data(contentsOf: blobMetadata.location.root.appending(path: copiedPath)) == binary
                && Data(contentsOf: blobMetadata.location.root.appending(path: "empty")).isEmpty
                && FileManager.default.destinationOfSymbolicLink(
                    atPath: blobMetadata.location.root.appending(path: "link").path) == "feature",
            "Actual replay preserves shared binary blobs, empty files, symlinks and literal newline paths")
        let (missingBlob, _, missingHead) = try await fixture("missing-previously-read-blob", conflict: false)
        let missingTarget = try await missingBlob.branches().first { $0.name == "main" }!
        _ = try await missingBlob.prepareRebase(target: missingTarget)
        let missingID = try await engine.run(
            ["rev-parse", missingHead + ":file"], in: missingBlob.location.root
        )
        .text.trimmingCharacters(in: .newlines)
        let missingPath = missingBlob.location.commonDirectory.appending(path: "objects")
            .appending(path: String(missingID.prefix(2))).appending(path: String(missingID.dropFirst(2)))
        try FileManager.default.removeItem(at: missingPath)
        let missingIndex = try Data(contentsOf: missingBlob.location.gitDirectory.appending(path: "index"))
        do {
            _ = try await missingBlob.prepareRebase(target: missingTarget)
            throw Failure.assertion("Preparation reused stale metadata for a missing blob")
        } catch is ModelFailure {}
        let observedMissingHead = try await missingBlob.head()
        try require(
            observedMissingHead == missingHead
                && (try Data(contentsOf: missingBlob.location.gitDirectory.appending(path: "index")))
                    == missingIndex
                && (try Data(contentsOf: missingBlob.location.root.appending(path: "file")))
                    == Data("base\n".utf8),
            "Fresh preparation rejects a previously read but removed blob without HEAD, index or file writes")
        let (emptyTarget, _, emptyOriginal) = try await fixture("empty-target-tree", conflict: false)
        _ = try await engine.run(["switch", "main"], in: emptyTarget.location.root)
        _ = try await engine.run(["rm", "-r", "--", "."], in: emptyTarget.location.root)
        _ = try await engine.run(["commit", "-m", "Empty target tree"], in: emptyTarget.location.root)
        _ = try await engine.run(["switch", "feature"], in: emptyTarget.location.root)
        let emptyBranch = try await emptyTarget.branches().first { $0.name == "main" }!
        let emptyIndex = try Data(contentsOf: emptyTarget.location.gitDirectory.appending(path: "index"))
        let emptyPlan = try await emptyTarget.prepareRebase(target: emptyBranch)
        try require(
            emptyPlan.head == emptyOriginal && emptyPlan.conflictPaths.isEmpty
                && (try Data(contentsOf: emptyTarget.location.gitDirectory.appending(path: "index")))
                    == emptyIndex,
            "An empty first target tree preserves original HEAD and index during preparation")
        guard case .completed = try await emptyTarget.executeRebase(emptyPlan) else {
            throw Failure.assertion("Empty target addition replay did not complete")
        }
        try require(
            (try Data(contentsOf: emptyTarget.location.root.appending(path: "feature")))
                == Data("feature\n".utf8)
                && !FileManager.default.fileExists(
                    atPath: emptyTarget.location.root.appending(path: "file").path),
            "Actual replay onto an empty target retains the addition and target deletion")
        let (differentFiles, differentBase, _) = try await fixture("disjoint-modifications", conflict: false)
        let differentRoot = differentFiles.location.root
        _ = try await engine.run(["switch", "main"], in: differentRoot)
        _ = try await engine.run(["reset", "--hard", differentBase], in: differentRoot)
        try Data("target only change\n".utf8).write(to: differentRoot.appending(path: "file"))
        _ = try await engine.run(["commit", "-am", "Target modification"], in: differentRoot)
        _ = try await engine.run(["switch", "feature"], in: differentRoot)
        _ = try await engine.run(["reset", "--hard", differentBase], in: differentRoot)
        for text in ["first\n", "second\n", "target\n", "final\n"] {
            try Data(text.utf8).write(to: differentRoot.appending(path: ".gitignore"))
            _ = try await engine.run(["commit", "-am", "Source modification"], in: differentRoot)
        }
        _ = try await engine.run(["commit", "--allow-empty", "-m", "Empty source"], in: differentRoot)
        let differentOriginal = try await differentFiles.head()
        let differentTarget = try await differentFiles.branches().first { $0.name == "main" }!
        let differentIndex = try Data(
            contentsOf: differentFiles.location.gitDirectory.appending(path: "index"))
        let objectFolder = differentFiles.location.commonDirectory.appending(path: "objects").path
        let objectsBefore = (FileManager.default.enumerator(atPath: objectFolder)?.allObjects as? [String])?
            .sorted()
        let differentPlan = try await differentFiles.prepareRebase(target: differentTarget)
        let objectsAfter = (FileManager.default.enumerator(atPath: objectFolder)?.allObjects as? [String])?
            .sorted()
        try require(
            differentPlan.head == differentOriginal && differentPlan.commits.count == 5
                && differentPlan.conflictPaths.isEmpty
                && (try Data(contentsOf: differentFiles.location.gitDirectory.appending(path: "index")))
                    == differentIndex
                && objectsBefore == objectsAfter,
            "Different regular-file modifications preserve source undo, empty commits and all user index/object entries in preview"
        )
        guard case .completed = try await differentFiles.executeRebase(differentPlan) else {
            throw Failure.assertion("Disjoint ordinary-file replay did not complete")
        }
        let differentCount = try await engine.run(
            ["rev-list", "--count", differentTarget.oid + "..HEAD"], in: differentRoot
        ).text.trimmingCharacters(in: .newlines)
        try require(
            differentCount == "5"
                && (try Data(contentsOf: differentRoot.appending(path: ".gitignore"))) == Data("final\n".utf8)
                && (try Data(contentsOf: differentRoot.appending(path: "file")))
                    == Data("target only change\n".utf8),
            "Actual sequential Git replay matches the different-file preview and preserves all five commits")
        let (hiddenConflict, _, _) = try await fixture("earlier-conflict-before-convergence", conflict: true)
        let hiddenRoot = hiddenConflict.location.root
        try Data("target bytes\n".utf8).write(to: hiddenRoot.appending(path: "file"))
        _ = try await engine.run(["commit", "-am", "Later source matches target"], in: hiddenRoot)
        let hiddenOriginal = try await hiddenConflict.head()
        let hiddenTarget = try await hiddenConflict.branches().first { $0.name == "main" }!
        let hiddenPlan = try await hiddenConflict.prepareRebase(target: hiddenTarget)
        try require(
            hiddenPlan.commits.count == 2 && hiddenPlan.conflictPaths == ["file"],
            "A later source matching the target never hides the earlier overlapping conflict")
        guard case .conflicts(let hiddenRecovery, 1) = try await hiddenConflict.executeRebase(hiddenPlan)
        else {
            throw Failure.assertion("Earlier overlapping conflict was incorrectly skipped")
        }
        guard
            case .aborted(let hiddenHead) = try await hiddenConflict.recoverRebase(
                continueOperation: false, expected: hiddenRecovery)
        else {
            throw Failure.assertion("Overlapping conflict abort did not complete")
        }
        try require(
            hiddenHead == hiddenOriginal
                && (try Data(contentsOf: hiddenRoot.appending(path: "file"))) == Data("target bytes\n".utf8),
            "Real first conflict and confirmed abort preserve the later original source contents")
        let report: [String: Any] = [
            "checks": checks, "passed": true,
            "scope":
                "Private actual Git preview/execution/recovery checks; not XCTest or complete Rebase acceptance.",
        ]
        if let output = CommandLine.arguments.dropFirst().first {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        finished = true
        print("\(checks) Rebase real Git checks passed")
    }
}
