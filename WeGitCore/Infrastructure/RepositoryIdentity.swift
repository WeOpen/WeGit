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

    static func readIfPresent(_ url: URL) throws -> RepositoryNodeIdentity? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw ModelFailure.repositoryReplaced }
            return nil
        }
        return try read(url)
    }

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
        let identities = [rootIdentity, gitIdentity] + (isLinkedWorktree ? [commonIdentity] : [])
        let parts = identities.map {
            "\($0.device):\($0.inode):\($0.bornSeconds):\($0.bornNanoseconds)"
        }.joined(separator: "|")
        return SHA256.hash(data: Data(parts.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func validateIdentity() throws {
        try Task.checkCancellation()
        guard try RepositoryNodeIdentity.read(root, directory: true) == rootIdentity,
            try RepositoryNodeIdentity.read(gitDirectory, directory: true) == gitIdentity,
            try RepositoryNodeIdentity.read(root.appending(path: ".git")) == markerIdentity,
            try RepositoryNodeIdentity.read(commonDirectory, directory: true) == commonIdentity,
            try RepositoryNodeIdentity.readIfPresent(gitDirectory.appending(path: "commondir"))
                == commonMarkerIdentity,
            try RepositoryNodeIdentity.readIfPresent(gitDirectory.appending(path: "gitdir"))
                == worktreeLinkIdentity
        else { throw ModelFailure.repositoryReplaced }
    }

    public func isSameRepository(as other: RepositoryLocation) -> Bool {
        rootIdentity == other.rootIdentity && gitIdentity == other.gitIdentity
            && commonIdentity == other.commonIdentity
    }

    /// Check Git's textual redirects when opening, then pin their node identities.
    /// Embedded newlines are valid path bytes; only Git's final newline is removed.
    func validateLayout() throws {
        func pointer(_ file: URL, relativeTo base: URL, prefix: String = "") throws -> URL {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 8193) ?? Data()
            guard bytes.count <= 8192, let text = String(data: bytes, encoding: .utf8),
                text.hasPrefix(prefix)
            else { throw ModelFailure.repositoryReplaced }
            let path = String(text.dropFirst(prefix.count)).removingLastNewline
            guard !path.isEmpty, !path.contains("\0") else { throw ModelFailure.repositoryReplaced }
            return URL(fileURLWithPath: path, relativeTo: base).resolvingSymlinksInPath()
        }
        let marker = root.appending(path: ".git").resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: marker.path, isDirectory: &directory) else {
            throw ModelFailure.repositoryReplaced
        }
        let actualGit =
            directory.boolValue ? marker : try pointer(marker, relativeTo: root, prefix: "gitdir: ")
        guard actualGit.path == gitDirectory.path else { throw ModelFailure.repositoryReplaced }
        if commonMarkerIdentity != nil {
            guard
                try pointer(gitDirectory.appending(path: "commondir"), relativeTo: gitDirectory).path
                    == commonDirectory.path
            else { throw ModelFailure.repositoryReplaced }
        } else if isLinkedWorktree {
            throw ModelFailure.repositoryReplaced
        }
        if isLinkedWorktree {
            guard worktreeLinkIdentity != nil,
                try pointer(gitDirectory.appending(path: "gitdir"), relativeTo: gitDirectory).path
                    == marker.path
            else { throw ModelFailure.repositoryReplaced }
        }
        try validateIdentity()
    }
}
