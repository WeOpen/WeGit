import Foundation

extension RepositoryService {
    @concurrent public func comparisonCommits(
        _ plan: ReferenceComparisonPlan, offset: Int = 0, count: Int = 100
    )
        async throws -> ComparisonCommitPage
    {
        guard plan.location == location, (0..<100000).contains(offset), (1...100).contains(count) else {
            throw ModelFailure.changed
        }
        try location.validateIdentity()
        let result = try await recoveryEngine.run(
            [
                "rev-list", "--topo-order", "--parents", "--max-count=\(count + 1)", "--skip=\(offset)",
                plan.target.id, "^" + plan.base.id, "--",
            ], in: location.root, outputLimit: 128 * 1024)
        guard result.stdout.isEmpty || result.stdout.last == 10 else { throw ModelFailure.changed }
        let rows = result.text.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        guard rows.count <= count + 1, rows.allSatisfy({ !$0.isEmpty && $0.allSatisfy(GitObjectID.valid) })
        else { throw ModelFailure.changed }
        let selected = Array(rows.prefix(count))
        let ids = selected.map { $0[0] }
        let isShallow = try await hasShallowHistory()
        let shallow = isShallow ? Set(selected.filter { $0.count == 1 }.map { $0[0] }) : []
        if ids.isEmpty { return ComparisonCommitPage(commits: [], nextOffset: nil) }
        let objects = try await recoveryEngine.run(
            ["cat-file", "--batch"], in: location.root,
            input: Data((ids.joined(separator: "\n") + "\n").utf8), outputLimit: 32 * 1024 * 1024)
        try location.validateIdentity()
        return ComparisonCommitPage(
            commits: try CommitParser.batch(objects.stdout, expected: ids, shallow: shallow),
            nextOffset: rows.count > count && offset + count < 100000 ? offset + count : nil)
    }

    @concurrent public func prepareReferenceComparison(
        base: String, target: String, kind: ReferenceComparisonKind = .twoPoint
    )
        async throws -> ReferenceComparisonPlan
    {
        try location.validateIdentity()
        func resolve(_ name: String) async throws -> GitCommit {
            guard !name.isEmpty, name.utf8.count <= 8192, !name.hasPrefix("-"), !name.contains("\0") else {
                throw ModelFailure.invalidPath
            }
            let value = try await recoveryEngine.run(
                ["rev-parse", "--verify", "--end-of-options", name + "^{commit}"], in: location.root
            ).text.removingLastNewline
            guard GitObjectID.valid(value) else { throw ModelFailure.changed }
            return try await RepositoryService(location: location, engine: recoveryEngine, queue: queue)
                .readCommit(value)
        }
        async let first = resolve(base)
        async let second = resolve(target)
        let (from, to) = try await (first, second)
        var ancestors: [String] = []
        if kind == .mergeBase {
            let result = try await recoveryEngine.run(
                ["merge-base", "--all", from.id, to.id], in: location.root, accepted: [0, 1],
                outputLimit: 8192)
            ancestors = result.text.split(separator: "\n").map(String.init)
            guard !ancestors.isEmpty else {
                throw ModelFailure.unsupported(L10n.text("无法确定共同祖先；请检查浅历史边界或选择两点比较。"))
            }
            guard ancestors.count <= 16, ancestors.allSatisfy(GitObjectID.valid) else {
                throw ModelFailure.changed
            }
        }
        try location.validateIdentity()
        return ReferenceComparisonPlan(
            id: UUID(), baseName: base, targetName: target, base: from, target: to,
            kind: kind, mergeBases: ancestors, location: location)
    }

    @concurrent public func referenceComparison(
        _ plan: ReferenceComparisonPlan, mergeBase: String? = nil,
        paths: [String]? = nil
    ) async throws -> ReferenceComparisonResult {
        guard plan.location == location else { throw ModelFailure.changed }
        let base: String
        if plan.kind == .twoPoint {
            base = plan.base.id
        } else {
            guard let selected = mergeBase ?? (plan.mergeBases.count == 1 ? plan.mergeBases.first : nil),
                plan.mergeBases.contains(selected)
            else { throw ModelFailure.unsupported(L10n.text("存在多个共同祖先，请明确选择比较起点。")) }
            base = selected
        }
        if let paths {
            guard !paths.isEmpty, paths.count <= 1000 else { throw ModelFailure.invalidPath }
            for path in paths { try validate(path) }
        }
        let flags = ["diff", "--find-renames", "--no-ext-diff", "--no-textconv", "--no-color"]
        async let names = recoveryEngine.run(
            flags + ["--name-status", "-z", base, plan.target.id, "--"] + (paths ?? []),
            in: location.root, outputLimit: 32 * 1024 * 1024,
            configuration: [(key: "diff.renameLimit", value: "1000")])
        async let statistics = recoveryEngine.run(
            flags + ["--numstat", "-z", base, plan.target.id, "--"] + (paths ?? []),
            in: location.root, outputLimit: 32 * 1024 * 1024,
            configuration: [(key: "diff.renameLimit", value: "1000")])
        let (changed, counts) = try await (names, statistics)
        let files = try CommitFilesParser.parse(names: changed.stdout, statistics: counts.stdout)
        guard files.count <= 100000 else { throw ModelFailure.unsupported(L10n.text("比较文件过多，请缩小路径范围。")) }
        try location.validateIdentity()
        let comparison = CommitComparison(commit: plan.target, parent: base, files: files, location: location)
        return ReferenceComparisonResult(plan: plan, effectiveBase: base, comparison: comparison)
    }

    @concurrent public func commitComparison(id: String, parent: String? = nil, paths: [String]? = nil)
        async throws
        -> CommitComparison
    {
        try location.validateIdentity()
        guard GitObjectID.valid(id), parent.map(GitObjectID.valid) ?? true else {
            throw ModelFailure.invalidPath
        }
        if let paths {
            guard (1...2).contains(paths.count) else { throw ModelFailure.invalidPath }
            for path in paths { try validate(path) }
        }
        let commit = try await readCommit(id)
        let selected = parent ?? commit.parents.first
        guard selected == nil || commit.parents.contains(selected!) else {
            throw ModelFailure.unsupported(L10n.text("比较对象不是此提交的父提交。"))
        }
        let base = selected == nil ? ["diff-tree", "--root", "--no-commit-id", "-r"] : ["diff"]
        let revisions = [selected, id].compactMap { $0 }
        let flags = ["--find-renames", "--no-ext-diff", "--no-textconv", "--no-color"]
        let names = try await recoveryEngine.run(
            base + flags + ["--name-status", "-z"] + revisions + ["--"] + (paths ?? []), in: location.root
        ).stdout
        let statistics = try await recoveryEngine.run(
            base + flags + ["--numstat", "-z"] + revisions + ["--"] + (paths ?? []), in: location.root
        ).stdout
        let files = try CommitFilesParser.parse(names: names, statistics: statistics)
        try location.validateIdentity()
        return CommitComparison(commit: commit, parent: selected, files: files, location: location)
    }

    @concurrent public func readCommitFile(
        _ file: CommitFileChange, comparison: CommitComparison,
        options: DiffReadOptions = DiffReadOptions(), loadLarge: Bool = false
    ) async throws -> DiffReadResult {
        try location.validateIdentity()
        guard comparison.location == location, comparison.files.contains(file),
            (0...200).contains(options.contextLines)
        else {
            throw ModelFailure.changed
        }
        try validate(file.path)
        if let old = file.oldPath { try validate(old) }
        let summary = DiffSummary(
            path: file.path, layer: .commit, additions: file.additions, deletions: file.deletions,
            fileBytes: nil, binary: file.binary)
        if !loadLarge && summary.needsExplicitLoad { return .deferred(summary, limit: nil) }
        let arguments = diffArguments(
            path: file.path, layer: .commit, options: options,
            revisions: [comparison.parent, comparison.commit.id].compactMap { $0 },
            rootCommit: comparison.parent == nil, oldPath: file.oldPath)
        do {
            let raw = try await recoveryEngine.run(
                arguments, in: location.root,
                outputLimit: loadLarge ? DiffReadBudget.patchBytes : DiffReadBudget.automaticBytes
            ).stdout
            return .loaded(
                try DiffParser.parse(raw, path: file.path, layer: .commit, head: nil, options: options))
        } catch ProcessFailure.outputLimit {
            if !loadLarge { return .deferred(summary, limit: nil) }
        } catch is DiffContentLimit {
            if !loadLarge { return .deferred(summary, limit: nil) }
        }
        try Task.checkCancellation()
        do {
            let directory = try await SnapshotIO.run { _ in try SnapshotDirectory() }
            let url = directory.url.appending(path: "commit.patch")
            _ = try await recoveryEngine.run(
                arguments, in: location.root, timeout: 120, outputLimit: DiskDiffBudget.bytes, stdoutFile: url
            )
            let source = try await SnapshotIO.run { _ in try SnapshotFile(directory: directory, url: url) }
            return .disk(
                try await DiskDiffSnapshot.index(
                    file: source, path: file.path, layer: .commit, options: options, head: nil))
        } catch ProcessFailure.outputLimit {
            return .deferred(summary, limit: .bytes(DiskDiffBudget.bytes))
        } catch let limit as DiffContentLimit { return .deferred(summary, limit: limit) }
    }
}
