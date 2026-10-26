import Darwin
import Foundation

extension RepositoryService {
    @concurrent public func prepareSingleCommit(_ operation: SingleCommitOperation, target: String)
        async throws -> SingleCommitPlan
    {
        try await queue.perform { try await singleCommitPlan(operation, target: target) }
    }

    private func singleCommitPlan(_ operation: SingleCommitOperation, target: String) async throws
        -> SingleCommitPlan
    {
        try location.validateIdentity()
        let state = try await status()
        guard let head = state.head, state.files.isEmpty, state.sequencer == .none else {
            throw ModelFailure.unsupported(L10n.text("请先提交或保存工作区改动，并完成当前 Git 操作。"))
        }
        let source = RepositoryService(location: location, engine: singleCommitEngine, queue: queue)
        let commit = try await source.readCommit(target)
        guard commit.parents.count <= 1 else {
            throw ModelFailure.unsupported(L10n.text("请选取一个普通提交；合并提交需要另行选择主线。"))
        }
        let index = try await singleCommitIndex()
        let directory = try await SnapshotIO.run { _ in try SnapshotDirectory() }
        defer { withExtendedLifetime(directory) {} }
        var previewEngine = singleCommitEngine
        // merge-tree writes only into this private directory and reads existing
        // objects through an alternate. Preview never runs checkout or commit hooks.
        previewEngine.environment["GIT_OBJECT_DIRECTORY"] = directory.url.path
        previewEngine.environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = singleCommitAlternatePath(
            location.commonDirectory.appending(path: "objects").path)
        let parent: String
        if let first = commit.parents.first {
            parent = first
        } else {
            parent = try await previewEngine.run(
                ["hash-object", "-w", "-t", "tree", "--stdin"], in: location.root, input: Data()
            ).text.removingLastNewline
        }
        guard GitObjectID.valid(parent) else { throw ModelFailure.changed }
        let base = operation == .cherryPick ? parent : commit.id
        let other = operation == .cherryPick ? commit.id : parent
        let inputPaths = try await singleCommitInputPaths(
            base: base, head: head, other: other, engine: previewEngine)
        let merge = try SingleCommitMergePreview(
            await previewEngine.run(
                ["merge-tree", "--write-tree", "--name-only", "-z", "--merge-base=" + base, head, other],
                in: location.root, accepted: [0, 1], timeout: 30,
                outputLimit: SingleCommitBudget.metadataBytes))
        let files = try await singleCommitChanges(from: head, to: merge.tree, engine: previewEngine)
        let paths = inputPaths.union(files.map(\.path)).union(merge.paths)
        try await StashWorktreeGuard.validate(paths: paths, tracked: index.paths, location: location)
        try await verifyHead(head)
        let fresh = try await status()
        guard fresh.branch == state.branch, fresh.head == head, fresh.files.isEmpty, fresh.sequencer == .none,
            try await singleCommitIndex().raw == index.raw
        else { throw ModelFailure.changed }
        return SingleCommitPlan(
            operation: operation, target: commit, head: head, branch: state.branch,
            files: files, conflictPaths: merge.conflicts, location: location, index: index.raw,
            resultTree: merge.tree, writePaths: paths)
    }

    public func executeSingleCommit(_ plan: SingleCommitPlan) async throws -> SingleCommitOutcome {
        try await withSharedOperation {
            guard plan.location == location else { throw ModelFailure.changed }
            try await verifyHead(plan.head)
            let fresh = try await singleCommitPlan(plan.operation, target: plan.target.id)
            guard fresh.head == plan.head, fresh.branch == plan.branch, fresh.target == plan.target,
                fresh.index == plan.index, fresh.resultTree == plan.resultTree, fresh.files == plan.files,
                fresh.conflictPaths == plan.conflictPaths, fresh.writePaths == plan.writePaths
            else { throw ModelFailure.changed }
            guard plan.hasChanges else {
                throw ModelFailure.unsupported(L10n.text("此提交在当前 HEAD 上没有可应用的改动。"))
            }
            try Task.checkCancellation()
            var failure: (any Error)?
            do {
                if plan.operation == .revert {
                    // A one-shot revert removes REVERT_HEAD before committing; a
                    // failed hook/signature then has no Git recovery entry. First
                    // apply with --no-commit, which keeps REVERT_HEAD, and let the
                    // native --continue commit and clear it only after success.
                    _ = try await singleCommitEngine.run(
                        ["revert", "--no-commit", "--no-edit", "--strategy=ort", plan.target.id],
                        in: location.root, timeout: 120)
                    let ready = try await status()
                    guard ready.head == plan.head, ready.branch == plan.branch,
                        ready.singleCommitRecovery?.target == plan.target.id, ready.conflicts.isEmpty
                    else { throw ModelFailure.changed }
                    let tree = try await singleCommitEngine.run(["write-tree"], in: location.root).text
                        .removingLastNewline
                    guard tree == plan.resultTree else { throw ModelFailure.changed }
                    _ = try await singleCommitEngine.run(
                        ["revert", "--continue"], in: location.root, timeout: 120)
                } else {
                    _ = try await singleCommitEngine.run(
                        ["cherry-pick", "--no-edit", "--strategy=ort", plan.target.id],
                        in: location.root, timeout: 120)
                }
            } catch { failure = error }
            let observed = await singleCommitObservation()
            let details = failure.map { ($0 as? GitFailure)?.details ?? $0.localizedDescription } ?? ""
            guard let observed else {
                throw SingleCommitOutcomeUnknown(
                    operation: plan.operation, previousHead: plan.head, observedHead: nil, details: details)
            }
            if let recovery = observed.status.singleCommitRecovery,
                recovery.operation == plan.operation, recovery.target == plan.target.id,
                observed.status.head == plan.head, observed.status.branch == plan.branch
            {
                if !observed.status.conflicts.isEmpty {
                    return .conflicts(observed.status.conflicts.count)
                }
                return .pending(details)
            }
            if let failure, observed.status.head == plan.head, observed.status.branch == plan.branch,
                observed.status.files.isEmpty, observed.status.sequencer == .none
            {
                throw failure
            }
            guard failure == nil, let commit = observed.commit, commit.id != plan.head,
                commit.parents == [plan.head], observed.tree == plan.resultTree,
                observed.status.branch == plan.branch, observed.status.sequencer == .none,
                observed.status.files.isEmpty
            else {
                throw SingleCommitOutcomeUnknown(
                    operation: plan.operation, previousHead: plan.head,
                    observedHead: observed.status.head, details: details)
            }
            return .committed(commit.id)
        }
    }

    public func recoverSingleCommit(continueOperation: Bool, expected: SingleCommitRecovery) async throws {
        try await withSharedOperation {
            let state = try await status()
            guard expected.location == location, state.singleCommitRecovery == expected else {
                throw ModelFailure.changed
            }
            guard !continueOperation || state.conflicts.isEmpty else {
                throw ModelFailure.unsupported(L10n.text("请先解决所有冲突。"))
            }
            try await verifyHead(expected.head)
            var failure: (any Error)?
            do {
                _ = try await singleCommitEngine.run(
                    [expected.operation.rawValue, continueOperation ? "--continue" : "--abort"],
                    in: location.root, timeout: 120)
            } catch { failure = error }
            let observed = await singleCommitObservation()
            let details = failure.map { ($0 as? GitFailure)?.details ?? $0.localizedDescription } ?? ""
            if let failure, observed?.status.head == expected.head,
                observed?.status.singleCommitRecovery?.target == expected.target
            {
                throw failure
            }
            guard failure == nil, let observed, observed.status.sequencer == .none,
                observed.status.branch == expected.branch,
                continueOperation
                    ? observed.commit?.parents == [expected.head]
                    : observed.status.head == expected.head
            else {
                throw SingleCommitOutcomeUnknown(
                    operation: expected.operation, previousHead: expected.head,
                    observedHead: observed?.status.head, details: details)
            }
        }
    }

    func singleCommitRecovery(for state: RepositoryStatus, operation: SingleCommitOperation) throws
        -> SingleCommitRecovery?
    {
        guard let head = state.head,
            try RepositoryNodeIdentity.readIfPresent(location.gitDirectory.appending(path: "sequencer"))
                == nil
        else { return nil }
        let marker = location.gitDirectory.appending(path: operation.marker)
        let identity = try RepositoryNodeIdentity.read(marker)
        guard identity.kind == UInt16(S_IFREG), (identity.markerSize ?? 0) <= 65 else { return nil }
        let descriptor = Darwin.open(marker.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ModelFailure.changed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data = try handle.read(upToCount: 66) ?? Data()
        try handle.close()
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        let target = value.removingLastNewline
        guard GitObjectID.valid(target), try RepositoryNodeIdentity.read(marker) == identity else {
            return nil
        }
        return SingleCommitRecovery(
            operation: operation, target: target, head: head, branch: state.branch,
            location: location, markerIdentity: identity)
    }

    private struct SingleCommitObservation: Sendable {
        let status: RepositoryStatus
        let commit: GitCommit?
        let tree: String?
    }

    private func singleCommitObservation() async -> SingleCommitObservation? {
        await Task.detached {
            do {
                let state = try await status()
                let source = RepositoryService(location: location, engine: singleCommitEngine, queue: queue)
                let commit: GitCommit?
                let tree: String?
                if let head = state.head {
                    commit = try await source.readCommit(head)
                    tree = try await singleCommitTree(head, engine: singleCommitEngine)
                } else {
                    commit = nil
                    tree = nil
                }
                return SingleCommitObservation(status: state, commit: commit, tree: tree)
            } catch { return nil }
        }.value
    }
}
