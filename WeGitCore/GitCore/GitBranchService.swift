import Foundation

extension RepositoryService {
    public func branches() async throws -> [GitBranch] {
        try location.validateIdentity()
        let data = try await engine.run(
            ["for-each-ref", "--format=" + BranchParser.format, "refs/heads", "refs/remotes"],
            in: location.root
        ).stdout
        return try BranchParser.parse(data)
    }

    public func createBranch(
        _ name: String, start: String? = nil, switchTo: Bool = true, expectedHead: String?
    ) async throws {
        try await withSharedOperation {
            try await verifyHead(expectedHead)
            try await validateBranchName(name)
            if let start { try await verifyCommit(start) }
            try await verifyHead(expectedHead)
            let arguments = switchTo ? ["switch", "-c", name] : ["branch", name]
            _ = try await engine.run(arguments + [start].compactMap { $0 }, in: location.root)
        }
    }

    func validateBranchName(_ name: String) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("@{"), !name.contains("\0") else {
            throw ModelFailure.invalidPath
        }
        _ = try await engine.run(["check-ref-format", "--branch", name], in: location.root)
    }

    func freshBranch(_ branch: GitBranch, localOnly: Bool = false) async throws -> GitBranch {
        guard let fresh = try await branches().first(where: { $0.id == branch.id }), fresh.oid == branch.oid,
            fresh.symbolicTarget == nil, !localOnly || !fresh.remote
        else { throw ModelFailure.changed }
        return fresh
    }

    func ensureNotInOtherWorktree(_ branch: GitBranch) throws {
        if let path = branch.worktreePath,
            URL(fileURLWithPath: path).resolvingSymlinksInPath() != location.root
        {
            throw ModelFailure.unsupported(L10n.text("此分支正在其他工作树中使用：\(path)"))
        }
    }

    public func checkoutCommit(_ oid: String, expectedHead: String?) async throws {
        try await withSharedOperation {
            try await verifyHead(expectedHead)
            try await verifyCommit(oid)
            guard try await status().sequencer == .none else {
                throw ModelFailure.unsupported(L10n.text("请先完成当前 Git 操作。"))
            }
            try await verifyHead(expectedHead)
            _ = try await engine.run(["switch", "--detach", oid], in: location.root)
        }
    }

    func verifyCommit(_ oid: String) async throws {
        guard GitObjectID.valid(oid) else { throw ModelFailure.invalidPath }
        let type = try await engine.run(["cat-file", "-t", oid], in: location.root).text.removingLastNewline
        guard type == "commit" else { throw ModelFailure.unsupported(L10n.text("起点不是有效提交。")) }
    }

    public func switchBranch(_ branch: GitBranch, expectedHead: String?) async throws {
        try await withSharedOperation {
            try await verifyHead(expectedHead)
            guard !branch.remote else {
                throw ModelFailure.unsupported(L10n.text("请先创建本地跟踪分支；当前版本不会自动猜测名称。"))
            }
            let fresh = try await freshBranch(branch, localOnly: true)
            try ensureNotInOtherWorktree(fresh)
            try await verifyHead(expectedHead)
            _ = try await engine.run(["switch", "--no-guess", fresh.name], in: location.root)
        }
    }

    public func merge(_ branch: GitBranch, expectedHead: String?) async throws {
        try await withSharedOperation {
            try await verifyHead(expectedHead)
            let state = try await status()
            guard state.files.isEmpty, state.sequencer == .none else {
                throw ModelFailure.unsupported(L10n.text("合并前请先处理工作区改动。"))
            }
            let source = try await engine.run(["rev-parse", "--verify", branch.id], in: location.root).text
                .removingLastNewline
            guard source == branch.oid else { throw ModelFailure.changed }
            try await verifyHead(expectedHead)
            _ = try await engine.run(["merge", "--no-edit", branch.oid], in: location.root, timeout: 120)
        }
    }

    public func sequencer(continueOperation: Bool, expected: Sequencer) async throws {
        if expected == .rebase {
            let state = try await status()
            guard let recovery = state.rebaseRecovery else { throw ModelFailure.changed }
            switch try await recoverRebase(continueOperation: continueOperation, expected: recovery) {
            case .completed, .aborted, .unchanged: return
            case .conflicts(_, let count):
                throw GitFailure(
                    message: L10n.text("存在未解决的冲突，请检查文件并继续或中止操作。"),
                    details: L10n.text("变基仍有 \(count) 个冲突。"), exitCode: 1)
            case .paused(_, let details):
                throw GitFailure(
                    message: L10n.text("变基尚未完成，请核对暂存区并继续或中止。"), details: details, exitCode: 1)
            }
        }
        try await withSharedOperation {
            let state = try await status()
            guard state.sequencer == expected, [.merge, .rebase].contains(expected) else {
                throw ModelFailure.changed
            }
            guard !continueOperation || state.conflicts.isEmpty else {
                throw ModelFailure.unsupported(L10n.text("请先解决所有冲突。"))
            }
            let args =
                expected == .merge && continueOperation
                ? ["commit", "--no-edit"] : [expected.rawValue, continueOperation ? "--continue" : "--abort"]
            try await verifyHead(state.head)
            _ = try await engine.run(args, in: location.root, timeout: 120)
        }
    }

}
