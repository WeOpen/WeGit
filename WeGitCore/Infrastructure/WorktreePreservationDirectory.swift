import Darwin
import Foundation

/// All working files stay in this same-volume directory. Git only retires its
/// now-missing checkout path; it never receives the path containing saved files.
final class WorktreePreservationDirectory: @unchecked Sendable {
    let url: URL
    private let descriptor: Int32
    private let identity: RepositoryNodeIdentity
    var checkout: URL { url.appending(path: "checkout", directoryHint: .isDirectory) }
    var files: URL { url.appending(path: "files", directoryHint: .isDirectory) }

    init(parent: URL) throws {
        let parentIdentity = try RepositoryNodeIdentity.read(parent, directory: true)
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw ModelFailure.changed }
        defer { Darwin.close(parentFD) }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0,
            parentInfo.st_dev == parentIdentity.device, parentInfo.st_ino == parentIdentity.inode,
            parentInfo.st_birthtimespec.tv_sec == parentIdentity.bornSeconds,
            parentInfo.st_birthtimespec.tv_nsec == parentIdentity.bornNanoseconds
        else { throw ModelFailure.changed }
        let name = ".WeGit-worktree-" + UUID().uuidString
        guard mkdirat(parentFD, name, 0o700) == 0 else { throw ModelFailure.changed }
        let value = parent.appending(path: name, directoryHint: .isDirectory)
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        do {
            guard try RepositoryNodeIdentity.read(parent, directory: true) == parentIdentity else {
                throw ModelFailure.changed
            }
            identity = try RepositoryNodeIdentity.read(value, directory: true)
            url = value
            descriptor = fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }
    deinit { Darwin.close(descriptor) }

    func validate() throws {
        guard try RepositoryNodeIdentity.read(url, directory: true) == identity else {
            throw ModelFailure.changed
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode,
            info.st_birthtimespec.tv_sec == identity.bornSeconds,
            info.st_birthtimespec.tv_nsec == identity.bornNanoseconds
        else { throw ModelFailure.changed }
    }

    func preserve(_ location: RepositoryLocation) throws {
        try validate()
        try location.validateIdentity()
        guard location.root.path == checkout.path,
            try RepositoryNodeIdentity.readIfPresent(files) == nil
        else { throw ModelFailure.changed }
        // Never replace even an empty foreign directory that arrived after validation.
        guard renameatx_np(descriptor, "checkout", descriptor, "files", UInt32(RENAME_EXCL)) == 0 else {
            throw ModelFailure.changed
        }
        guard try RepositoryNodeIdentity.read(files, directory: true) == location.rootIdentity else {
            throw ModelFailure.changed
        }
    }

    func validateMissingCheckout() throws {
        try validate()
        var info = stat()
        guard fstatat(descriptor, "checkout", &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw ModelFailure.changed
        }
    }

    var recoveryURL: URL {
        let actual = Self.path(for: descriptor, fallback: url)
        if FileManager.default.fileExists(atPath: actual.appending(path: "files").path) {
            return actual.appending(path: "files", directoryHint: .isDirectory)
        }
        if FileManager.default.fileExists(atPath: actual.appending(path: "checkout").path) {
            return actual.appending(path: "checkout", directoryHint: .isDirectory)
        }
        return actual
    }

    static func pin(_ location: RepositoryLocation) throws -> Int32 {
        try location.validateIdentity()
        let fd = Darwin.open(location.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        var info = stat()
        guard fstat(fd, &info) == 0,
            info.st_dev == location.rootIdentity.device, info.st_ino == location.rootIdentity.inode,
            info.st_birthtimespec.tv_sec == location.rootIdentity.bornSeconds,
            info.st_birthtimespec.tv_nsec == location.rootIdentity.bornNanoseconds
        else {
            Darwin.close(fd)
            throw ModelFailure.changed
        }
        return fd
    }

    static func path(for descriptor: Int32, fallback: URL) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
        guard result == 0 else { return fallback }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
    }
}
