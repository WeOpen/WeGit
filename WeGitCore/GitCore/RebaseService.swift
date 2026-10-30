import Foundation

extension RepositoryService {
    @concurrent
    public func prepareRebase(target: GitBranch, preserveMerges: Bool = false) async throws -> RebasePlan {
        try await queue.perform { try await rebasePlan(target: target, preserveMerges: preserveMerges) }
    }

    func rebasePlan(target: GitBranch, preserveMerges: Bool) async throws -> RebasePlan {
        try location.validateIdentity()
        let state = try await status()
        guard let head = state.head, !state.isDetached, state.files.isEmpty, state.sequencer == .none else {
            throw ModelFailure.unsupported(L10n.text("变基前请回到本地分支，保存工作区改动并完成当前操作。"))
        }
        try await validateBranchName(state.branch)
        let target = try await freshBranch(target)
        try await verifyCommit(target.oid)
        let bases = try await singleCommitEngine.run(
            ["merge-base", "--all", head, target.oid], in: location.root, accepted: [0, 1],
            outputLimit: RebaseBudget.metadataBytes
        ).stdout
        let baseIDs = try rebaseObjectIDs(bases)
        guard baseIDs.count <= 1 else {
            throw ModelFailure.unsupported(L10n.text("此历史存在多个共同起点，请在 Terminal 中确认变基范围。"))
        }
        let base = baseIDs.first
        let disposition: RebaseDisposition =
            head == target.oid || base == target.oid ? .upToDate : base == head ? .fastForward : .replay
        let ids: [String]
        if disposition == .replay {
            let arguments =
                [
                    "rev-list", "--reverse", "--topo-order", "--max-count=\(RebaseBudget.commits + 1)",
                ] + (preserveMerges ? [] : ["--no-merges"]) + [target.oid + ".." + head, "--"]
            ids = try rebaseObjectIDs(
                await singleCommitEngine.run(
                    arguments, in: location.root, outputLimit: RebaseBudget.metadataBytes
                ).stdout)
        } else {
            ids = []
        }
        guard ids.count <= RebaseBudget.commits else { throw RebaseBudget.exceeded }
        let index = try await singleCommitIndex()
        let commits = try await rebaseCommits(ids)
        let metadata = RebaseTreeMetadata(root: location.root)
        try await metadata.preload(
            [target.oid] + commits.flatMap { [$0.id] + $0.parents }, engine: singleCommitEngine)
        var paths = try await metadata.paths(target.oid, engine: singleCommitEngine)
        var scanned: Set<String> = [target.oid]
        for commit in commits {
            try Task.checkCancellation()
            for treeCommit in [commit.id] + commit.parents where scanned.insert(treeCommit).inserted {
                paths.formUnion(try await metadata.paths(treeCommit, engine: singleCommitEngine))
            }
            guard paths.count <= RebaseBudget.entries else { throw RebaseBudget.exceeded }
        }
        let preview = try await rebaseReplayPreview(
            steps: rebasePreviewSteps(commits, base: base, preserveMerges: preserveMerges),
            head: target.oid, onto: target.oid, treeMetadata: metadata)
        paths.formUnion(preview.paths)
        // A clean porcelain status omits ignored content. Git's initial reset onto
        // the target can overwrite it before the first commit is replayed.
        try await StashWorktreeGuard.validate(paths: paths, tracked: index.paths, location: location)
        let unpublished: Set<String>
        if ids.isEmpty {
            unpublished = []
        } else {
            unpublished = Set(
                try rebaseObjectIDs(
                    await singleCommitEngine.run(
                        [
                            "rev-list", "--max-count=\(RebaseBudget.commits + 1)", head, "--not", target.oid,
                            "--remotes", "--",
                        ], in: location.root, outputLimit: RebaseBudget.metadataBytes
                    ).stdout))
        }
        let fresh = try await status()
        guard fresh.head == head, fresh.branch == state.branch, fresh.files.isEmpty,
            fresh.sequencer == .none, try await singleCommitIndex().raw == index.raw,
            try await freshBranch(target) == target
        else { throw ModelFailure.changed }
        return RebasePlan(
            branch: state.branch, head: head, target: target, startingPoint: base, commits: commits,
            disposition: disposition, preserveMerges: preserveMerges,
            publishedCommits: Set(ids).subtracting(unpublished), conflictPaths: preview.conflicts,
            location: location, index: index.raw, writePaths: paths, resultTree: preview.resultTree)
    }

    func rebaseObjectIDs(_ bytes: Data) throws -> [String] {
        guard bytes.isEmpty || bytes.last == 10, let text = String(data: bytes, encoding: .utf8) else {
            throw ModelFailure.changed
        }
        let values = text.split(separator: "\n").map(String.init)
        guard values.allSatisfy(GitObjectID.valid), Set(values).count == values.count else {
            throw ModelFailure.changed
        }
        return values
    }

    func rebaseTreePaths(_ object: String, engine: GitEngine? = nil) async throws -> Set<String> {
        guard GitObjectID.valid(object) else { throw ModelFailure.invalidPath }
        let bytes = try await (engine ?? singleCommitEngine).run(
            ["ls-tree", "-r", "-z", "--full-tree", object], in: location.root,
            outputLimit: RebaseBudget.metadataBytes
        ).stdout
        guard bytes.isEmpty || bytes.last == 0 else { throw ModelFailure.changed }
        var paths: Set<String> = []
        for row in bytes.split(separator: 0) {
            guard let tab = row.firstIndex(of: 9),
                let header = String(data: row[..<tab], encoding: .utf8),
                let path = String(data: row[row.index(after: tab)...], encoding: .utf8)
            else { throw ModelFailure.changed }
            let fields = header.split(separator: " ")
            guard fields.count == 3, fields[1] == "blob", GitObjectID.valid(String(fields[2])),
                ["100644", "100755", "120000"].contains(fields[0])
            else {
                throw ModelFailure.unsupported(L10n.text("此变基范围包含子模块或未支持的树记录，请在 Terminal 中处理。"))
            }
            try validate(path)
            paths.insert(path)
        }
        guard paths.count <= RebaseBudget.entries else { throw RebaseBudget.exceeded }
        return paths
    }
}
