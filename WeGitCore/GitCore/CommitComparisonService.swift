import Foundation

extension RepositoryService {
    @concurrent public func commitComparison(id: String, parent: String? = nil) async throws
        -> CommitComparison
    {
        try location.validateIdentity()
        guard GitObjectID.valid(id), parent.map(GitObjectID.valid) ?? true else {
            throw ModelFailure.invalidPath
        }
        let commit = try await readCommit(id)
        let selected = parent ?? commit.parents.first
        guard selected == nil || commit.parents.contains(selected!) else {
            throw ModelFailure.unsupported(L10n.text("比较对象不是此提交的父提交。"))
        }
        let base = selected == nil ? ["diff-tree", "--root", "--no-commit-id", "-r"] : ["diff"]
        let revisions = [selected, id].compactMap { $0 }
        let flags = ["--find-renames", "--no-ext-diff", "--no-textconv", "--no-color"]
        let names = try await engine.run(
            base + flags + ["--name-status", "-z"] + revisions + ["--"], in: location.root
        ).stdout
        let statistics = try await engine.run(
            base + flags + ["--numstat", "-z"] + revisions + ["--"], in: location.root
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
            let raw = try await engine.run(
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
            _ = try await engine.run(
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
