import Darwin
import Foundation

public struct ConfigurationWriteOutcomeUnknown: Error, LocalizedError, Sendable {
    public let retainedInput: URL?
    public var errorDescription: String? {
        L10n.text("Git 配置写入结果需要核对。输入已保留，请重新读取配置；不会自动重试。")
    }
}

/// Edits a private copy while holding Git's actual scope-specific lock. Worktree
/// writes use config.worktree explicitly, so an extension toggle cannot redirect
/// --worktree to the shared config file.
final class RepositoryConfigurationFile: @unchecked Sendable {
    let location: RepositoryLocation
    let name: String
    let url: URL
    let snapshot: SelectedIndexSnapshot
    private let parent: Int32
    private let lock: Int32
    private let original: RepositoryNodeIdentity?
    private let originalStamp: SnapshotFileStamp?
    private var installed = false
    var hasInstalled: Bool { installed }
    var retainedInput: URL { snapshot.bytes == nil ? url : url.appendingPathExtension("lock") }

    init(location: RepositoryLocation, scope: GitSettingScope) throws {
        guard scope == .local || scope == .worktree else { throw ModelFailure.invalidPath }
        try location.validateIdentity()
        self.location = location
        name = scope == .local ? "config" : "config.worktree"
        let directory = scope == .local ? location.commonDirectory : location.gitDirectory
        let identity = scope == .local ? location.commonIdentity : location.gitIdentity
        url = directory.appending(path: name)
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode,
            info.st_birthtimespec.tv_sec == identity.bornSeconds,
            info.st_birthtimespec.tv_nsec == identity.bornNanoseconds
        else {
            Darwin.close(fd)
            throw ModelFailure.changed
        }
        let locked = openat(fd, name + ".lock", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard locked >= 0 else {
            Darwin.close(fd)
            throw ModelFailure.changed
        }
        do {
            let value = try Self.read(fd, name: name)
            snapshot = value.0
            original = try RepositoryNodeIdentity.readIfPresent(url)
            originalStamp = value.1
        } catch {
            var own = stat()
            var named = stat()
            if fstat(locked, &own) == 0, fstatat(fd, name + ".lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
                own.st_dev == named.st_dev, own.st_ino == named.st_ino
            {
                unlinkat(fd, name + ".lock", 0)
            }
            Darwin.close(locked)
            Darwin.close(fd)
            throw error
        }
        parent = fd
        lock = locked
    }

    deinit {
        var own = stat()
        var named = stat()
        if fstat(lock, &own) == 0, fstatat(parent, name + ".lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
            own.st_dev == named.st_dev, own.st_ino == named.st_ino
        {
            unlinkat(parent, name + ".lock", 0)
        }
        Darwin.close(lock)
        Darwin.close(parent)
    }

    private static func read(_ parent: Int32, name: String) throws -> (
        SelectedIndexSnapshot, SnapshotFileStamp?
    ) {
        var before = stat()
        if fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ModelFailure.changed }
            return (SelectedIndexSnapshot(bytes: nil, mode: 0o644), nil)
        }
        guard before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), before.st_uid == getuid(),
            (0...(4 * 1024 * 1024)).contains(before.st_size)
        else { throw ModelFailure.changed }
        let value = try SelectedIndexSnapshot.read(parent: parent, name: name)
        var after = stat()
        guard fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
            SnapshotFileStamp(before) == SnapshotFileStamp(after)
        else { throw ModelFailure.changed }
        return (value, SnapshotFileStamp(after))
    }

    private static func sameNode(_ a: RepositoryNodeIdentity?, _ b: RepositoryNodeIdentity?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.device == b.device && a.inode == b.inode && a.kind == b.kind
            && a.bornSeconds == b.bornSeconds && a.bornNanoseconds == b.bornNanoseconds
    }

    @concurrent func install(_ bytes: Data) async throws {
        guard bytes.count <= 4 * 1024 * 1024 else { throw ModelFailure.changed }
        try await SnapshotIO.run { [self] cancellation in
            try location.validateIdentity()
            let current = try Self.read(parent, name: name)
            guard current.0 == snapshot, current.1 == originalStamp,
                try RepositoryNodeIdentity.readIfPresent(url) == original
            else { throw ModelFailure.changed }
            try RecoveryFileIO.write(bytes, descriptor: lock, cancellation: cancellation)
            guard fchmod(lock, snapshot.mode) == 0, fsync(lock) == 0 else {
                throw ProcessFailure.outputWrite(errno)
            }
            let lockURL = url.appendingPathExtension("lock")
            let prepared = try RepositoryNodeIdentity.read(lockURL)
            let copied = try Self.read(parent, name: name + ".lock")
            guard copied.0.bytes == bytes, copied.0.mode == snapshot.mode else { throw ModelFailure.changed }
            try cancellation.check()
            try location.validateIdentity()
            let fresh = try Self.read(parent, name: name)
            guard fresh.0 == snapshot, fresh.1 == originalStamp else { throw ModelFailure.changed }
            let action = snapshot.bytes == nil ? RENAME_EXCL : RENAME_SWAP
            guard renameatx_np(parent, name + ".lock", parent, name, UInt32(action)) == 0 else {
                throw ModelFailure.changed
            }
            installed = true
            if snapshot.bytes != nil {
                let held = try Self.read(parent, name: name + ".lock")
                let heldNode = try RepositoryNodeIdentity.read(lockURL)
                guard Self.sameNode(heldNode, original), held.0 == snapshot else {
                    let active = try Self.read(parent, name: name)
                    if Self.sameNode(try RepositoryNodeIdentity.read(url), prepared), active.0.bytes == bytes,
                        renameatx_np(parent, name + ".lock", parent, name, UInt32(RENAME_SWAP)) == 0
                    {
                        installed = false
                        throw ModelFailure.changed
                    }
                    throw ConfigurationWriteOutcomeUnknown(retainedInput: lockURL)
                }
            }
            let observed = try Self.read(parent, name: name)
            guard observed.0.bytes == bytes, observed.0.mode == snapshot.mode,
                Self.sameNode(try RepositoryNodeIdentity.read(url), prepared), fsync(parent) == 0
            else { throw ConfigurationWriteOutcomeUnknown(retainedInput: lockURL) }
        }
    }

    @concurrent func finish() async throws {
        try await SnapshotIO.run { [self] _ in
            try location.validateIdentity()
            guard installed else { throw ModelFailure.changed }
            if snapshot.bytes != nil {
                let lockURL = url.appendingPathExtension("lock")
                let held = try Self.read(parent, name: name + ".lock")
                guard Self.sameNode(try RepositoryNodeIdentity.readIfPresent(lockURL), original),
                    held.0 == snapshot,
                    unlinkat(parent, name + ".lock", 0) == 0, fsync(parent) == 0
                else { throw ConfigurationWriteOutcomeUnknown(retainedInput: lockURL) }
            }
        }
    }
}
