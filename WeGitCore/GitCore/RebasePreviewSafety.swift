import Foundation

struct RebaseReplayPreview: Sendable {
    let paths: Set<String>
    let conflicts: [String]
    let resultTree: String?
}

extension RepositoryService {
    private func rebaseModifiedPaths(
        before: [String: RebaseTreeEntry], after: [String: RebaseTreeEntry]
    ) throws -> Set<String>? {
        guard before.count == after.count else { return nil }
        var changed: Set<String> = []
        for (path, original) in before {
            try Task.checkCancellation()
            guard let current = after[path] else { return nil }
            if current != original {
                guard current.mode == original.mode, ["100644", "100755"].contains(current.mode) else {
                    return nil
                }
                changed.insert(path)
            }
        }
        return changed
    }

    /// Different ordinary-file modifications cannot create an intermediate
    /// content or structural conflict. Verify Git's aggregate tree against the
    /// per-step byte-budgeted composition before using this bounded shortcut.
    func rebaseDisjointPreview(
        commits: [GitCommit], base: String?, target: String, metadata: RebaseTreeMetadata
    ) async throws -> RebaseReplayPreview? {
        guard let base, let last = commits.last else { return nil }
        let ancestor = try await metadata.entries(base, engine: singleCommitEngine)
        var expected = try await metadata.entries(target, engine: singleCommitEngine)
        guard let targetPaths = try rebaseModifiedPaths(before: ancestor, after: expected) else { return nil }
        var prior = ancestor
        var parent = base
        var paths: Set<String> = []
        for commit in commits {
            try Task.checkCancellation()
            guard commit.parents == [parent] else { return nil }
            let incoming = try await metadata.entries(commit.id, engine: singleCommitEngine)
            guard let changed = try rebaseModifiedPaths(before: prior, after: incoming),
                changed.isDisjoint(with: targetPaths)
            else { return nil }
            paths.formUnion(try rebaseInputPaths(ancestor: prior, current: expected, incoming: incoming))
            for path in changed { expected[path] = incoming[path] }
            guard paths.count <= RebaseBudget.entries else { throw RebaseBudget.exceeded }
            prior = incoming
            parent = commit.id
        }
        let renormalize = try await singleCommitEngine.run(
            ["config", "--bool", "--get", "merge.renormalize"], in: location.root, accepted: [0, 1]
        ).text.removingLastNewline
        guard renormalize != "true" else { return nil }
        let directory = try await SnapshotIO.run { _ in try SnapshotDirectory() }
        defer { withExtendedLifetime(directory) {} }
        let scratch = try await rebasePreviewEngine(directory: directory)
        let merge = try SingleCommitMergePreview(
            await scratch.run(
                ["merge-tree", "--write-tree", "--name-only", "-z", "--merge-base=" + base, target, last.id],
                in: location.root, accepted: [0, 1], outputLimit: RebaseBudget.metadataBytes))
        guard merge.conflicts.isEmpty,
            try await metadata.matches(merge.tree, expected: expected, engine: scratch)
        else { return nil }
        return RebaseReplayPreview(paths: paths, conflicts: [], resultTree: merge.tree)
    }

    private func rebasePreviewEngine(directory: SnapshotDirectory) async throws -> GitEngine {
        var scratch = singleCommitEngine
        scratch.environment["GIT_OBJECT_DIRECTORY"] = directory.url.path
        scratch.environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = singleCommitAlternatePath(
            location.commonDirectory.appending(path: "objects").path)
        let drivers = try await rebasePreviewDrivers()
        if !drivers.isEmpty {
            scratch.environment["GIT_CONFIG_COUNT"] = String(drivers.count)
            for (index, key) in drivers.enumerated() {
                scratch.environment["GIT_CONFIG_KEY_\(index)"] = key
                scratch.environment["GIT_CONFIG_VALUE_\(index)"] = "/usr/bin/false"
            }
        }
        for role in ["AUTHOR", "COMMITTER"] {
            scratch.environment["GIT_\(role)_NAME"] = "WeGit Preview"
            scratch.environment["GIT_\(role)_EMAIL"] = "preview@example.invalid"
            scratch.environment["GIT_\(role)_DATE"] = "2000-01-01T00:00:00 +0000"
        }
        return scratch
    }

    func rebaseCommits(_ ids: [String]) async throws -> [GitCommit] {
        guard ids.count <= RebaseBudget.commits, ids.allSatisfy(GitObjectID.valid) else {
            throw RebaseBudget.exceeded
        }
        guard !ids.isEmpty else { return [] }
        return try CommitParser.batch(
            await singleCommitEngine.run(
                ["cat-file", "--batch"], in: location.root,
                input: Data((ids.joined(separator: "\n") + "\n").utf8),
                outputLimit: RebaseBudget.metadataBytes
            ).stdout, expected: ids)
    }

    /// Simulate only until the next real conflict. Later resolutions are unknown;
    /// Continue prepares a new preview from the staged resolution. All synthetic
    /// trees/commits live in an owned temporary object directory, never in .git.
    func rebaseReplayPreview(
        steps: [RebaseStep], head: String, onto: String, labels: [String: String] = [:],
        stagedResolution: Bool = false, treeMetadata: RebaseTreeMetadata? = nil
    ) async throws -> RebaseReplayPreview {
        let directory = try await SnapshotIO.run { _ in try SnapshotDirectory() }
        let metadata = treeMetadata ?? RebaseTreeMetadata(root: location.root)
        defer { withExtendedLifetime(directory) {} }
        var scratch = try await rebasePreviewEngine(directory: directory)
        let ids = Array(Set(steps.compactMap(\.object))).sorted()
        let commits = Dictionary(uniqueKeysWithValues: try await rebaseCommits(ids).map { ($0.id, $0) })
        func commit(tree: String, parents: [String]) async throws -> String {
            let value = try await scratch.run(
                ["commit-tree", tree] + parents.flatMap { ["-p", $0] }, in: location.root,
                input: Data("WeGit read-only preview\n".utf8),
                configuration: [("commit.gpgsign", "false")]
            ).text.removingLastNewline
            guard GitObjectID.valid(value) else { throw ModelFailure.changed }
            return value
        }
        var current = head
        if stagedResolution {
            // write-tree refreshes the index's cache-tree even with optional
            // locks disabled. Rebuild a separate index from the pinned stage
            // records so no private tree ID can enter the user's index.
            let index = try await rebaseIndexSnapshot()
            _ = try rebaseIndexPaths(index)
            var records = Data()
            for row in index.split(separator: 0) {
                guard let tab = row.firstIndex(of: 9),
                    let header = String(data: row[..<tab], encoding: .utf8),
                    header.split(separator: " ").last == "0"
                else { throw ModelFailure.changed }
                records.append(contentsOf: row.dropFirst(2))
                records.append(0)
            }
            scratch.environment["GIT_INDEX_FILE"] = directory.url.appending(path: "preview-index").path
            _ = try await scratch.run(["read-tree", "--empty"], in: location.root)
            _ = try await scratch.run(
                ["update-index", "-z", "--index-info"], in: location.root, input: records)
            let tree = try await scratch.run(["write-tree"], in: location.root).text.removingLastNewline
            guard GitObjectID.valid(tree) else { throw ModelFailure.changed }
            _ = try await metadata.entries(tree, engine: scratch)
            current = try await commit(tree: tree, parents: [head])
            try await metadata.alias(current, tree: tree)
        }
        var rewritten = labels
        rewritten["onto"] = onto
        var paths: Set<String> = []
        for step in steps {
            try Task.checkCancellation()
            switch step {
            case .noop: continue
            case .label(let name): rewritten[name] = current
            case .reset(let name):
                guard let target = rewritten[name] else { throw ModelFailure.changed }
                paths.formUnion(try await metadata.paths(target, engine: scratch))
                current = target
            case .pick(let id):
                guard let source = commits[id], source.parents.count <= 1 else {
                    throw ModelFailure.unsupported(L10n.text("此重放步骤需要明确的合并父线，请在 Terminal 中处理。"))
                }
                let base: String
                if let parent = source.parents.first {
                    base = parent
                } else {
                    base = try await scratch.run(
                        ["hash-object", "-w", "-t", "tree", "--stdin"], in: location.root, input: Data()
                    ).text.removingLastNewline
                }
                paths.formUnion(
                    try await rebaseInputPaths(
                        base: base, head: current, other: id, metadata: metadata, engine: scratch))
                let merge = try SingleCommitMergePreview(
                    await scratch.run(
                        [
                            "merge-tree", "--write-tree", "--name-only", "-z", "--merge-base=" + base,
                            current, id,
                        ],
                        in: location.root, accepted: [0, 1], outputLimit: RebaseBudget.metadataBytes))
                paths.formUnion(merge.paths)
                if !merge.conflicts.isEmpty {
                    return RebaseReplayPreview(paths: paths, conflicts: merge.conflicts, resultTree: nil)
                }
                try await metadata.derive(merge.tree, from: current, engine: scratch)
                current = try await commit(tree: merge.tree, parents: [current])
                try await metadata.alias(current, tree: merge.tree)
            case .merge(_, let names):
                guard names.count == 1, let other = rewritten[names[0]] else {
                    throw ModelFailure.unsupported(L10n.text("此合并重放包含未支持的父线，请在 Terminal 中处理。"))
                }
                let bases = try rebaseObjectIDs(
                    await scratch.run(
                        ["merge-base", "--all", current, other], in: location.root, accepted: [0, 1]
                    ).stdout)
                guard bases.count == 1 else {
                    throw ModelFailure.unsupported(L10n.text("此合并重放需要确认多个或缺失的共同起点。"))
                }
                paths.formUnion(
                    try await rebaseInputPaths(
                        base: bases[0], head: current, other: other, metadata: metadata, engine: scratch))
                let merge = try SingleCommitMergePreview(
                    await scratch.run(
                        ["merge-tree", "--write-tree", "--name-only", "-z", current, other],
                        in: location.root, accepted: [0, 1], outputLimit: RebaseBudget.metadataBytes))
                paths.formUnion(merge.paths)
                if !merge.conflicts.isEmpty {
                    return RebaseReplayPreview(paths: paths, conflicts: merge.conflicts, resultTree: nil)
                }
                try await metadata.derive(merge.tree, from: current, engine: scratch)
                current = try await commit(tree: merge.tree, parents: Array(Set([current, other])).sorted())
                try await metadata.alias(current, tree: merge.tree)
            }
            guard paths.count <= RebaseBudget.entries else { throw RebaseBudget.exceeded }
        }
        return RebaseReplayPreview(
            paths: paths, conflicts: [], resultTree: try await singleCommitTree(current, engine: scratch))
    }

    func rebasePreviewSteps(_ commits: [GitCommit], base: String?, preserveMerges: Bool) async throws
        -> [RebaseStep]
    {
        guard preserveMerges else { return commits.map { .pick($0.id) } }
        let ids = Set(commits.map(\.id))
        var steps: [RebaseStep] = []
        for commit in commits {
            guard commit.parents.count <= 2, let base else {
                throw ModelFailure.unsupported(L10n.text("保留合并需要有共同起点的双父线历史。"))
            }
            for parent in commit.parents where !ids.contains(parent) {
                let related = try await singleCommitEngine.run(
                    ["merge-base", "--is-ancestor", parent, base], in: location.root, accepted: [0, 1])
                guard related.exitCode == 0 else {
                    throw ModelFailure.unsupported(L10n.text("此历史包含起点之外的父线，请在 Terminal 中确认保留合并。"))
                }
            }
            func label(_ parent: String?) -> String {
                parent.flatMap { ids.contains($0) ? "c" + $0 : nil } ?? "onto"
            }
            steps.append(.reset(label(commit.parents.first)))
            if commit.parents.count == 2 {
                steps.append(.merge(commit.id, [label(commit.parents[1])]))
            } else {
                steps.append(.pick(commit.id))
            }
            steps.append(.label("c" + commit.id))
        }
        return steps
    }
}
