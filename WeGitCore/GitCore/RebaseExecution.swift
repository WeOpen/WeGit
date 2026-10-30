import Foundation

extension RepositoryService {
    public func executeRebase(_ plan: RebasePlan) async throws -> RebaseOutcome {
        try await withSharedOperation {
            guard plan.location == location else { throw ModelFailure.changed }
            try await verifyHead(plan.head)
            let fresh = try await rebasePlan(target: plan.target, preserveMerges: plan.preserveMerges)
            guard fresh.branch == plan.branch, fresh.head == plan.head, fresh.target == plan.target,
                fresh.startingPoint == plan.startingPoint, fresh.commits == plan.commits,
                fresh.disposition == plan.disposition, fresh.index == plan.index,
                fresh.writePaths == plan.writePaths, fresh.conflictPaths == plan.conflictPaths,
                fresh.resultTree == plan.resultTree, fresh.publishedCommits == plan.publishedCommits
            else { throw ModelFailure.changed }
            guard plan.hasWork else { return .unchanged }
            let reference = try await protectRebaseOriginal(plan.head)
            try await StashWorktreeGuard.validate(
                paths: plan.writePaths, tracked: rebaseIndexPaths(plan.index), location: location)
            let ready = try await status()
            guard ready.head == plan.head, ready.branch == plan.branch, ready.files.isEmpty,
                ready.sequencer == .none, try await rebaseIndexSnapshot() == plan.index,
                try await freshBranch(plan.target) == plan.target
            else { throw ModelFailure.changed }
            try await verifyHead(plan.head)
            try Task.checkCancellation()
            let arguments =
                [
                    "rebase", "--merge", "--no-autostash", "--no-update-refs", "--no-fork-point",
                    "--reapply-cherry-picks", "--empty=keep", "--keep-empty", "--no-autosquash",
                    "--no-rerere-autoupdate", "--strategy=ort",
                    plan.preserveMerges ? "--rebase-merges=no-rebase-cousins" : "--no-rebase-merges",
                    "--onto", plan.target.oid,
                ] + (plan.startingPoint == nil ? ["--root"] : [plan.target.oid])
            var failure: (any Error)?
            do {
                _ = try await singleCommitEngine.run(
                    arguments, in: location.root, timeout: 120,
                    configuration: rebaseCommandConfiguration)
            } catch { failure = error }
            return try await reconcileRebase(
                original: plan.head, branch: "refs/heads/" + plan.branch, onto: plan.target.oid,
                beforeHead: plan.head, beforeIndex: plan.index, resultTree: plan.resultTree,
                originalReference: reference, originals: plan.commits, abort: false, failure: failure)
        }
    }

    @concurrent
    public func prepareRebaseRecovery(
        _ action: RebaseRecoveryAction, expected: RebaseRecovery
    ) async throws -> RebaseRecoveryPlan {
        try await queue.perform { try await rebaseRecoveryPlan(action, expected: expected) }
    }

    func rebaseRecoveryPlan(
        _ action: RebaseRecoveryAction, expected: RebaseRecovery
    ) async throws -> RebaseRecoveryPlan {
        try location.validateIdentity()
        let state = try await status()
        guard expected.location == location, state.rebaseRecovery == expected else {
            throw ModelFailure.changed
        }
        let restriction = action == .abort ? expected.abortRestriction : expected.continuationRestriction
        if let restriction { throw ModelFailure.unsupported(restriction) }
        if action == .continueOperation {
            guard state.conflicts.isEmpty, !state.files.contains(where: \.unstaged) else {
                throw ModelFailure.unsupported(L10n.text("请先保存并标记所有冲突已解决，处理未暂存改动后继续。"))
            }
        }
        let tracked = try rebaseIndexPaths(expected.index)
        var paths = try await rebaseTreePaths(expected.originalHead)
        paths.formUnion(try await rebaseTreePaths(expected.onto))
        paths.formUnion(try await rebaseTreePaths(expected.head))
        paths.formUnion(tracked)
        let resultTree: String?
        var resetBeforeRetry = false
        if action == .continueOperation {
            if let rescheduled = expected.rescheduledCommit,
                expected.remaining.first == .pick(rescheduled)
            {
                // Git 2.54 keeps the failed pick in todo. The staged result is
                // only accepted when it exactly matches that replay; then the
                // explicit Continue resets and lets Git replay the duplicate.
                let first = expected.remaining[0]
                let generated = try await rebaseReplayPreview(
                    steps: [first], head: expected.head, onto: expected.onto, labels: expected.rewritten)
                let staged = try await rebaseReplayPreview(
                    steps: [], head: expected.head, onto: expected.onto, stagedResolution: true)
                let current = try await singleCommitTree(expected.head, engine: singleCommitEngine)
                if staged.resultTree != current {
                    guard let generatedTree = generated.resultTree, staged.resultTree == generatedTree else {
                        throw ModelFailure.unsupported(
                            L10n.text("此提交已重新排队，暂存区还有额外编辑。请先保存这些内容并在 Terminal 中处理。"))
                    }
                    resetBeforeRetry = true
                }
                paths.formUnion(generated.paths)
                let preview = try await rebaseReplayPreview(
                    steps: expected.remaining, head: expected.head, onto: expected.onto,
                    labels: expected.rewritten, stagedResolution: false)
                paths.formUnion(preview.paths)
                resultTree = preview.resultTree
            } else if let rescheduled = expected.rescheduledCommit {
                // Git 2.56 removes the failed pick from todo and leaves its
                // generated result staged. Verify that exact stage, then
                // preview the remaining todo from the staged result.
                let generated = try await rebaseReplayPreview(
                    steps: [.pick(rescheduled)], head: expected.head, onto: expected.onto,
                    labels: expected.rewritten)
                let staged = try await rebaseReplayPreview(
                    steps: [], head: expected.head, onto: expected.onto, stagedResolution: true)
                guard staged.resultTree == generated.resultTree else {
                    throw ModelFailure.unsupported(
                        L10n.text("此提交已重新排队，暂存区还有额外编辑。请先保存这些内容并在 Terminal 中处理。"))
                }
                paths.formUnion(generated.paths)
                let preview = try await rebaseReplayPreview(
                    steps: expected.remaining, head: expected.head, onto: expected.onto,
                    labels: expected.rewritten, stagedResolution: true)
                paths.formUnion(preview.paths)
                resultTree = preview.resultTree
            } else {
                let preview = try await rebaseReplayPreview(
                    steps: expected.remaining, head: expected.head, onto: expected.onto,
                    labels: expected.rewritten, stagedResolution: true)
                paths.formUnion(preview.paths)
                resultTree = preview.resultTree
            }
        } else {
            resultTree = try await singleCommitTree(expected.originalHead, engine: singleCommitEngine)
        }
        guard paths.count <= RebaseBudget.entries else { throw RebaseBudget.exceeded }
        try await StashWorktreeGuard.validate(paths: paths, tracked: tracked, location: location)
        let fresh = try await status()
        guard fresh.files == state.files, fresh.rebaseRecovery == expected else {
            throw ModelFailure.changed
        }
        return RebaseRecoveryPlan(
            action: action, recovery: expected, writePaths: paths, files: state.files, resultTree: resultTree,
            resetBeforeRetry: resetBeforeRetry)
    }

    public func executeRebaseRecovery(_ plan: RebaseRecoveryPlan) async throws -> RebaseOutcome {
        try await withSharedOperation {
            let expected = plan.recovery
            let fresh = try await rebaseRecoveryPlan(plan.action, expected: expected)
            guard fresh.writePaths == plan.writePaths, fresh.files == plan.files,
                fresh.resultTree == plan.resultTree, fresh.resetBeforeRetry == plan.resetBeforeRetry
            else { throw ModelFailure.changed }
            let reference = try await protectRebaseOriginal(expected.originalHead)
            try await StashWorktreeGuard.validate(
                paths: plan.writePaths, tracked: rebaseIndexPaths(expected.index), location: location)
            let ready = try await status()
            guard ready.files == plan.files, ready.rebaseRecovery == expected else {
                throw ModelFailure.changed
            }
            try await verifyHead(expected.head)
            try Task.checkCancellation()
            let originals = plan.action == .abort ? [] : try await rebaseCommits(expected.originals)
            var failure: (any Error)?
            do {
                if plan.resetBeforeRetry {
                    // A failed commit can be both in done and rescheduled in
                    // todo. Only the exact generated stage is eligible for
                    // reset-and-replay, after this explicit Continue action.
                    _ = try await singleCommitEngine.run(
                        ["reset", "--hard", expected.head], in: location.root)
                    let reset = try await status()
                    guard let recovery = reset.rebaseRecovery, reset.head == expected.head,
                        reset.files.allSatisfy(\.untracked), recovery.files == expected.files,
                        recovery.directoryIdentity == expected.directoryIdentity,
                        recovery.rewritten == expected.rewritten,
                        recovery.originalHead == expected.originalHead, recovery.onto == expected.onto,
                        recovery.branchRef == expected.branchRef
                    else { throw ModelFailure.changed }
                }
                _ = try await singleCommitEngine.run(
                    ["rebase", plan.action == .abort ? "--abort" : "--continue"],
                    in: location.root, timeout: 120, configuration: rebaseCommandConfiguration)
            } catch { failure = error }
            return try await reconcileRebase(
                original: expected.originalHead, branch: expected.branchRef, onto: expected.onto,
                beforeHead: expected.head, beforeIndex: expected.index, resultTree: plan.resultTree,
                originalReference: reference,
                originals: originals,
                abort: plan.action == .abort, failure: failure)
        }
    }

    public func recoverRebase(
        continueOperation: Bool, expected: RebaseRecovery
    ) async throws -> RebaseOutcome {
        let plan = try await prepareRebaseRecovery(
            continueOperation ? .continueOperation : .abort, expected: expected)
        return try await executeRebaseRecovery(plan)
    }

    var rebaseCommandConfiguration: [(key: String, value: String)] {
        [
            ("rebase.updateRefs", "false"), ("rebase.autoStash", "false"), ("rebase.autoSquash", "false"),
            ("rebase.rescheduleFailedExec", "false"), ("rebase.abbreviateCommands", "false"),
            ("rebase.instructionFormat", "%s"),
        ]
    }

    /// A deterministic worktree-scoped ref makes the original reachable after
    /// relaunch, cancellation, successful rewriting, or loss of Git's ORIG_HEAD.
    /// An existing matching ref is reused; a conflicting ref is never overwritten.
    func protectRebaseOriginal(_ original: String) async throws -> String {
        guard GitObjectID.valid(original) else { throw ModelFailure.changed }
        let ref = "refs/wegit/rebase/" + location.persistenceID + "/" + original
        let existing = try await singleCommitEngine.run(
            ["rev-parse", "--verify", ref], in: location.root, accepted: [0, 128])
        if existing.exitCode == 0 {
            guard existing.text.removingLastNewline == original else { throw ModelFailure.changed }
            return ref
        }
        var failure: (any Error)?
        do {
            _ = try await singleCommitEngine.run(
                [
                    "update-ref", "--create-reflog", "-m", "WeGit rebase original HEAD", ref, original,
                    String(repeating: "0", count: original.count),
                ], in: location.root)
        } catch { failure = error }
        let observed = await Task.detached {
            try? await singleCommitEngine.run(["rev-parse", "--verify", ref], in: location.root).text
                .removingLastNewline
        }.value
        guard observed == original else {
            if let failure { throw failure }
            throw ModelFailure.changed
        }
        return ref
    }

    private struct RebaseObservation: Sendable {
        let status: RepositoryStatus
        let recovery: RebaseRecovery?
        let index: Data
        let tree: String?
        let branchObject: String?
        let containsTarget: Bool
        let matchesOriginals: Bool
    }

    private func reconcileRebase(
        original: String, branch: String, onto: String, beforeHead: String, beforeIndex: Data,
        resultTree: String?, originalReference: String, originals: [GitCommit],
        abort: Bool, failure: (any Error)?
    ) async throws -> RebaseOutcome {
        let observed = await Task.detached { () -> RebaseObservation? in
            do {
                let state = try await status()
                let recovery = state.rebaseRecovery
                let index = try await rebaseIndexSnapshot()
                let tree: String?
                if let head = state.head {
                    tree = try await singleCommitTree(head, engine: singleCommitEngine)
                } else {
                    tree = nil
                }
                let branchResult = try await singleCommitEngine.run(
                    ["rev-parse", "--verify", branch], in: location.root, accepted: [0, 128])
                let related: Bool
                let matches: Bool
                if let head = state.head {
                    related =
                        try await singleCommitEngine.run(
                            ["merge-base", "--is-ancestor", onto, head], in: location.root, accepted: [0, 1]
                        ).exitCode == 0
                    matches =
                        state.sequencer == .none && !abort
                        ? try await rebaseMatchesOriginals(originals, head: head, onto: onto) : false
                } else {
                    related = false
                    matches = false
                }
                guard try await self.head() == state.head else { return nil }
                return RebaseObservation(
                    status: state, recovery: recovery, index: index, tree: tree,
                    branchObject: branchResult.exitCode == 0 ? branchResult.text.removingLastNewline : nil,
                    containsTarget: related, matchesOriginals: matches)
            } catch { return nil }
        }.value
        let details = failure.map { ($0 as? GitFailure)?.details ?? $0.localizedDescription } ?? ""
        func unknown() -> RebaseOutcomeUnknown {
            RebaseOutcomeUnknown(
                previousHead: original, observedHead: observed?.status.head, details: details,
                originalReference: originalReference)
        }
        guard let observed else { throw unknown() }
        if let recovery = observed.recovery,
            recovery.originalHead == original, recovery.branchRef == branch, recovery.onto == onto,
            observed.branchObject == original
        {
            if !observed.status.conflicts.isEmpty {
                return .conflicts(recovery, observed.status.conflicts.count)
            }
            return .paused(recovery, details)
        }
        let branchName = String(branch.dropFirst("refs/heads/".count))
        if observed.status.sequencer == .none, observed.status.branch == branchName,
            observed.branchObject == observed.status.head, observed.tree == resultTree,
            let head = observed.status.head
        {
            if abort, head == original, observed.status.files.allSatisfy(\.untracked) {
                return .aborted(head)
            }
            if !abort, observed.containsTarget, observed.matchesOriginals, observed.status.files.isEmpty {
                return .completed(head)
            }
        }
        if let failure, observed.status.head == beforeHead, observed.status.branch == branchName,
            observed.status.sequencer == .none, observed.status.files.isEmpty, observed.index == beforeIndex
        {
            throw failure
        }
        throw unknown()
    }

    private struct RebaseCommitIdentity: Hashable {
        let message: String
        let author: String
        let email: String
        let date: Date
    }

    private func rebaseMatchesOriginals(_ originals: [GitCommit], head: String, onto: String) async throws
        -> Bool
    {
        guard !originals.isEmpty else { return head == onto }
        let ids = try rebaseObjectIDs(
            await singleCommitEngine.run(
                [
                    "rev-list", "--max-count=\(originals.count + 1)", "--reverse", "--topo-order",
                    onto + ".." + head, "--",
                ],
                in: location.root, outputLimit: RebaseBudget.metadataBytes
            ).stdout)
        guard ids.count == originals.count else { return false }
        func identities(_ commits: [GitCommit]) -> [RebaseCommitIdentity: Int] {
            var result: [RebaseCommitIdentity: Int] = [:]
            for commit in commits {
                result[
                    RebaseCommitIdentity(
                        message: commit.message, author: commit.author,
                        email: commit.authorEmail, date: commit.date), default: 0] += 1
            }
            return result
        }
        let actual = try await rebaseCommits(ids)
        return identities(actual) == identities(originals)
    }
}
