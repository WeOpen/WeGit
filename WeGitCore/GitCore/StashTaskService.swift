import Foundation

extension RepositoryService {
    @concurrent public func prepareTaskSwitch(
        to target: GitBranch, message: String, includeUntracked: Bool = false
    ) async throws -> TaskSwitchPlan {
        try await queue.perform {
            guard !message.contains("\0"), message.utf8.count <= 4096 else { throw ModelFailure.invalidPath }
            let index = try SelectedIndexSnapshot.read(location: location)
            let sharedIndex = try await captureRecoverySharedIndex(index)
            let tracked = try await stashIndexFiles()
            let metadata = try await RecoveryFileIO.metadataAll(location: location, paths: tracked.sorted())
            let state = try await status()
            guard let head = state.head, state.sequencer == .none, state.conflicts.isEmpty,
                state.commitQueue?.phase.pending != true
            else {
                throw ModelFailure.unsupported(L10n.text("请先完成当前 Git 操作，再保存任务并切换。"))
            }
            let branch = try await freshBranch(target, localOnly: true)
            guard !branch.current else { throw ModelFailure.changed }
            try ensureNotInOtherWorktree(branch)
            let files = state.files.filter { !$0.untracked || includeUntracked }
            guard !files.isEmpty else { throw ModelFailure.unsupported(L10n.text("没有可保存的任务改动。")) }
            let captures = try await captureRecoveryFiles(
                Array(Set(files.map(\.path))).sorted(),
                limit: RecoveryBudget.bytes - (index.bytes?.count ?? 0) - (sharedIndex?.data.count ?? 0))
            try await RecoveryFileIO.verifyMetadataAll(metadata, location: location)
            try await RecoveryFileIO.verifyAll(captures, location: location)
            guard try SelectedIndexSnapshot.read(location: location) == index else {
                throw ModelFailure.changed
            }
            try await verifyHead(head)
            try await verifyRecoverySharedIndex(sharedIndex)
            return TaskSwitchPlan(
                target: branch, head: head, branch: state.branch, message: message,
                includeUntracked: includeUntracked, files: state.files, location: location, index: index,
                sharedIndex: sharedIndex, metadata: metadata, captures: captures)
        }
    }

    public func executeTaskSwitch(_ plan: TaskSwitchPlan) async throws -> TaskSwitchOutcome {
        try await withSharedOperation {
            guard plan.location == location else { throw ModelFailure.changed }
            try await verifyStashTaskSnapshot(
                head: plan.head, branch: plan.branch, index: plan.index, metadata: plan.metadata,
                captures: plan.captures)
            let target = try await freshBranch(plan.target, localOnly: true)
            try ensureNotInOtherWorktree(target)
            let (store, original) = try await stashTaskBackup(
                operation: "task-save-and-switch", head: plan.head, branch: plan.branch,
                target: target.oid, index: plan.index, sharedIndex: plan.sharedIndex, captures: plan.captures)
            var record = original
            try await verifyRecoverySharedIndex(plan.sharedIndex)
            let stash: GitStash
            do {
                try await verifyStashTaskSnapshot(
                    head: plan.head, branch: plan.branch, index: plan.index, metadata: plan.metadata,
                    captures: plan.captures)
                stash = try await createStashUnderPermit(
                    message: plan.message, includeUntracked: plan.includeUntracked,
                    expectedHead: plan.head, expectedFiles: plan.files)
            } catch {
                record.state = .needsVerification
                record.details = String(Redaction.text(error.localizedDescription).prefix(8192))
                try? store.save(record)
                throw RecoveryOutcomeUnknown(recordID: record.id, details: record.details ?? "")
            }
            do {
                try await switchBranchUnderPermit(target, expectedHead: plan.head)
                let observed = try await recoveryContext()
                guard observed.head == target.oid, observed.branch == target.name else {
                    throw ModelFailure.changed
                }
                record.state = .succeeded
                record.observedHead = observed.head
                record.details = "stash=" + stash.objectID
                try store.save(record)
                return .switched(stash)
            } catch {
                record.state = .needsVerification
                record.details =
                    "stash=" + stash.objectID + "\n"
                    + String(Redaction.text(error.localizedDescription).prefix(8192))
                try? store.save(record)
                return .savedNeedsReview(stash, record.details ?? "")
            }
        }
    }

    @concurrent public func prepareStashBranch(
        _ entry: GitStash, in list: StashList, name: String, dropAfterApply: Bool = false
    ) async throws -> StashBranchPlan {
        try await queue.perform {
            try await validateBranchName(name)
            guard try await branches().allSatisfy({ $0.id != "refs/heads/" + name }) else {
                throw ModelFailure.changed
            }
            let index = try SelectedIndexSnapshot.read(location: location)
            let sharedIndex = try await captureRecoverySharedIndex(index)
            let tracked = try await stashIndexFiles()
            let metadata = try await RecoveryFileIO.metadataAll(location: location, paths: tracked.sorted())
            let state = try await status()
            guard let head = state.head, state.sequencer == .none, state.files.allSatisfy(\.untracked),
                state.commitQueue?.phase.pending != true
            else {
                throw ModelFailure.unsupported(L10n.text("请先保存已跟踪文件的改动，再从储藏创建分支。"))
            }
            try await verifyStashEntry(entry, in: list)
            let contents = try await stashContents(entry, in: list)
            let changed = try await singleCommitEngine.run(
                ["diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", head, contents.base, "--"],
                in: location.root, outputLimit: 32 * 1024 * 1024
            ).stdout
            var paths = Set(try recoveryPaths(changed))
            for target in [contents.working, contents.index] {
                let raw = try await singleCommitEngine.run(
                    [
                        "diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", contents.base,
                        target.id, "--",
                    ],
                    in: location.root, outputLimit: 32 * 1024 * 1024
                ).stdout
                paths.formUnion(try recoveryPaths(raw))
            }
            if let untracked = contents.untracked {
                let raw = try await singleCommitEngine.run(
                    ["ls-tree", "-r", "--name-only", "-z", untracked.id], in: location.root
                ).stdout
                paths.formUnion(try recoveryPaths(raw))
            }
            try await StashWorktreeGuard.validate(paths: paths, tracked: tracked, location: location)
            let captures = try await captureRecoveryFiles(
                paths.sorted(),
                limit: RecoveryBudget.bytes - (index.bytes?.count ?? 0) - (sharedIndex?.data.count ?? 0))
            try await verifyStashTaskSnapshot(
                head: head, branch: state.branch, index: index, metadata: metadata, captures: captures)
            return StashBranchPlan(
                entry: entry, name: name, base: contents.base, head: head, branch: state.branch,
                dropAfterApply: dropAfterApply, files: paths.sorted(), list: list, location: location,
                index: index, sharedIndex: sharedIndex, metadata: metadata, captures: captures)
        }
    }

    public func executeStashBranch(_ plan: StashBranchPlan) async throws -> StashBranchOutcome {
        try await withSharedOperation {
            guard plan.location == location else { throw ModelFailure.changed }
            try await verifyStashTaskSnapshot(
                head: plan.head, branch: plan.branch, index: plan.index, metadata: plan.metadata,
                captures: plan.captures)
            try await verifyStashEntry(plan.entry, in: plan.list)
            let (store, original) = try await stashTaskBackup(
                operation: "stash-create-branch", head: plan.head, branch: plan.branch,
                target: plan.base, index: plan.index, sharedIndex: plan.sharedIndex, captures: plan.captures)
            var record = original
            try await verifyRecoverySharedIndex(plan.sharedIndex)
            do {
                try await verifyStashTaskSnapshot(
                    head: plan.head, branch: plan.branch, index: plan.index, metadata: plan.metadata,
                    captures: plan.captures)
                try await createBranchUnderPermit(plan.name, start: plan.base, expectedHead: plan.head)
                let context = try await recoveryContext()
                guard context.head == plan.base, context.branch == plan.name else {
                    throw ModelFailure.changed
                }
            } catch {
                record.state = .needsVerification
                record.details = String(Redaction.text(error.localizedDescription).prefix(8192))
                try? store.save(record)
                throw RecoveryOutcomeUnknown(recordID: record.id, details: record.details ?? "")
            }
            do {
                let result = try await expectingBranch(plan.name).restoreStashUnderPermit(
                    plan.entry, in: plan.list,
                    restoreIndex: true, pop: plan.dropAfterApply, expectedHead: plan.base)
                if case .appliedNeedsReview(let details) = result {
                    record.state = .needsVerification
                    record.details = details
                } else {
                    record.state = .succeeded
                }
                record.observedHead = plan.base
                try store.save(record)
                return .restored(plan.name, result)
            } catch {
                record.state = .needsVerification
                record.details = String(Redaction.text(error.localizedDescription).prefix(8192))
                try? store.save(record)
                return .branchCreatedNeedsReview(plan.name, record.details ?? "")
            }
        }
    }

    private func verifyStashTaskSnapshot(
        head: String, branch: String, index: SelectedIndexSnapshot,
        metadata: [RecoveryFileMetadata], captures: [RecoveryFileCapture]
    ) async throws {
        let context = try await recoveryContext()
        guard context.head == head, context.branch == branch,
            try SelectedIndexSnapshot.read(location: location) == index
        else {
            throw ModelFailure.changed
        }
        try await RecoveryFileIO.verifyMetadataAll(metadata, location: location)
        try await RecoveryFileIO.verifyAll(captures, location: location)
    }

    private func stashTaskBackup(
        operation: String, head: String, branch: String, target: String,
        index: SelectedIndexSnapshot, sharedIndex: RecoverySharedIndexSnapshot?,
        captures: [RecoveryFileCapture]
    ) async throws -> (RecoveryStore, RecoveryRecord) {
        let store = try RecoveryStore(location: location)
        try await trimRecovery(store)
        var record = try await store.persist(
            operation: operation, head: head, branch: branch, target: target, index: index, files: captures,
            sharedIndex: sharedIndex)
        record.indexTree = try await recoveryIndexTree(index.bytes, shared: sharedIndex, persist: true)
        try store.save(record)
        try await protectRecovery(record)
        return (store, record)
    }
}
