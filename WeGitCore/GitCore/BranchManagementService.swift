import Foundation

extension RepositoryService {
    public func renameBranch(_ branch: GitBranch, to name: String, expectedHead: String?) async throws {
        try await queue.perform {
            try await verifyHead(expectedHead)
            let fresh = try await freshBranch(branch, localOnly: true)
            try ensureNotInOtherWorktree(fresh)
            guard try await status().sequencer == .none else {
                throw ModelFailure.unsupported(L10n.text("请先完成当前 Git 操作。"))
            }
            try await validateBranchName(name)
            guard fresh.name != name else { return }
            try await verifyHead(expectedHead)
            _ = try await engine.run(["branch", "--move", "--", fresh.name, name], in: location.root)
        }
    }

    public func prepareBranchDeletion(_ branch: GitBranch, expectedHead: String?) async throws
        -> BranchDeletionPlan
    {
        try await queue.perform {
            try await verifyHead(expectedHead)
            return try await deletionPlan(branch, head: expectedHead)
        }
    }

    private func deletionPlan(_ branch: GitBranch, head: String?) async throws -> BranchDeletionPlan {
        let fresh = try await freshBranch(branch, localOnly: true)
        guard !fresh.current, fresh.worktreePath == nil else {
            throw ModelFailure.unsupported(L10n.text("正在检出的分支不能删除。请先切换当前或其他工作树的分支。"))
        }
        guard try await status().sequencer == .none else {
            throw ModelFailure.unsupported(L10n.text("请先完成当前 Git 操作。"))
        }
        var target = L10n.text("当前 HEAD")
        var targetOID = head
        if let upstream = fresh.upstreamRef {
            let resolved = try await engine.run(
                ["rev-parse", "--verify", "--end-of-options", upstream + "^{commit}"], in: location.root,
                accepted: [0, 128])
            if resolved.exitCode == 0 {
                target = fresh.upstream
                targetOID = resolved.text.removingLastNewline
            }
        }
        var merged = false
        if let targetOID {
            let result = try await engine.run(
                ["merge-base", "--is-ancestor", fresh.oid, targetOID], in: location.root, accepted: [0, 1])
            merged = result.exitCode == 0
        }
        return BranchDeletionPlan(
            branch: fresh, head: head, mergeTarget: target, mergeTargetOID: targetOID, merged: merged,
            location: location)
    }

    public func deleteBranch(_ plan: BranchDeletionPlan, allowUnmerged: Bool = false) async throws {
        try await queue.perform {
            guard plan.location == location else { throw ModelFailure.repositoryReplaced }
            try await verifyHead(plan.head)
            let current = try await deletionPlan(plan.branch, head: plan.head)
            guard current.mergeTargetOID == plan.mergeTargetOID,
                current.branch.upstreamRef == plan.branch.upstreamRef,
                current.merged == plan.merged
            else { throw ModelFailure.changed }
            guard current.merged || allowUnmerged else {
                throw ModelFailure.unsupported(L10n.text("分支尚未合并，需要明确确认删除未合并分支。"))
            }
            try await verifyHead(plan.head)
            _ = try await engine.run(
                ["branch", allowUnmerged ? "-D" : "-d", "--", current.branch.name], in: location.root)
        }
    }

    public func createTrackingBranch(
        from remote: GitBranch, name: String, switchTo: Bool = true, expectedHead: String?
    ) async throws {
        try await queue.perform {
            try await verifyHead(expectedHead)
            let fresh = try await freshBranch(remote)
            guard fresh.remote else { throw ModelFailure.unsupported(L10n.text("请选择远端跟踪分支。")) }
            try await validateBranchName(name)
            try await verifyCommit(fresh.oid)
            guard try await status().sequencer == .none else {
                throw ModelFailure.unsupported(L10n.text("请先完成当前 Git 操作。"))
            }
            try await verifyHead(expectedHead)
            let arguments =
                switchTo
                ? ["switch", "--track", "-c", name, fresh.id] : ["branch", "--track", name, fresh.id]
            _ = try await engine.run(arguments, in: location.root)
        }
    }

    public func setUpstream(of branch: GitBranch, to upstream: GitBranch?, expectedHead: String?) async throws
    {
        try await queue.perform {
            try await verifyHead(expectedHead)
            let local = try await freshBranch(branch, localOnly: true)
            try ensureNotInOtherWorktree(local)
            if let upstream {
                let target = try await freshBranch(upstream)
                guard target.id != local.id else {
                    throw ModelFailure.unsupported(L10n.text("分支不能将自身设置为上游。"))
                }
                try await verifyHead(expectedHead)
                _ = try await engine.run(
                    ["branch", "--set-upstream-to=" + target.id, "--", local.name], in: location.root)
            } else if local.upstreamRef != nil {
                try await verifyHead(expectedHead)
                _ = try await engine.run(["branch", "--unset-upstream", "--", local.name], in: location.root)
            }
        }
    }
}
