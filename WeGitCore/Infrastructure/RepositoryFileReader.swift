import Darwin
import Foundation

/// A read-only batch pins one root and validates the repository redirects on both
/// boundaries. Per-file readers still check their parents, entry and descriptor.
/// The batch cannot expose its result until validate() succeeds after all reads.
final class RepositoryReadFence: @unchecked Sendable {
    private let location: RepositoryLocation
    private let root: Int32
    init(location: RepositoryLocation) throws {
        self.location = location
        root = try WorktreePreservationDirectory.pin(location)
    }
    deinit { Darwin.close(root) }

    func openRoot(for location: RepositoryLocation) throws -> Int32 {
        guard self.location == location else { throw ModelFailure.changed }
        try validateRoot()
        let descriptor = fcntl(root, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw ProcessFailure.outputWrite(errno) }
        return descriptor
    }
    func validateRoot() throws {
        var info = stat()
        guard fstat(root, &info) == 0, info.st_dev == location.rootIdentity.device,
            info.st_ino == location.rootIdentity.inode,
            info.st_birthtimespec.tv_sec == location.rootIdentity.bornSeconds,
            info.st_birthtimespec.tv_nsec == location.rootIdentity.bornNanoseconds
        else { throw ModelFailure.repositoryReplaced }
    }
    func validate() throws {
        try location.validateIdentity()
        try validateRoot()
    }
}

/// A worktree read is anchored at the opened repository directory. Every intermediate
/// component must be a real directory; a final symlink is read as link text, never followed.
/// Only a constant number of descriptors is held, even for deep paths.
final class RepositoryFileReader {
    private struct DirectoryStamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let bornSeconds: Int
        let bornNanoseconds: Int
        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            bornSeconds = info.st_birthtimespec.tv_sec
            bornNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }

    private let location: RepositoryLocation
    private let root: Int32
    private let parent: Int32
    private let descriptor: Int32?
    private let folders: [String]
    private let folderIdentities: [DirectoryStamp]
    private let name: String
    private let stamp: SnapshotFileStamp
    private let stampMode: UInt16
    private let cancellation: IOCancellation
    private let readFence: RepositoryReadFence?
    let symbolicLink: Bool
    var mode: UInt16 { UInt16(stampMode) }
    var size: Int64 { stamp.size }
    var version: SnapshotFileStamp { stamp }
    var directoryIdentities: [ConflictEditorDirectoryIdentity] {
        folderIdentities.map {
            ConflictEditorDirectoryIdentity(
                device: UInt64($0.device), inode: UInt64($0.inode),
                bornSeconds: Int64($0.bornSeconds), bornNanoseconds: Int64($0.bornNanoseconds))
        }
    }

    init(
        location: RepositoryLocation, path: String, cancellation: IOCancellation, openContents: Bool = true,
        readFence: RepositoryReadFence? = nil
    )
        throws
    {
        try cancellation.check()
        if readFence == nil { try location.validateIdentity() }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else {
            throw ModelFailure.invalidPath
        }
        let components = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard let last = components.last, !components.contains("..") else { throw ModelFailure.invalidPath }
        let rootFD =
            try readFence?.openRoot(for: location)
            ?? Darwin.open(location.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ModelFailure.repositoryReplaced }
        var parentFD = rootFD
        var fileFD: Int32?
        var transferred = false
        defer {
            if !transferred {
                if let fileFD { Darwin.close(fileFD) }
                if parentFD != rootFD { Darwin.close(parentFD) }
                Darwin.close(rootFD)
            }
        }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0,
            rootInfo.st_dev == location.rootIdentity.device, rootInfo.st_ino == location.rootIdentity.inode,
            rootInfo.st_birthtimespec.tv_sec == location.rootIdentity.bornSeconds,
            rootInfo.st_birthtimespec.tv_nsec == location.rootIdentity.bornNanoseconds
        else { throw ModelFailure.repositoryReplaced }
        let folders = Array(components.dropLast())
        var identities: [DirectoryStamp] = []
        for folder in folders {
            try cancellation.check()
            let next = openat(parentFD, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ModelFailure.invalidPath }
            var info = stat()
            if fstat(next, &info) != 0 {
                Darwin.close(next)
                throw ModelFailure.changed
            }
            identities.append(DirectoryStamp(info))
            if parentFD != rootFD { Darwin.close(parentFD) }
            parentFD = next
        }
        var info = stat()
        guard fstatat(parentFD, last, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_size >= 0 else {
            throw ModelFailure.changed
        }
        let kind = info.st_mode & UInt16(S_IFMT)
        guard kind == UInt16(S_IFREG) || kind == UInt16(S_IFLNK) else {
            throw ModelFailure.unsupported(L10n.text("此文件类型不支持文本预览。"))
        }
        if kind == UInt16(S_IFREG) && openContents {
            let fd = openat(parentFD, last, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw ModelFailure.changed }
            fileFD = fd
            var opened = stat()
            guard fstat(fd, &opened) == 0, SnapshotFileStamp(opened) == SnapshotFileStamp(info) else {
                throw ModelFailure.changed
            }
        }
        self.location = location
        root = rootFD
        parent = parentFD
        descriptor = fileFD
        self.folders = folders
        folderIdentities = identities
        name = last
        stamp = SnapshotFileStamp(info)
        stampMode = UInt16(info.st_mode & UInt16(0o777))
        symbolicLink = kind == UInt16(S_IFLNK)
        self.cancellation = cancellation
        self.readFence = readFence
        transferred = true
    }

    deinit {
        if let descriptor { Darwin.close(descriptor) }
        if parent != root { Darwin.close(parent) }
        Darwin.close(root)
    }

    func read(limit: Int, consume: (Data) throws -> Void) throws {
        try cancellation.check()
        guard limit > 0, size <= limit else { throw ProcessFailure.outputLimit }
        if symbolicLink {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = readlinkat(parent, name, &bytes, bytes.count)
            guard count >= 0 else { throw ModelFailure.changed }
            guard count < bytes.count, count <= limit else { throw ProcessFailure.outputLimit }
            try consume(bytes.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: count) })
        } else if let descriptor {
            guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw ModelFailure.changed }
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            var total = 0
            while true {
                try cancellation.check()
                var count: Int
                repeat {
                    count = Darwin.read(descriptor, &bytes, bytes.count)
                } while count < 0 && errno == EINTR
                guard count >= 0 else {
                    throw ModelFailure.unsupported(L10n.text("读取文件失败，请检查权限和磁盘状态（\(errno)）。"))
                }
                if count == 0 { break }
                guard count <= limit - total else { throw ProcessFailure.outputLimit }
                try consume(bytes.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: count) })
                total += count
            }
            guard total == size else { throw ModelFailure.changed }
        } else {
            throw ModelFailure.unsupported(L10n.text("此文件未以内容读取模式打开。"))
        }
        try validate()
    }

    /// APFS clones preserve a point-in-time byte snapshot without materializing
    /// another full copy. Other filesystems keep the bounded streaming path.
    func clone(to directory: SnapshotDirectory, name: String) throws -> Bool {
        guard !symbolicLink, let descriptor else { return false }
        try validate()
        try directory.validate()
        try cancellation.check()
        let parent = Darwin.open(directory.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ModelFailure.changed }
        defer { Darwin.close(parent) }
        if fclonefileat(descriptor, parent, name, UInt32(CLONE_NOOWNERCOPY)) != 0 {
            if [EXDEV, ENOTSUP, EINVAL].contains(errno) { return false }
            throw ProcessFailure.outputWrite(errno)
        }
        try validate()
        try directory.validate()
        try cancellation.check()
        return true
    }

    func validate() throws {
        try cancellation.check()
        if let readFence { try readFence.validateRoot() } else { try location.validateIdentity() }
        var current = root
        defer { if current != root { Darwin.close(current) } }
        for (index, folder) in folders.enumerated() {
            try cancellation.check()
            let next = openat(current, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ModelFailure.changed }
            var info = stat()
            guard fstat(next, &info) == 0, DirectoryStamp(info) == folderIdentities[index] else {
                Darwin.close(next)
                throw ModelFailure.changed
            }
            if current != root { Darwin.close(current) }
            current = next
        }
        var named = stat()
        guard fstatat(current, name, &named, AT_SYMLINK_NOFOLLOW) == 0, SnapshotFileStamp(named) == stamp
        else {
            throw ModelFailure.changed
        }
        if let descriptor {
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, SnapshotFileStamp(opened) == stamp else {
                throw ModelFailure.changed
            }
        }
    }

    func containsOriginalEntry() -> Bool {
        var info = stat()
        return fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            && info.st_dev == stamp.device && info.st_ino == stamp.inode
    }
}
