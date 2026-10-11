import CryptoKit
import Darwin
import Foundation

struct RepositoryNodeIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
    let kind: UInt16
    let bornSeconds: Int
    let bornNanoseconds: Int
    // A directory's timestamps change during normal Git writes. A .git file or symlink's
    // timestamps, however, must remain fixed: changing it can redirect commands elsewhere.
    let markerSize: Int64?
    let markerModifiedSeconds: Int?
    let markerModifiedNanoseconds: Int?
    let markerChangedSeconds: Int?
    let markerChangedNanoseconds: Int?

    static func read(_ url: URL, directory: Bool = false) throws -> RepositoryNodeIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ModelFailure.repositoryReplaced }
        let kind = info.st_mode & UInt16(S_IFMT)
        guard
            directory
                ? kind == UInt16(S_IFDIR)
                : [UInt16(S_IFDIR), UInt16(S_IFREG), UInt16(S_IFLNK)].contains(kind)
        else {
            throw ModelFailure.repositoryReplaced
        }
        let marker = kind != UInt16(S_IFDIR)
        return RepositoryNodeIdentity(
            device: info.st_dev, inode: info.st_ino, kind: kind,
            bornSeconds: info.st_birthtimespec.tv_sec, bornNanoseconds: info.st_birthtimespec.tv_nsec,
            markerSize: marker ? info.st_size : nil,
            markerModifiedSeconds: marker ? info.st_mtimespec.tv_sec : nil,
            markerModifiedNanoseconds: marker ? info.st_mtimespec.tv_nsec : nil,
            markerChangedSeconds: marker ? info.st_ctimespec.tv_sec : nil,
            markerChangedNanoseconds: marker ? info.st_ctimespec.tv_nsec : nil)
    }
}

extension RepositoryLocation {
    /// Stable across a directory move, different for a replacement at the same path.
    public var persistenceID: String {
        let parts = [rootIdentity, gitIdentity].map {
            "\($0.device):\($0.inode):\($0.bornSeconds):\($0.bornNanoseconds)"
        }.joined(separator: "|")
        return SHA256.hash(data: Data(parts.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func validateIdentity() throws {
        try Task.checkCancellation()
        guard try RepositoryNodeIdentity.read(root, directory: true) == rootIdentity,
            try RepositoryNodeIdentity.read(gitDirectory, directory: true) == gitIdentity,
            try RepositoryNodeIdentity.read(root.appending(path: ".git")) == markerIdentity
        else { throw ModelFailure.repositoryReplaced }
    }

    public func isSameRepository(as other: RepositoryLocation) -> Bool {
        rootIdentity == other.rootIdentity && gitIdentity == other.gitIdentity
    }
}
