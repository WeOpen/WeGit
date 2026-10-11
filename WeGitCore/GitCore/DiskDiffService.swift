import Foundation

extension RepositoryService {
    public func diskDiff(path: String, layer: DiffLayer, options: DiffReadOptions = DiffReadOptions())
        async throws -> DiskDiffSnapshot
    {
        guard layer != .commit else { throw ModelFailure.unsupported("提交差异需要明确的比较对象。") }
        try validate(path)
        guard (0...200).contains(options.contextLines) else {
            throw ModelFailure.unsupported("上下文行数须在 0～200 之间。")
        }
        let directory = try await SnapshotIO.run { _ in try SnapshotDirectory() }
        let current = try await head()
        let file: SnapshotFile
        if layer == .untracked {
            file = try await SnapshotFile.captureWorktree(
                location: location, path: path, directory: directory)
        } else {
            let url = directory.url.appending(path: "patch")
            let result = try await engine.run(
                diffArguments(path: path, layer: layer, options: options), in: location.root,
                timeout: 120, outputLimit: DiskDiffBudget.bytes, stdoutFile: url)
            file = try await SnapshotIO.run { _ in try SnapshotFile(directory: directory, url: url) }
            guard file.stamp.size == result.stdoutByteCount else { throw ModelFailure.changed }
        }
        try Task.checkCancellation()
        return try await DiskDiffSnapshot.index(
            file: file, path: path, layer: layer, options: options, head: current,
            preview: layer == .untracked)
    }

    public func apply(hunk: DiskDiffHunk, from snapshot: DiskDiffSnapshot, discard: Bool = false) async throws
    {
        try await queue.perform {
            try await verifyHead(snapshot.head)
            guard snapshot.canApplyHunk, snapshot.hunks.contains(hunk),
                !discard || snapshot.layer == .unstaged
            else {
                throw ModelFailure.unsupported("此差异不支持当前差异块操作。")
            }
            let fresh = try await diskDiff(
                path: snapshot.path, layer: snapshot.layer, options: snapshot.options)
            guard fresh.digest == snapshot.digest, fresh.byteCount == snapshot.byteCount,
                fresh.head == snapshot.head,
                fresh.hunks.contains(hunk)
            else { throw ModelFailure.changed }
            let directory = try await SnapshotIO.run { _ in try SnapshotDirectory() }
            let patch = directory.url.appending(path: "selected.patch")
            try await snapshot.file.copy(ranges: [0..<snapshot.headerEnd, hunk.byteRange], to: patch)
            var arguments = ["apply"]
            if !discard { arguments.append("--cached") }
            if discard || snapshot.layer == .staged { arguments.append("--reverse") }
            try await verifyHead(snapshot.head)
            _ = try await engine.run(
                arguments + ["--check", "--", patch.path], in: location.root, timeout: 120)
            try await verifyHead(snapshot.head)
            _ = try await engine.run(arguments + ["--", patch.path], in: location.root, timeout: 120)
            withExtendedLifetime(directory) {}
        }
    }

    public func discard(_ snapshot: DiskDiffSnapshot) async throws {
        try await queue.perform {
            try await verifyHead(snapshot.head)
            guard snapshot.layer == .unstaged, !snapshot.options.ignoreWhitespace else {
                throw ModelFailure.unsupported("此入口只丢弃未暂存的已跟踪文件改动。")
            }
            let fresh = try await diskDiff(
                path: snapshot.path, layer: snapshot.layer, options: snapshot.options)
            guard fresh.digest == snapshot.digest, fresh.byteCount == snapshot.byteCount,
                fresh.head == snapshot.head
            else {
                throw ModelFailure.changed
            }
            try await verifyHead(snapshot.head)
            _ = try await engine.run(["restore", "--worktree", "--", snapshot.path], in: location.root)
        }
    }
}
