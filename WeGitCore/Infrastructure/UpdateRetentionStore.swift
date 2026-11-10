import CryptoKit
import Darwin
import Foundation

struct UpdateRetentionTree: Equatable, Codable, Sendable {
    struct File: Equatable, Codable, Sendable {
        let node: RepositoryNodeIdentity
        let mode: UInt16
        let bytes: Int64
        let sha256: String?
    }
    let root: UpdateNodeIdentity
    let directories: [String: UpdateNodeIdentity]
    let files: [String: File]
    let bytes: Int64

    static func read(_ root: URL, hashing: Bool, cancellation: IOCancellation) throws -> Self {
        let identity = try UpdateNodeIdentity.read(root, directory: true)
        guard identity.owner == getuid(), identity.permissions == 0o700 else { throw UpdateFailure.changed }
        var directories: [String: UpdateNodeIdentity] = [:]
        var files: [String: File] = [:]
        var total: Int64 = 0
        var failed = false
        guard
            let iterator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                errorHandler: { _, _ in
                    failed = true
                    return false
                })
        else { throw UpdateFailure.changed }
        for case let url as URL in iterator {
            try cancellation.check()
            guard directories.count + files.count < 10_000 else { throw UpdateFailure.exceeded }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard valid(relative) else { throw UpdateFailure.changed }
            var value = stat()
            guard lstat(url.path, &value) == 0, value.st_uid == getuid() else { throw UpdateFailure.changed }
            if value.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) {
                directories[relative] = try UpdateNodeIdentity.read(url, directory: true)
                continue
            }
            guard value.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), value.st_size >= 0,
                value.st_size <= 1024 * 1024 * 1024 - total
            else { throw UpdateFailure.exceeded }
            let node = try RepositoryNodeIdentity.read(url)
            let checksum: String?
            if hashing {
                let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw UpdateFailure.changed }
                defer { close(descriptor) }
                let before = SnapshotFileStamp(value)
                var current = stat()
                guard fstat(descriptor, &current) == 0, SnapshotFileStamp(current) == before else {
                    throw UpdateFailure.changed
                }
                var hash = SHA256()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                var count: Int64 = 0
                while true {
                    try cancellation.check()
                    let readCount = Darwin.read(descriptor, &buffer, buffer.count)
                    if readCount < 0, errno == EINTR { continue }
                    guard readCount >= 0 else { throw UpdateFailure.changed }
                    if readCount == 0 { break }
                    count += Int64(readCount)
                    guard count <= value.st_size else { throw UpdateFailure.changed }
                    hash.update(data: Data(buffer.prefix(readCount)))
                }
                guard count == value.st_size, fstat(descriptor, &current) == 0,
                    SnapshotFileStamp(current) == before
                else { throw UpdateFailure.changed }
                checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
            } else {
                checksum = nil
            }
            total += value.st_size
            files[relative] = File(
                node: node, mode: value.st_mode & 0o777, bytes: value.st_size, sha256: checksum)
        }
        guard !failed, try UpdateNodeIdentity.read(root, directory: true) == identity else {
            throw UpdateFailure.changed
        }
        for (path, value) in directories {
            guard try UpdateNodeIdentity.read(root.appending(path: path), directory: true) == value else {
                throw UpdateFailure.changed
            }
        }
        for (path, value) in files {
            guard try RepositoryNodeIdentity.read(root.appending(path: path)) == value.node else {
                throw UpdateFailure.changed
            }
        }
        return Self(root: identity, directories: directories, files: files, bytes: total)
    }

    func fingerprint(_ prefix: String) throws -> UpdateAppFingerprint? {
        guard let root = directories[prefix] else { return nil }
        let base = prefix + "/"
        func node(_ value: UpdateNodeIdentity) throws -> RepositoryNodeIdentity {
            guard let device = Int32(exactly: value.device), value.kind == UInt16(S_IFDIR) else {
                throw UpdateFailure.changed
            }
            return RepositoryNodeIdentity(
                device: device, inode: value.inode, kind: value.kind,
                bornSeconds: Int(value.bornSeconds), bornNanoseconds: Int(value.bornNanoseconds),
                markerSize: nil, markerModifiedSeconds: nil, markerModifiedNanoseconds: nil,
                markerChangedSeconds: nil, markerChangedNanoseconds: nil)
        }
        var mappedFiles: [String: UpdateAppFile] = [:]
        var mappedDirectories: [String: RepositoryNodeIdentity] = [:]
        var bytes: Int64 = 0
        for (path, value) in files where path.hasPrefix(base) {
            guard let sha = value.sha256 else { throw UpdateFailure.changed }
            mappedFiles[String(path.dropFirst(base.count))] = UpdateAppFile(
                identity: value.node, hash: sha, mode: value.mode)
            bytes += value.bytes
        }
        for (path, value) in directories where path.hasPrefix(base) {
            mappedDirectories[String(path.dropFirst(base.count))] = try node(value)
        }
        return try UpdateAppFingerprint.capture(
            tree: UpdateAppTree(
                root: node(root), files: mappedFiles,
                bytes: bytes, directories: mappedDirectories), root: root)
    }

    static func valid(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

}

struct UpdatePreparationRecord: Codable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let bytes: Int64
        let sha256: String
    }
    let format: Int
    let id: UUID
    let created: Date
    let scope: UpdateHandoffScope
    let target: URL
    let parentIdentity: UpdateNodeIdentity
    let storageIdentity: UpdateNodeIdentity
    let source: UpdateProcessIdentity
    let signedManifest: Data
    let packageManifest: Data
    let installedVersion: String
    let installedBuild: UInt64
    let installedVariant: UpdateVariant
    let oldApp: UpdateAppFingerprint
    var files: [String: File]
    var directories: Set<String>

    func matches(_ tree: UpdateRetentionTree) -> Bool {
        let metadata: Set<String> = [
            "archive.dmg", "package-manifest.json", "original-preferences.plist",
            "current-preferences.plist", "current-store-backup.plist", "request.json", "journal.json",
        ]
        let prefixes = ["Replacement.app/", "Installer/Resources/WeGit_WeGitCore.bundle/"]
        guard
            files.keys.allSatisfy({
                UpdateRetentionTree.valid($0)
                    && (metadata.contains($0)
                        || $0 == "Installer/Helpers/WeGitUpdater" || prefixes.contains(where: $0.hasPrefix))
            }),
            directories.allSatisfy({
                UpdateRetentionTree.valid($0)
                    && ([
                        "Replacement.app", "Installer",
                        "Installer/Helpers", "Installer/Resources",
                        "Installer/Resources/WeGit_WeGitCore.bundle",
                    ].contains($0)
                        || prefixes.contains(where: $0.hasPrefix))
            }),
            files.count + directories.count <= 10_000,
            tree.root == storageIdentity, Set(tree.directories.keys).isSubset(of: directories),
            Set(tree.files.keys).isSubset(of: Set(files.keys).union(["lock", "preparation.json"]))
        else { return false }
        for (path, actual) in tree.files where path != "lock" && path != "preparation.json" {
            guard let expected = files[path], expected.bytes == actual.bytes, expected.sha256 == actual.sha256
            else { return false }
        }
        return tree.files["ticket.json"] == nil && tree.files["lock"]?.bytes == 0
            && tree.files["lock"]?.mode == 0o600
    }
}

struct UpdateRetentionAuthorization: Codable, Sendable {
    let signedManifest: Data
    let installedVersion: String
    let installedBuild: UInt64
    let installedVariant: UpdateVariant
    let created: Date
    let helper: UpdateProcessIdentity?
    let evidence: [String: Data]
}

struct UpdateCleanupProgress: Codable, Sendable {
    let format: Int
    let entry: UpdateRetentionEntry
    let target: URL
    let scope: UpdateHandoffScope
    let parent: UpdateNodeIdentity
    let tree: UpdateRetentionTree
    let binding: String
    let authorization: UpdateRetentionAuthorization
    var deleted: Set<String>
    var pending: String?
    var rootRemoved: Bool

    var url: URL {
        target.deletingLastPathComponent().appending(path: ".WeGit-cleanup-" + entry.id + ".json")
    }
    var orderedPaths: [String] {
        let metadata: Set<String> = [
            "ticket.json", "request.json", "journal.json", "preparation.json", "lock",
        ]
        let content = tree.files.keys.filter { !metadata.contains($0) }.sorted()
        let directories = tree.directories.keys.sorted { a, b in
            a.count == b.count ? a < b : a.count > b.count
        }
        return content + directories + tree.files.keys.filter { metadata.contains($0) }.sorted()
    }

    mutating func save() throws {
        let data = try encoded()
        guard data.count <= 4 * 1024 * 1024 else { throw UpdateFailure.exceeded }
        let temporary = url.deletingLastPathComponent().appending(
            path: ".WeGit-cleanup-write-" + UUID().uuidString)
        try UpdateInstaller.exclusiveWrite(data, to: temporary)
        guard rename(temporary.path, url.path) == 0 else { throw UpdateFailure.changed }
        try UpdateInstaller.sync(url.deletingLastPathComponent())
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(self)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["deleted"] = deleted.sorted()
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    func validateRemaining(cancellation: IOCancellation) throws -> UpdateRetentionTree? {
        guard format == 1,
            entry.directory.deletingLastPathComponent().path == target.deletingLastPathComponent().path,
            entry.directory.lastPathComponent == ".WeGit-update-" + entry.id,
            UUID(uuidString: entry.id) != nil,
            tree.directories.count + tree.files.count <= 10_000,
            tree.files.keys.allSatisfy(UpdateRetentionTree.valid),
            tree.directories.keys.allSatisfy(UpdateRetentionTree.valid),
            tree.files.keys.allSatisfy({ tree.directories[$0] == nil }),
            tree.files.values.allSatisfy({
                $0.bytes >= 0 && $0.bytes <= 1024 * 1024 * 1024 && $0.sha256?.count == 64
            }),
            Set(orderedPaths).count == orderedPaths.count,
            deleted.isSubset(of: Set(orderedPaths)),
            pending == nil || pending == "/" || orderedPaths.contains(pending!),
            try UpdateNodeIdentity.read(target.deletingLastPathComponent(), directory: true) == parent
        else { throw UpdateFailure.changed }
        // Deletions form a prefix. Only the single persisted pending operation
        // may be missing without a completed-deletion acknowledgement.
        let order = orderedPaths
        guard Set(order.prefix(deleted.count)) == deleted,
            pending == nil
                || (pending == "/"
                    ? deleted.count == order.count : pending == order.dropFirst(deleted.count).first)
        else { throw UpdateFailure.changed }
        if try RepositoryNodeIdentity.readIfPresent(entry.directory) == nil {
            guard deleted.count == order.count, pending == "/" || rootRemoved else {
                throw UpdateFailure.changed
            }
            return nil
        }
        guard !rootRemoved else { throw UpdateFailure.changed }
        let current = try UpdateRetentionTree.read(entry.directory, hashing: true, cancellation: cancellation)
        guard current.root == tree.root else { throw UpdateFailure.changed }
        var absent = deleted
        if let pending, pending != "/", current.files[pending] == nil, current.directories[pending] == nil {
            absent.insert(pending)
        }
        guard current.files == tree.files.filter({ !absent.contains($0.key) }),
            current.directories == tree.directories.filter({ !absent.contains($0.key) })
        else { throw UpdateFailure.changed }
        return current
    }
    mutating func execute(cancellation: IOCancellation) throws {
        _ = try validateRemaining(cancellation: cancellation)
        if let pending, pending != "/" {
            let missing =
                try RepositoryNodeIdentity.readIfPresent(entry.directory.appending(path: pending)) == nil
            if pending != "/", missing {
                deleted.insert(pending)
                self.pending = nil
                try save()
            }
        }
        for path in orderedPaths where !deleted.contains(path) {
            try cancellation.check()
            pending = path
            try save()
            try remove(path)
            deleted.insert(path)
            pending = nil
            try save()
        }
        try cancellation.check()
        pending = "/"
        try save()
        if try RepositoryNodeIdentity.readIfPresent(entry.directory) != nil {
            guard try UpdateNodeIdentity.read(entry.directory, directory: true) == tree.root,
                rmdir(entry.directory.path) == 0
            else { throw UpdateFailure.changed }
            try UpdateInstaller.sync(entry.directory.deletingLastPathComponent())
        }
        rootRemoved = true
        try save()
        // A crash after rmdir still leaves this parent-side intent available.
        // Removing it is the final operation after no retained payload remains.
        guard try RepositoryNodeIdentity.readIfPresent(entry.directory) == nil,
            try UpdateInstaller.readSmall(url, limit: 4 * 1024 * 1024) == encoded(), unlink(url.path) == 0
        else { throw UpdateFailure.changed }
        try UpdateInstaller.sync(url.deletingLastPathComponent())
    }
    private func remove(_ path: String) throws {
        let rootFD = open(entry.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw UpdateFailure.changed }
        defer { close(rootFD) }
        var actual = stat()
        guard fstat(rootFD, &actual) == 0, matches(actual, tree.root) else { throw UpdateFailure.changed }
        let parts = path.split(separator: "/").map(String.init)
        var parent = dup(rootFD)
        guard parent >= 0 else { throw UpdateFailure.changed }
        defer { close(parent) }
        var relative = ""
        for part in parts.dropLast() {
            relative = relative.isEmpty ? part : relative + "/" + part
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw UpdateFailure.changed }
            close(parent)
            parent = next
            guard fstat(parent, &actual) == 0, let expected = tree.directories[relative],
                matches(actual, expected)
            else { throw UpdateFailure.changed }
        }
        let leaf = parts.last!
        guard fstatat(parent, leaf, &actual, AT_SYMLINK_NOFOLLOW) == 0 else { throw UpdateFailure.changed }
        if let expected = tree.files[path] {
            guard actual.st_dev == expected.node.device, actual.st_ino == expected.node.inode,
                actual.st_size == expected.bytes, actual.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                actual.st_mode & 0o777 == expected.mode,
                actual.st_mtimespec.tv_sec == expected.node.markerModifiedSeconds,
                actual.st_mtimespec.tv_nsec == expected.node.markerModifiedNanoseconds,
                actual.st_ctimespec.tv_sec == expected.node.markerChangedSeconds,
                actual.st_ctimespec.tv_nsec == expected.node.markerChangedNanoseconds,
                unlinkat(parent, leaf, 0) == 0
            else { throw UpdateFailure.changed }
        } else {
            guard let expected = tree.directories[path], matches(actual, expected),
                unlinkat(parent, leaf, AT_REMOVEDIR) == 0
            else { throw UpdateFailure.changed }
        }
        guard fsync(parent) == 0 else { throw UpdateFailure.changed }
    }
    private func matches(_ actual: stat, _ expected: UpdateNodeIdentity) -> Bool {
        actual.st_ino == expected.inode && Int64(actual.st_dev) == expected.device
            && actual.st_birthtimespec.tv_sec == expected.bornSeconds
            && actual.st_birthtimespec.tv_nsec == expected.bornNanoseconds
            && actual.st_uid == expected.owner && actual.st_mode & 0o777 == expected.permissions
            && actual.st_mode & UInt16(S_IFMT) == expected.kind
    }
}
