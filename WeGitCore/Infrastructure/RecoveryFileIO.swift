import CryptoKit
import Darwin
import Foundation

struct RecoveryFileCapture: Sendable {
    let file: RecoveryFile
    let snapshot: SnapshotFile?
    let version: SnapshotFileStamp?
    let parents: [ConflictEditorDirectoryIdentity]
    let missingParent: String?
    func matches(_ other: Self) -> Bool {
        file.path == other.file.path && file.kind == other.file.kind && file.mode == other.file.mode
            && file.bytes == other.file.bytes && file.sha256 == other.file.sha256
            && version == other.version && parents == other.parents && missingParent == other.missingParent
    }
}

enum RecoveryFileIO {
    @concurrent static func verify(_ capture: RecoveryFileCapture, location: RepositoryLocation) async throws
    {
        try await SnapshotIO.run { cancellation in
            try cancellation.check()
            let parent = try Parent(location: location, path: capture.file.path)
            let missing = try parent.probe()
            guard parent.identities == capture.parents, missing == capture.missingParent else {
                throw ModelFailure.changed
            }
            if let expected = capture.version {
                let reader = try RepositoryFileReader(
                    location: location, path: capture.file.path,
                    cancellation: cancellation, openContents: false)
                guard reader.version == expected, reader.mode == capture.file.mode else {
                    throw ModelFailure.changed
                }
                try reader.validate()
            }
            try location.validateIdentity()
        }
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
            !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git"
            })
        else { throw ModelFailure.invalidPath }
    }

    @concurrent static func capture(
        location: RepositoryLocation, path: String, name: String, storage: SnapshotDirectory? = nil
    )
        async throws -> RecoveryFileCapture
    {
        try await SnapshotIO.run { cancellation in
            try validate(path)
            try cancellation.check()
            let parent = try Parent(location: location, path: path)
            let missing = try parent.probe()
            if let missing {
                return RecoveryFileCapture(
                    file: RecoveryFile(
                        path: path, kind: .absent, mode: 0o644, bytes: 0, sha256: nil, storageName: name),
                    snapshot: nil, version: nil, parents: parent.identities, missingParent: missing)
            }
            let directory = try storage ?? SnapshotDirectory()
            let url = directory.url.appending(path: name)
            let descriptor = Darwin.open(
                url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw ProcessFailure.outputWrite(errno) }
            defer { Darwin.close(descriptor) }
            let reader = try RepositoryFileReader(location: location, path: path, cancellation: cancellation)
            var digest = SHA256()
            try reader.read(limit: RecoveryBudget.bytes) { data in
                digest.update(data: data)
                try write(data, descriptor: descriptor, cancellation: cancellation)
            }
            guard fsync(descriptor) == 0 else { throw ProcessFailure.outputWrite(errno) }
            return RecoveryFileCapture(
                file: RecoveryFile(
                    path: path, kind: reader.symbolicLink ? .symbolicLink : .file,
                    mode: reader.mode, bytes: Int(reader.size),
                    sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(), storageName: name),
                snapshot: try SnapshotFile(directory: directory, url: url), version: reader.version,
                parents: parent.identities, missingParent: nil)
        }
    }

    static func write(_ data: Data, descriptor: Int32, cancellation: IOCancellation) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try cancellation.check()
                let count = Darwin.write(
                    descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ProcessFailure.outputWrite(errno) }
                offset += count
            }
        }
    }

    static func copy(_ source: SnapshotFile, to descriptor: Int32, cancellation: IOCancellation) throws
        -> String
    {
        let input = try source.open()
        defer { Darwin.close(input) }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total = 0
        while true {
            try cancellation.check()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ProcessFailure.outputWrite(errno) }
            if count == 0 { break }
            let bytes = Data(buffer.prefix(count))
            digest.update(data: bytes)
            try write(bytes, descriptor: descriptor, cancellation: cancellation)
            total += count
            guard total <= RecoveryBudget.bytes else { throw RecoveryBudget.exceeded }
        }
        try source.validate(input)
        guard total == source.stamp.size, fsync(descriptor) == 0 else { throw ModelFailure.changed }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Open every parent relative to a pinned root; never follow a user symlink.
    private final class Parent {
        let location: RepositoryLocation
        let components: [String]
        let root: Int32
        var descriptor: Int32
        var identities: [ConflictEditorDirectoryIdentity] = []
        var missingDirectory: String?
        var name: String { components.last! }
        init(location: RepositoryLocation, path: String) throws {
            try validate(path)
            self.location = location
            components = path.split(separator: "/").map(String.init)
            root = try WorktreePreservationDirectory.pin(location)
            descriptor = root
        }
        deinit {
            if descriptor != root { Darwin.close(descriptor) }
            Darwin.close(root)
        }
        func probe() throws -> String? {
            for (index, component) in components.dropLast().enumerated() {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 {
                    guard errno == ENOENT else { throw ModelFailure.invalidPath }
                    missingDirectory = components.prefix(index + 1).joined(separator: "/")
                    return missingDirectory
                }
                var info = stat()
                guard fstat(next, &info) == 0 else {
                    Darwin.close(next)
                    throw ModelFailure.changed
                }
                identities.append(Self.identity(info))
                if descriptor != root { Darwin.close(descriptor) }
                descriptor = next
            }
            var info = stat()
            if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw ModelFailure.changed }
                return ""
            }
            guard [UInt16(S_IFREG), UInt16(S_IFLNK)].contains(info.st_mode & UInt16(S_IFMT)) else {
                throw ModelFailure.unsupported(L10n.text("此操作不会替换现有目录或特殊文件。"))
            }
            return nil
        }
        static func identity(_ info: stat) -> ConflictEditorDirectoryIdentity {
            ConflictEditorDirectoryIdentity(
                device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                bornSeconds: Int64(info.st_birthtimespec.tv_sec),
                bornNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
        }
    }

    @concurrent static func install(
        source: RecoveryFileCapture, expected: RecoveryFileCapture, location: RepositoryLocation,
        createdDirectories: [String: ConflictEditorDirectoryIdentity]
    ) async throws -> [String: ConflictEditorDirectoryIdentity] {
        try await SnapshotIO.run { cancellation in
            try cancellation.check()
            let parent = try Parent(location: location, path: source.file.path)
            var created = createdDirectories
            for (index, component) in parent.components.dropLast().enumerated() {
                let prefix = parent.components.prefix(index + 1).joined(separator: "/")
                var made = false
                var next = openat(
                    parent.descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 {
                    guard errno == ENOENT, expected.missingParent?.isEmpty == false,
                        source.file.kind != .absent
                    else {
                        if errno == ENOENT, source.file.kind == .absent { return created }
                        throw ModelFailure.changed
                    }
                    guard mkdirat(parent.descriptor, component, 0o755) == 0 else {
                        throw ModelFailure.changed
                    }
                    made = true
                    next = openat(
                        parent.descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw ModelFailure.changed }
                var info = stat()
                guard fstat(next, &info) == 0 else {
                    Darwin.close(next)
                    throw ModelFailure.changed
                }
                let identity = Parent.identity(info)
                if index < expected.parents.count {
                    guard expected.parents[index] == identity else {
                        Darwin.close(next)
                        throw ModelFailure.changed
                    }
                } else if let known = created[prefix] {
                    guard known == identity else {
                        Darwin.close(next)
                        throw ModelFailure.changed
                    }
                } else {
                    // A missing parent must be one this operation just created.
                    guard made,
                        expected.missingParent == prefix
                            || created.keys.contains(where: { prefix.hasPrefix($0 + "/") })
                    else {
                        Darwin.close(next)
                        throw ModelFailure.changed
                    }
                    created[prefix] = identity
                }
                if parent.descriptor != parent.root { Darwin.close(parent.descriptor) }
                parent.descriptor = next
            }
            func validateEntry() throws {
                try location.validateIdentity()
                var info = stat()
                let found = fstatat(parent.descriptor, parent.name, &info, AT_SYMLINK_NOFOLLOW) == 0
                if let version = expected.version {
                    guard found, SnapshotFileStamp(info) == version, info.st_uid == geteuid() else {
                        throw ModelFailure.changed
                    }
                } else {
                    guard !found, errno == ENOENT else { throw ModelFailure.changed }
                }
            }
            try validateEntry()
            if source.file.kind == .absent {
                if expected.version != nil {
                    guard unlinkat(parent.descriptor, parent.name, 0) == 0 else {
                        throw ProcessFailure.outputWrite(errno)
                    }
                }
                return created
            }
            guard let snapshot = source.snapshot else { throw ModelFailure.changed }
            let candidate = ".wegit-restore-" + UUID().uuidString
            defer { unlinkat(parent.descriptor, candidate, 0) }
            if source.file.kind == .symbolicLink {
                let descriptor = try snapshot.open()
                defer { Darwin.close(descriptor) }
                let data =
                    try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 65537)
                    ?? Data()
                guard data.count <= 65536, !data.contains(0), hash(data) == source.file.sha256 else {
                    throw ModelFailure.changed
                }
                var value = data.map { CChar(bitPattern: $0) } + [0]
                guard symlinkat(&value, parent.descriptor, candidate) == 0 else {
                    throw ProcessFailure.outputWrite(errno)
                }
            } else {
                let output = openat(
                    parent.descriptor, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(source.file.mode))
                guard output >= 0 else { throw ProcessFailure.outputWrite(errno) }
                defer { Darwin.close(output) }
                guard try copy(snapshot, to: output, cancellation: cancellation) == source.file.sha256,
                    fchmod(output, mode_t(source.file.mode)) == 0
                else { throw ModelFailure.changed }
            }
            try cancellation.check()
            try validateEntry()
            let result =
                expected.version == nil
                ? renameatx_np(
                    parent.descriptor, candidate, parent.descriptor, parent.name, UInt32(RENAME_EXCL))
                : renameat(parent.descriptor, candidate, parent.descriptor, parent.name)
            guard result == 0, fsync(parent.descriptor) == 0 else { throw ProcessFailure.outputWrite(errno) }
            return created
        }
    }
}
