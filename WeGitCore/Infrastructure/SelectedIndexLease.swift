import Darwin
import Foundation

/// An index snapshot is anchored to the opened worktree's Git directory.
struct SelectedIndexSnapshot: Sendable, Equatable {
    let bytes: Data?
    let mode: mode_t

    static func read(location: RepositoryLocation) throws -> Self {
        try location.validateIdentity()
        let parent = try openDirectory(location)
        defer { Darwin.close(parent) }
        return try read(parent: parent)
    }

    static func openDirectory(_ location: RepositoryLocation) throws -> Int32 {
        let parent = Darwin.open(location.gitDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ModelFailure.repositoryReplaced }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_dev == location.gitIdentity.device,
            info.st_ino == location.gitIdentity.inode,
            info.st_birthtimespec.tv_sec == location.gitIdentity.bornSeconds,
            info.st_birthtimespec.tv_nsec == location.gitIdentity.bornNanoseconds
        else {
            Darwin.close(parent)
            throw ModelFailure.repositoryReplaced
        }
        return parent
    }

    static func read(parent: Int32) throws -> Self {
        let fd = openat(parent, "index", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw ModelFailure.changed }
            return Self(bytes: nil, mode: 0o644)
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            before.st_size >= 0, before.st_size <= 32 * 1024 * 1024
        else { throw ModelFailure.changed }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ModelFailure.changed }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= 32 * 1024 * 1024 else { throw ModelFailure.changed }
        }
        var after = stat()
        var named = stat()
        guard fstat(fd, &after) == 0, fstatat(parent, "index", &named, AT_SYMLINK_NOFOLLOW) == 0,
            SnapshotFileStamp(before) == SnapshotFileStamp(after),
            SnapshotFileStamp(after) == SnapshotFileStamp(named),
            before.st_dev == named.st_dev, before.st_ino == named.st_ino,
            bytes.count == before.st_size
        else { throw ModelFailure.changed }
        return Self(bytes: bytes, mode: mode_t(before.st_mode & 0o777))
    }
}

/// The standard Git lock blocks other conforming writers until the verified candidate is installed.
final class SelectedIndexLease: @unchecked Sendable {
    private let parent: Int32
    private let descriptor: Int32
    private let snapshot: SelectedIndexSnapshot

    init(location: RepositoryLocation, snapshot: SelectedIndexSnapshot) throws {
        try location.validateIdentity()
        let parent = try SelectedIndexSnapshot.openDirectory(location)
        let lock = openat(parent, "index.lock", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            Darwin.close(parent)
            throw ModelFailure.changed
        }
        self.parent = parent
        descriptor = lock
        self.snapshot = snapshot
    }

    deinit {
        var actual = stat()
        var owned = stat()
        if fstat(descriptor, &owned) == 0,
            fstatat(parent, "index.lock", &actual, AT_SYMLINK_NOFOLLOW) == 0,
            owned.st_dev == actual.st_dev, owned.st_ino == actual.st_ino
        {
            unlinkat(parent, "index.lock", 0)
        }
        Darwin.close(descriptor)
        Darwin.close(parent)
    }

    func verify() throws {
        guard try SelectedIndexSnapshot.read(parent: parent) == snapshot else { throw ModelFailure.changed }
        var actual = stat()
        var owned = stat()
        guard fstat(descriptor, &owned) == 0,
            fstatat(parent, "index.lock", &actual, AT_SYMLINK_NOFOLLOW) == 0,
            owned.st_dev == actual.st_dev, owned.st_ino == actual.st_ino
        else { throw ModelFailure.changed }
    }

    func write(_ data: Data) throws {
        try verify()
        guard data.count <= 32 * 1024 * 1024 else { throw ModelFailure.changed }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(
                    descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ProcessFailure.outputWrite(errno) }
                offset += count
            }
        }
        guard fchmod(descriptor, snapshot.mode) == 0, fsync(descriptor) == 0 else {
            throw ProcessFailure.outputWrite(errno)
        }
        try verify()
    }

    func install() throws {
        try verify()
        try Task.checkCancellation()
        guard renameat(parent, "index.lock", parent, "index") == 0 else {
            throw ProcessFailure.outputWrite(errno)
        }
    }
}
