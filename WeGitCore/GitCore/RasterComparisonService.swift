import Foundation

extension RepositoryService {
    @concurrent public func prepareRasterComparison(
        path: String, layer: DiffLayer, oldPath: String? = nil
    ) async throws -> RasterComparisonInput {
        try RecoveryFileIO.validate(path)
        if let oldPath { try RecoveryFileIO.validate(oldPath) }
        guard layer == .staged || layer == .unstaged || layer == .untracked else {
            throw ModelFailure.unsupported(L10n.text("图片比较需要明确的工作文件或暂存层。"))
        }
        let head = try await self.head()
        let index = try SelectedIndexSnapshot.read(location: location)
        let before: RasterInput
        let after: RasterInput
        if layer == .staged {
            before = try await rasterTreeInput(revision: head, path: oldPath ?? path)
            after = try await rasterIndexInput(path: path)
        } else {
            before = layer == .untracked ? rasterAbsent(path) : try await rasterIndexInput(path: path)
            after = try await rasterWorkingInput(path: path)
        }
        guard try await self.head() == head,
            try SelectedIndexSnapshot.read(location: location) == index
        else { throw ModelFailure.changed }
        if let current = after.currentFile {
            try await RecoveryFileIO.verifyAll([current], location: location)
        }
        try location.validateIdentity()
        return RasterComparisonInput(before: before, after: after)
    }

    @concurrent public func prepareRasterComparison(
        file: CommitFileChange, comparison: CommitComparison
    ) async throws -> RasterComparisonInput {
        guard comparison.location == location, comparison.files.contains(file) else {
            throw ModelFailure.changed
        }
        async let before = rasterTreeInput(revision: comparison.parent, path: file.oldPath ?? file.path)
        async let after = rasterTreeInput(revision: comparison.commit.id, path: file.path)
        let result = try await RasterComparisonInput(before: before, after: after)
        try location.validateIdentity()
        return result
    }

    private func rasterAbsent(_ path: String) -> RasterInput {
        RasterInput(path: path, kind: .absent, byteCount: 0, objectID: nil, snapshot: nil, currentFile: nil)
    }

    private func rasterTreeInput(revision: String?, path: String) async throws -> RasterInput {
        try RecoveryFileIO.validate(path)
        guard let revision else { return rasterAbsent(path) }
        guard GitObjectID.valid(revision) else { throw ModelFailure.invalidPath }
        let result = try await recoveryEngine.run(
            ["ls-tree", "-z", revision, "--", path], in: location.root, outputLimit: 128 * 1024)
        let records = result.stdout.split(separator: 0)
        guard records.count <= 1 else { throw ModelFailure.changed }
        guard let row = records.first else { return rasterAbsent(path) }
        guard let tab = row.firstIndex(of: 9),
            String(data: row[row.index(after: tab)...], encoding: .utf8) == path
        else { throw ModelFailure.changed }
        let fields = String(decoding: row[..<tab], as: UTF8.self).split(separator: " ").map(String.init)
        guard fields.count == 3, fields[1] == "blob", GitObjectID.valid(fields[2]) else {
            throw ModelFailure.unsupported(L10n.text("此对象不是可读取的图片文件。"))
        }
        if fields[0] == "120000" {
            return RasterInput(
                path: path, kind: .symbolicLink, byteCount: 0, objectID: fields[2], snapshot: nil,
                currentFile: nil)
        }
        guard ["100644", "100755"].contains(fields[0]) else { throw ModelFailure.changed }
        return try await rasterBlobInput(path: path, object: fields[2])
    }

    private func rasterIndexInput(path: String) async throws -> RasterInput {
        let result = try await recoveryEngine.run(
            ["ls-files", "--stage", "-z", "--", path], in: location.root, outputLimit: 128 * 1024)
        let records = result.stdout.split(separator: 0)
        guard records.count <= 1 else {
            throw ModelFailure.unsupported(L10n.text("此文件有未解决的索引阶段，请先处理冲突。"))
        }
        guard let row = records.first else { return rasterAbsent(path) }
        guard let tab = row.firstIndex(of: 9),
            String(data: row[row.index(after: tab)...], encoding: .utf8) == path
        else { throw ModelFailure.changed }
        let fields = String(decoding: row[..<tab], as: UTF8.self).split(separator: " ").map(String.init)
        guard fields.count == 3, fields[2] == "0", GitObjectID.valid(fields[1]) else {
            throw ModelFailure.changed
        }
        if fields[0] == "120000" {
            return RasterInput(
                path: path, kind: .symbolicLink, byteCount: 0, objectID: fields[1], snapshot: nil,
                currentFile: nil)
        }
        guard ["100644", "100755"].contains(fields[0]) else { throw ModelFailure.changed }
        return try await rasterBlobInput(path: path, object: fields[1])
    }

    private func rasterBlobInput(path: String, object: String) async throws -> RasterInput {
        let result = try await recoveryEngine.run(["cat-file", "-s", object], in: location.root)
        guard let count = Int64(result.text.removingLastNewline), count >= 0 else {
            throw ModelFailure.changed
        }
        guard count <= RasterReadBudget.bytes else {
            return RasterInput(
                path: path, kind: .oversized, byteCount: count, objectID: object, snapshot: nil,
                currentFile: nil)
        }
        let storage = try await SnapshotIO.run { _ in try SnapshotDirectory() }
        let output = storage.url.appending(path: "image")
        _ = try await recoveryEngine.run(
            ["cat-file", "blob", object], in: location.root, outputLimit: Int(RasterReadBudget.bytes),
            stdoutFile: output)
        let snapshot = try await SnapshotIO.run { _ in try SnapshotFile(directory: storage, url: output) }
        guard snapshot.stamp.size == count else { throw ModelFailure.changed }
        return RasterInput(
            path: path, kind: .image, byteCount: count, objectID: object, snapshot: snapshot, currentFile: nil
        )
    }

    private func rasterWorkingInput(path: String) async throws -> RasterInput {
        let metadata = try await RecoveryFileIO.metadataAll(location: location, paths: [path])[0]
        guard let version = metadata.version else { return rasterAbsent(path) }
        if version.size > RasterReadBudget.bytes {
            return RasterInput(
                path: path, kind: .oversized, byteCount: version.size, objectID: nil, snapshot: nil,
                currentFile: nil)
        }
        // APFS clones emit ItemCloned for their source. A live reader must not
        // create the event that invalidates and reloads its own content.
        let file = try await RecoveryFileIO.captureAll(
            location: location, paths: [path], limit: Int(RasterReadBudget.bytes), cloneSource: false)[0]
        guard file.version == metadata.version, file.parents == metadata.parents,
            file.missingParent == metadata.missingParent
        else { throw ModelFailure.changed }
        if file.file.kind == .symbolicLink {
            return RasterInput(
                path: path, kind: .symbolicLink, byteCount: Int64(file.file.bytes), objectID: nil,
                snapshot: nil, currentFile: file)
        }
        return RasterInput(
            path: path, kind: .image, byteCount: Int64(file.file.bytes), objectID: nil,
            snapshot: file.snapshot, currentFile: file)
    }
}
