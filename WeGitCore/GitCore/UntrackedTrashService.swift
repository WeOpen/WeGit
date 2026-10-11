import Darwin
import Foundation

public struct UntrackedRemoval: Sendable {
    public let path: String
    public let head: String?
    public let byteCount: Int64
    public let symbolicLink: Bool
    let location: RepositoryLocation
    let version: SnapshotFileStamp
}

public struct UntrackedTrashReceipt: Sendable {
    public let originalPath: String
    public let trashURL: URL
}

public struct UntrackedTrashFailure: Error, LocalizedError, Sendable {
    public let trashURL: URL?
    public var errorDescription: String? {
        if let trashURL {
            return "废纸篓操作的结果无法完整核对。请在 Finder 检查原路径和此位置：\(trashURL.path)"
        }
        return "废纸篓操作的结果无法完整核对。请在 Finder 检查原路径和废纸篓后再操作。"
    }
}

extension RepositoryService {
    public func prepareUntrackedRemoval(path: String, expectedHead: String?) async throws -> UntrackedRemoval
    {
        try await queue.perform {
            try validate(path)
            try await verifyHead(expectedHead)
            let current = try await status()
            guard current.files.contains(where: { $0.path == path && $0.untracked }) else {
                throw ModelFailure.unsupported("只能从此入口移除当前未跟踪的文件。请刷新后检查文件状态。")
            }
            return try await SnapshotIO.run { cancellation in
                let reader = try RepositoryFileReader(
                    location: location, path: path, cancellation: cancellation, openContents: false)
                try reader.validate()
                return UntrackedRemoval(
                    path: path, head: expectedHead, byteCount: reader.size, symbolicLink: reader.symbolicLink,
                    location: location, version: reader.version)
            }
        }
    }

    /// Call only after confirming this exact path and snapshot. The index is never changed,
    /// and an unavailable Trash never falls back to permanent deletion.
    public func trashUntracked(_ removal: UntrackedRemoval, trash: any FileTrashing = SystemTrash())
        async throws -> UntrackedTrashReceipt
    {
        try await queue.perform {
            guard removal.location == location else { throw ModelFailure.repositoryReplaced }
            try await verifyHead(removal.head)
            let current = try await status()
            guard current.files.contains(where: { $0.path == removal.path && $0.untracked }) else {
                throw ModelFailure.changed
            }
            try await verifyHead(removal.head)
            return try await SnapshotIO.run { cancellation in
                let reader = try RepositoryFileReader(
                    location: location, path: removal.path, cancellation: cancellation, openContents: false)
                guard reader.version == removal.version, reader.symbolicLink == removal.symbolicLink else {
                    throw ModelFailure.changed
                }
                try reader.validate()
                try cancellation.check()
                // FileManager's move is synchronous. Once it succeeds, report the verified
                // result even if cancellation arrived during the move, rather than inviting a retry.
                let destination: URL?
                do {
                    destination = try trash.moveToTrash(location.root.appending(path: removal.path))
                } catch {
                    if !reader.containsOriginalEntry() { throw UntrackedTrashFailure(trashURL: nil) }
                    throw error
                }
                guard let destination, destination.isFileURL else {
                    throw UntrackedTrashFailure(trashURL: destination)
                }
                var moved = stat()
                guard lstat(destination.path, &moved) == 0, moved.st_dev == removal.version.device,
                    moved.st_ino == removal.version.inode, moved.st_size == removal.version.size,
                    moved.st_mtimespec.tv_sec == removal.version.modifiedSeconds,
                    moved.st_mtimespec.tv_nsec == removal.version.modifiedNanoseconds,
                    !reader.containsOriginalEntry()
                else { throw UntrackedTrashFailure(trashURL: destination) }
                return UntrackedTrashReceipt(originalPath: removal.path, trashURL: destination)
            }
        }
    }
}
