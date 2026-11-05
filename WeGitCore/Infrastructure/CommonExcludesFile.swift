import Darwin
import Foundation

struct CommonExcludesSnapshot: Sendable, Equatable {
    let parent: RepositoryNodeIdentity?
    let file: RepositoryNodeIdentity?
    let bytes: Data?
    let mode: mode_t
    let stamp: SnapshotFileStamp?
}

public struct IgnoreWriteOutcomeUnknown: Error, LocalizedError, Sendable {
    public let retainedInput: URL?
    public var errorDescription: String? {
        L10n.text("本地忽略文件的写入结果需要核对。输入已保留，不会自动重试。")
    }
}

/// The only supported metadata target is commonDirectory/info/exclude.
/// A worktree cannot redirect this writer to arbitrary Git or system files.
enum CommonExcludesFile {
    static let limit = 1024 * 1024
    @concurrent static func read(_ location: RepositoryLocation) async throws -> CommonExcludesSnapshot {
        try await SnapshotIO.run { cancellation in
            let parent = try Parent(location, create: false)
            try cancellation.check()
            let value = try readAt(parent, name: "exclude")
            try parent.validate()
            return value
        }
    }

    @concurrent static func replace(
        _ data: Data?, expected: CommonExcludesSnapshot, location: RepositoryLocation
    ) async throws -> CommonExcludesSnapshot {
        guard data?.count ?? 0 <= limit else { throw RecoveryBudget.exceeded }
        return try await SnapshotIO.run { cancellation in
            let parent = try Parent(location, create: data != nil && expected.parent == nil)
            guard parent.identity == expected.parent || parent.created && expected.parent == nil else {
                throw ModelFailure.changed
            }
            let current = try readAt(parent, name: "exclude")
            guard current.file == expected.file, current.bytes == expected.bytes,
                current.mode == expected.mode, current.stamp == expected.stamp
            else { throw ModelFailure.changed }
            guard let directory = parent.info else { return current }
            if data == current.bytes { return current }
            let lock = openat(
                directory, "exclude.lock", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw ModelFailure.changed }
            defer { Darwin.close(lock) }
            let lockURL = parent.url.appending(path: "exclude.lock")
            let ownLock = try RepositoryNodeIdentity.read(lockURL)
            var cleanupLock: RepositoryNodeIdentity? = ownLock
            var changed = false
            defer {
                if let known = cleanupLock, (try? RepositoryNodeIdentity.read(lockURL)) == known {
                    unlinkat(directory, "exclude.lock", 0)
                }
            }
            do {
                if let data {
                    try RecoveryFileIO.write(data, descriptor: lock, cancellation: cancellation)
                    guard fchmod(lock, expected.mode) == 0, fsync(lock) == 0 else {
                        throw ProcessFailure.outputWrite(errno)
                    }
                }
                let preparedLock = try readAt(parent, name: "exclude.lock")
                guard sameNode(preparedLock.file, ownLock),
                    preparedLock.bytes == (data ?? Data()),
                    preparedLock.mode == (data == nil ? 0o600 : expected.mode)
                else { throw ModelFailure.changed }
                cleanupLock = preparedLock.file
                try cancellation.check()
                try parent.validate()
                let fresh = try readAt(parent, name: "exclude")
                guard fresh == current else { throw ModelFailure.changed }
                if data == nil {
                    guard let source = current.file else { return current }
                    let holding = ".wegit-exclude-removed-" + UUID().uuidString
                    let holdingURL = parent.url.appending(path: holding)
                    guard renameatx_np(directory, "exclude", directory, holding, UInt32(RENAME_EXCL)) == 0
                    else {
                        throw ModelFailure.changed
                    }
                    changed = true
                    let held = try readAt(parent, name: holding)
                    guard sameNode(held.file, source), held.bytes == expected.bytes,
                        held.mode == expected.mode
                    else {
                        if renameatx_np(directory, holding, directory, "exclude", UInt32(RENAME_EXCL)) == 0 {
                            changed = false
                            throw ModelFailure.changed
                        }
                        throw IgnoreWriteOutcomeUnknown(retainedInput: holdingURL)
                    }
                    guard unlinkat(directory, holding, 0) == 0, fsync(directory) == 0 else {
                        throw IgnoreWriteOutcomeUnknown(retainedInput: holdingURL)
                    }
                } else if expected.file == nil {
                    guard
                        renameatx_np(directory, "exclude.lock", directory, "exclude", UInt32(RENAME_EXCL))
                            == 0
                    else {
                        throw ModelFailure.changed
                    }
                    cleanupLock = nil
                    changed = true
                } else {
                    guard
                        renameatx_np(directory, "exclude.lock", directory, "exclude", UInt32(RENAME_SWAP))
                            == 0
                    else {
                        throw ModelFailure.changed
                    }
                    changed = true
                    cleanupLock = nil
                    do {
                        let moved = try readAt(parent, name: "exclude.lock")
                        guard sameNode(moved.file, expected.file), moved.bytes == expected.bytes,
                            moved.mode == expected.mode
                        else { throw ModelFailure.changed }
                        cleanupLock = moved.file
                    } catch {
                        if let installed = try? readAt(parent, name: "exclude"),
                            sameNode(installed.file, preparedLock.file), installed.bytes == data,
                            installed.mode == expected.mode,
                            renameatx_np(directory, "exclude.lock", directory, "exclude", UInt32(RENAME_SWAP))
                                == 0
                        {
                            changed = false
                            cleanupLock = try? RepositoryNodeIdentity.read(lockURL)
                            throw ModelFailure.changed
                        }
                        throw IgnoreWriteOutcomeUnknown(retainedInput: lockURL)
                    }
                }
                guard fsync(directory) == 0 else { throw ProcessFailure.outputWrite(errno) }
                try parent.validate()
                let result = try readAt(parent, name: "exclude")
                guard result.bytes == data, data == nil || sameNode(result.file, preparedLock.file),
                    data == nil || result.mode == expected.mode
                else { throw ModelFailure.changed }
                if let obsolete = cleanupLock {
                    guard try RepositoryNodeIdentity.readIfPresent(lockURL) == obsolete,
                        unlinkat(directory, "exclude.lock", 0) == 0, fsync(directory) == 0
                    else { throw IgnoreWriteOutcomeUnknown(retainedInput: lockURL) }
                    cleanupLock = nil
                }
                return result
            } catch {
                if changed {
                    cleanupLock = nil
                    throw (error as? IgnoreWriteOutcomeUnknown)
                        ?? IgnoreWriteOutcomeUnknown(
                            retainedInput: (try? RepositoryNodeIdentity.readIfPresent(lockURL)) != nil
                                ? lockURL : nil)
                }
                throw error
            }
        }
    }

    // Writing and controlled renames change marker timestamps. Compare the
    // pinned node here, then independently verify its complete bytes and mode.
    private static func sameNode(_ a: RepositoryNodeIdentity?, _ b: RepositoryNodeIdentity?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.device == b.device && a.inode == b.inode && a.kind == b.kind
            && a.bornSeconds == b.bornSeconds && a.bornNanoseconds == b.bornNanoseconds
    }

    private static func readAt(_ parent: Parent, name: String) throws -> CommonExcludesSnapshot {
        guard let directory = parent.info else {
            return CommonExcludesSnapshot(parent: nil, file: nil, bytes: nil, mode: 0o644, stamp: nil)
        }
        var before = stat()
        if fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ModelFailure.changed }
            return CommonExcludesSnapshot(
                parent: parent.identity, file: nil, bytes: nil, mode: 0o644, stamp: nil)
        }
        guard before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            before.st_uid == geteuid(), before.st_size >= 0, before.st_size <= limit
        else { throw ModelFailure.changed }
        let node = try RepositoryNodeIdentity.read(parent.url.appending(path: name))
        let data = try SelectedIndexSnapshot.read(parent: directory, name: name)
        var after = stat()
        guard fstatat(directory, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
            SnapshotFileStamp(before) == SnapshotFileStamp(after)
        else { throw ModelFailure.changed }
        return CommonExcludesSnapshot(
            parent: parent.identity, file: node, bytes: data.bytes, mode: data.mode,
            stamp: SnapshotFileStamp(after))
    }

    private final class Parent {
        let location: RepositoryLocation
        let common: Int32
        let info: Int32?
        let identity: RepositoryNodeIdentity?
        let created: Bool
        var url: URL { location.commonDirectory.appending(path: "info") }
        init(_ location: RepositoryLocation, create: Bool) throws {
            try location.validateIdentity()
            self.location = location
            let common = Darwin.open(
                location.commonDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard common >= 0 else { throw ModelFailure.changed }
            var root = stat()
            guard fstat(common, &root) == 0, root.st_dev == location.commonIdentity.device,
                root.st_ino == location.commonIdentity.inode,
                root.st_birthtimespec.tv_sec == location.commonIdentity.bornSeconds,
                root.st_birthtimespec.tv_nsec == location.commonIdentity.bornNanoseconds
            else {
                Darwin.close(common)
                throw ModelFailure.changed
            }
            var made = false
            var info = openat(common, "info", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if info < 0, errno == ENOENT, create {
                guard mkdirat(common, "info", 0o755) == 0, fsync(common) == 0 else {
                    Darwin.close(common)
                    throw ModelFailure.changed
                }
                made = true
                info = openat(common, "info", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if info < 0, errno != ENOENT {
                Darwin.close(common)
                throw ModelFailure.changed
            }
            let openedIdentity: RepositoryNodeIdentity?
            do {
                openedIdentity =
                    info >= 0
                    ? try RepositoryNodeIdentity.read(
                        location.commonDirectory.appending(path: "info"), directory: true)
                    : nil
            } catch {
                if info >= 0 { Darwin.close(info) }
                Darwin.close(common)
                throw error
            }
            self.common = common
            self.info = info >= 0 ? info : nil
            created = made
            identity = openedIdentity
            do { try validate() } catch {
                if info >= 0 { Darwin.close(info) }
                Darwin.close(common)
                throw error
            }
        }
        deinit {
            if let info { Darwin.close(info) }
            Darwin.close(common)
        }
        func validate() throws {
            try location.validateIdentity()
            guard try RepositoryNodeIdentity.readIfPresent(url) == identity else {
                throw ModelFailure.changed
            }
            if let info, let identity {
                var value = stat()
                guard fstat(info, &value) == 0, value.st_dev == identity.device,
                    value.st_ino == identity.inode,
                    value.st_birthtimespec.tv_sec == identity.bornSeconds,
                    value.st_birthtimespec.tv_nsec == identity.bornNanoseconds
                else { throw ModelFailure.changed }
            }
        }
    }
}
