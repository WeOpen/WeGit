import CryptoKit
import Darwin
import Foundation

struct RecoveryFileMetadata: Sendable {
    let path: String
    let mode: UInt16
    let version: SnapshotFileStamp?
    let parents: [ConflictEditorDirectoryIdentity]
    let missingParent: String?
}

private final class RecoveryByteBudget: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var bytes = 0
    init(limit: Int) { self.limit = limit }
    func reserve(_ count: Int) throws {
        try lock.withLock {
            guard count >= 0, count <= limit - bytes else { throw RecoveryBudget.exceeded }
            bytes += count
        }
    }
}

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

private final class RecoveryInstallResults: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: (any Error)?
    private var completed = 0
    func check() throws { try lock.withLock { if let failure { throw failure } } }
    func finishBatch(_ count: Int) { lock.withLock { completed += count } }
    func fail(_ error: any Error) { lock.withLock { if failure == nil { failure = error } } }
    func finish(_ count: Int) throws {
        try lock.withLock {
            if let failure { throw failure }
            guard completed == count else { throw ModelFailure.changed }
        }
    }
}

enum RecoveryFileIO {
    @concurrent static func preview(_ capture: RecoveryFileCapture) async throws -> String? {
        guard capture.file.kind != .absent, (0...64 * 1024).contains(capture.file.bytes),
            let snapshot = capture.snapshot
        else { return nil }
        return try await SnapshotIO.run { cancellation in
            let input = try snapshot.open()
            defer { Darwin.close(input) }
            var data = Data(count: capture.file.bytes)
            try data.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try cancellation.check()
                    let count = Darwin.read(
                        input, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw ModelFailure.changed }
                    offset += count
                }
            }
            try snapshot.validate(input)
            guard hash(data) == capture.file.sha256 else { throw ModelFailure.changed }
            guard !data.contains(0) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    @concurrent static func replacement(
        path: String, data: Data?, kind: RecoveryFile.Kind = .file, mode: UInt16
    )
        async throws -> RecoveryFileCapture
    {
        try validate(path)
        guard mode <= 0o777, data?.count ?? 0 <= RecoveryBudget.bytes else { throw RecoveryBudget.exceeded }
        guard let data else {
            return RecoveryFileCapture(
                file: RecoveryFile(
                    path: path, kind: .absent, mode: 0o644, bytes: 0, sha256: nil, storageName: "blob-0"),
                snapshot: nil, version: nil, parents: [], missingParent: nil)
        }
        return try await SnapshotIO.run { cancellation in
            let storage = try SnapshotDirectory()
            let pathURL = storage.url.appending(path: "blob-0")
            let descriptor = Darwin.open(
                pathURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw ProcessFailure.outputWrite(errno) }
            defer { Darwin.close(descriptor) }
            try write(data, descriptor: descriptor, cancellation: cancellation)
            let checksum = hash(data)
            return RecoveryFileCapture(
                file: RecoveryFile(
                    path: path, kind: kind, mode: mode, bytes: data.count, sha256: checksum,
                    storageName: "blob-0"),
                snapshot: try SnapshotFile(directory: storage, url: pathURL, verifiedSHA256: checksum),
                version: nil, parents: [], missingParent: nil)
        }
    }

    @concurrent static func metadataAll(location: RepositoryLocation, paths: [String]) async throws
        -> [RecoveryFileMetadata]
    {
        guard paths.count <= RecoveryBudget.metadataFiles else { throw RecoveryBudget.exceeded }
        return try await SnapshotIO.run { cancellation in
            let fence = try RepositoryReadFence(location: location)
            var values: [RecoveryFileMetadata] = []
            values.reserveCapacity(paths.count)
            for path in paths {
                try cancellation.check()
                let parent = try Parent(location: location, path: path, readFence: fence)
                let missing = try parent.probe()
                if missing != nil {
                    values.append(
                        RecoveryFileMetadata(
                            path: path, mode: 0o644, version: nil,
                            parents: parent.identities, missingParent: missing))
                } else {
                    let reader = try RepositoryFileReader(
                        location: location, path: path,
                        cancellation: cancellation, openContents: false, readFence: fence)
                    try reader.validate()
                    values.append(
                        RecoveryFileMetadata(
                            path: path, mode: reader.mode, version: reader.version,
                            parents: parent.identities, missingParent: nil))
                }
            }
            try cancellation.check()
            try fence.validate()
            return values
        }
    }

    @concurrent static func verifyMetadataAll(_ values: [RecoveryFileMetadata], location: RepositoryLocation)
        async throws
    {
        try await SnapshotIO.run { cancellation in
            let fence = try RepositoryReadFence(location: location)
            for value in values {
                try cancellation.check()
                let parent = try Parent(location: location, path: value.path, readFence: fence)
                let missing = try parent.probe()
                guard parent.identities == value.parents, missing == value.missingParent else {
                    throw ModelFailure.changed
                }
                if let version = value.version {
                    let reader = try RepositoryFileReader(
                        location: location, path: value.path,
                        cancellation: cancellation, openContents: false, readFence: fence)
                    guard reader.version == version, reader.mode == value.mode else {
                        throw ModelFailure.changed
                    }
                    try reader.validate()
                }
            }
            try cancellation.check()
            try fence.validate()
        }
    }

    @concurrent static func verify(_ capture: RecoveryFileCapture, location: RepositoryLocation) async throws
    {
        try await verifyAll([capture], location: location)
    }
    @concurrent static func verifyAll(_ captures: [RecoveryFileCapture], location: RepositoryLocation)
        async throws
    {
        try await SnapshotIO.run { cancellation in
            let fence = try RepositoryReadFence(location: location)
            for capture in captures {
                try verifyNow(capture, location: location, cancellation: cancellation, readFence: fence)
            }
            try cancellation.check()
            try fence.validate()
        }
    }

    private static func verifyNow(
        _ capture: RecoveryFileCapture, location: RepositoryLocation, cancellation: IOCancellation,
        readFence: RepositoryReadFence
    ) throws {
        try cancellation.check()
        let parent = try Parent(location: location, path: capture.file.path, readFence: readFence)
        let missing = try parent.probe()
        guard parent.identities == capture.parents, missing == capture.missingParent else {
            throw ModelFailure.changed
        }
        if let expected = capture.version {
            let reader = try RepositoryFileReader(
                location: location, path: capture.file.path,
                cancellation: cancellation, openContents: false, readFence: readFence)
            guard reader.version == expected, reader.mode == capture.file.mode else {
                throw ModelFailure.changed
            }
            try reader.validate()
        }
    }

    static func hash(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for value in digest {
            bytes.append(alphabet[Int(value >> 4)])
            bytes.append(alphabet[Int(value & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
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
    ) async throws -> RecoveryFileCapture {
        try await SnapshotIO.run { cancellation in
            try captureNow(
                location: location, path: path, name: name, storage: storage, cancellation: cancellation)
        }
    }
    @concurrent static func captureAll(
        location: RepositoryLocation, paths: [String], limit: Int = RecoveryBudget.bytes,
        storageOffset: Int = 0,
        cloneSource: Bool = true
    ) async throws
        -> [RecoveryFileCapture]
    {
        guard paths.count <= RecoveryBudget.files, (0...RecoveryBudget.bytes).contains(limit),
            (0...(RecoveryBudget.files - paths.count)).contains(storageOffset)
        else {
            throw RecoveryBudget.exceeded
        }
        if paths.isEmpty {
            return try await SnapshotIO.run { cancellation in
                try cancellation.check()
                try location.validateIdentity()
                return []
            }
        }
        let (fence, storage) = try await SnapshotIO.run { _ in
            (try RepositoryReadFence(location: location), try SnapshotDirectory())
        }
        let budget = RecoveryByteBudget(limit: limit)
        // Two bounded batches, never one task or temporary directory per file.
        let width = (paths.count + 1) / 2
        let chunks = try await withThrowingTaskGroup(of: (Int, [RecoveryFileCapture]).self) { group in
            for start in stride(from: 0, to: paths.count, by: width) {
                group.addTask {
                    try await SnapshotIO.run { cancellation in
                        var values: [RecoveryFileCapture] = []
                        for index in start..<min(paths.count, start + width) {
                            values.append(
                                try captureNow(
                                    location: location, path: paths[index],
                                    name: "blob-\(storageOffset + index)",
                                    storage: storage, cancellation: cancellation, readFence: fence,
                                    budget: budget, cloneSource: cloneSource))
                        }
                        try cancellation.check()
                        try storage.validate()
                        return (start, values)
                    }
                }
            }
            var result: [(Int, [RecoveryFileCapture])] = []
            for try await value in group { result.append(value) }
            return result
        }
        let captures = chunks.sorted { $0.0 < $1.0 }.flatMap(\.1)
        try await SnapshotIO.run { cancellation in
            try cancellation.check()
            try fence.validate()
            try validateSnapshotStorage(captures, cancellation: cancellation)
        }
        return captures
    }

    static func validateSnapshotStorage(_ captures: [RecoveryFileCapture], cancellation: IOCancellation)
        throws
    {
        var directories: Set<ObjectIdentifier> = []
        for capture in captures {
            try cancellation.check()
            guard let directory = capture.snapshot?.directory,
                directories.insert(ObjectIdentifier(directory)).inserted
            else { continue }
            try directory.validate()
        }
    }

    private static func captureNow(
        location: RepositoryLocation, path: String, name: String, storage: SnapshotDirectory?,
        cancellation: IOCancellation, readFence: RepositoryReadFence? = nil,
        budget: RecoveryByteBudget? = nil,
        cloneSource: Bool = true
    ) throws -> RecoveryFileCapture {
        try validate(path)
        try cancellation.check()
        let parent = try Parent(location: location, path: path, readFence: readFence)
        let missing = try parent.probe()
        if let missing {
            return RecoveryFileCapture(
                file: RecoveryFile(
                    path: path, kind: .absent, mode: 0o644, bytes: 0, sha256: nil, storageName: name),
                snapshot: nil, version: nil, parents: parent.identities, missingParent: missing)
        }
        let directory = try storage ?? SnapshotDirectory()
        let url = directory.url.appending(path: name)
        let reader = try RepositoryFileReader(
            location: location, path: path, cancellation: cancellation, readFence: readFence)
        guard reader.size <= RecoveryBudget.bytes else { throw RecoveryBudget.exceeded }
        try budget?.reserve(Int(reader.size))
        if cloneSource, try reader.clone(to: directory, name: name) {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ModelFailure.changed }
            defer { Darwin.close(descriptor) }
            let digest = try hashFile(
                descriptor, expectedBytes: Int(reader.size), cancellation: cancellation)
            // Preview storage is process-owned. The durable copy is synced by
            // RecoveryStore before any destructive repository write begins.
            guard fchmod(descriptor, 0o600) == 0 else {
                throw ProcessFailure.outputWrite(errno)
            }
            try reader.validate()
            return RecoveryFileCapture(
                file: RecoveryFile(
                    path: path, kind: .file, mode: reader.mode, bytes: Int(reader.size), sha256: digest,
                    storageName: name),
                snapshot: try SnapshotFile(directory: directory, url: url, verifiedSHA256: digest),
                version: reader.version,
                parents: parent.identities, missingParent: nil)
        }
        let descriptor = Darwin.open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ProcessFailure.outputWrite(errno) }
        defer { Darwin.close(descriptor) }
        var digest = SHA256()
        try reader.read(limit: RecoveryBudget.bytes) { data in
            digest.update(data: data)
            try write(data, descriptor: descriptor, cancellation: cancellation)
        }
        let checksum = hex(digest.finalize())
        return RecoveryFileCapture(
            file: RecoveryFile(
                path: path, kind: reader.symbolicLink ? .symbolicLink : .file,
                mode: reader.mode, bytes: Int(reader.size),
                sha256: checksum, storageName: name),
            snapshot: try SnapshotFile(directory: directory, url: url, verifiedSHA256: checksum),
            version: reader.version,
            parents: parent.identities, missingParent: nil)
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

    @concurrent static func verifyContentsAll(_ sources: [RecoveryFileCapture], location: RepositoryLocation)
        async throws
    {
        if sources.isEmpty {
            try location.validateIdentity()
            return
        }
        let fence = try await SnapshotIO.run { _ in try RepositoryReadFence(location: location) }
        let width = (sources.count + 1) / 2
        let versions = try await withThrowingTaskGroup(of: [RecoveryFileMetadata].self) { group in
            for start in stride(from: 0, to: sources.count, by: width) {
                group.addTask {
                    try await SnapshotIO.run { cancellation in
                        var values: [RecoveryFileMetadata] = []
                        for index in start..<min(sources.count, start + width) {
                            let source = sources[index]
                            try cancellation.check()
                            let parent = try Parent(
                                location: location, path: source.file.path, readFence: fence)
                            let missing = try parent.probe()
                            if source.file.kind == .absent {
                                guard missing != nil else { throw ModelFailure.changed }
                                values.append(
                                    RecoveryFileMetadata(
                                        path: source.file.path, mode: 0o644, version: nil,
                                        parents: parent.identities, missingParent: missing))
                                continue
                            }
                            guard missing == nil else { throw ModelFailure.changed }
                            let reader = try RepositoryFileReader(
                                location: location, path: source.file.path,
                                cancellation: cancellation, readFence: fence)
                            guard reader.mode == source.file.mode, reader.size == source.file.bytes,
                                reader.symbolicLink == (source.file.kind == .symbolicLink)
                            else { throw ModelFailure.changed }
                            var digest = SHA256()
                            try reader.read(limit: RecoveryBudget.bytes) { digest.update(data: $0) }
                            guard hex(digest.finalize()) == source.file.sha256 else {
                                throw ModelFailure.changed
                            }
                            values.append(
                                RecoveryFileMetadata(
                                    path: source.file.path, mode: reader.mode, version: reader.version,
                                    parents: parent.identities, missingParent: nil))
                        }
                        return values
                    }
                }
            }
            var result: [RecoveryFileMetadata] = []
            for try await value in group { result.append(contentsOf: value) }
            return result
        }
        // An earlier file must still match when the complete verification ends.
        try await verifyMetadataAll(versions, location: location)
    }

    static func hashFile(_ descriptor: Int32, expectedBytes: Int, cancellation: IOCancellation) throws
        -> String
    {
        guard expectedBytes >= 0, expectedBytes <= RecoveryBudget.bytes, lseek(descriptor, 0, SEEK_SET) == 0
        else { throw ModelFailure.changed }
        var digest = SHA256()
        var count = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellation.check()
            let size = Darwin.read(descriptor, &buffer, buffer.count)
            if size < 0 && errno == EINTR { continue }
            guard size >= 0 else { throw ModelFailure.changed }
            if size == 0 { break }
            count += size
            guard count <= expectedBytes else { throw ModelFailure.changed }
            buffer.withUnsafeBytes {
                digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(size)))
            }
        }
        guard count == expectedBytes else { throw ModelFailure.changed }
        return hex(digest.finalize())
    }

    static func copy(
        _ source: SnapshotFile, directory: Int32, name: String, mode: mode_t = 0o600,
        cancellation: IOCancellation
    ) throws -> String {
        let input = try source.open()
        defer { Darwin.close(input) }
        try cancellation.check()
        let checksum =
            try source.verifiedSHA256
            ?? hashFile(
                input, expectedBytes: Int(source.stamp.size), cancellation: cancellation)
        try source.validate(input)
        if fclonefileat(input, directory, name, UInt32(CLONE_NOOWNERCOPY)) == 0 {
            let output = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard output >= 0 else { throw ModelFailure.changed }
            defer { Darwin.close(output) }
            var info = stat()
            guard fstat(output, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                info.st_size == source.stamp.size, info.st_uid == getuid()
            else { throw ModelFailure.changed }
            try source.validate(input)
            guard fchmod(output, mode) == 0, fsync(output) == 0 else {
                throw ProcessFailure.outputWrite(errno)
            }
            // fclonefileat clones the pinned descriptor's exact bytes. Its digest
            // remains valid only after the original stamp is checked on both sides.
            return checksum
        }
        guard [EXDEV, ENOTSUP, EINVAL].contains(errno) else { throw ProcessFailure.outputWrite(errno) }
        let output = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard output >= 0 else { throw ProcessFailure.outputWrite(errno) }
        defer { Darwin.close(output) }
        let digest = try copy(source, to: output, cancellation: cancellation)
        guard fchmod(output, mode) == 0, fsync(output) == 0 else { throw ProcessFailure.outputWrite(errno) }
        return digest
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
            let bytes = buffer.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: count) }
            buffer.withUnsafeBytes {
                digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count)))
            }
            try write(bytes, descriptor: descriptor, cancellation: cancellation)
            total += count
            guard total <= RecoveryBudget.bytes else { throw RecoveryBudget.exceeded }
        }
        try source.validate(input)
        guard total == source.stamp.size, fsync(descriptor) == 0 else { throw ModelFailure.changed }
        return hex(digest.finalize())
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
        init(location: RepositoryLocation, path: String, readFence: RepositoryReadFence? = nil) throws {
            try validate(path)
            self.location = location
            components = path.split(separator: "/").map(String.init)
            root = try readFence?.openRoot(for: location) ?? WorktreePreservationDirectory.pin(location)
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
            try installNow(
                source: source, expected: expected, location: location,
                createdDirectories: createdDirectories, cancellation: cancellation)
        }
    }
    @concurrent static func installAll(
        sources: [RecoveryFileCapture], expected: [RecoveryFileCapture], location: RepositoryLocation
    ) async throws {
        guard sources.count == expected.count else { throw ModelFailure.changed }
        _ = try await SnapshotIO.run { cancellation in
            let independent =
                sources.count >= 128
                && sources.indices.allSatisfy {
                    sources[$0].file.kind == .file && expected[$0].file.kind == .file
                        && sources[$0].file.path == expected[$0].file.path
                        && expected[$0].missingParent == nil && expected[$0].version != nil
                }
            let identities = expected.compactMap { value in
                value.version.map { "\($0.device):\($0.inode)" }
            }
            let paths = Set(sources.map(\.file.path))
            let related = paths.contains { path in
                var prefix = ""
                for component in path.split(separator: "/").dropLast() {
                    prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                    if paths.contains(prefix) { return true }
                }
                return false
            }
            if independent, !related, paths.count == sources.count, Set(identities).count == sources.count {
                // Only distinct existing regular leaves may overlap. Directory
                // creation, links, aliases and related paths retain serial order.
                let results = RecoveryInstallResults()
                let width = (sources.count + 3) / 4
                DispatchQueue.concurrentPerform(iterations: (sources.count + width - 1) / width) { batch in
                    let offset = batch * width
                    do {
                        for index in offset..<min(sources.count, offset + width) {
                            try results.check()
                            _ = try installNow(
                                source: sources[index], expected: expected[index], location: location,
                                createdDirectories: [:], cancellation: cancellation)
                        }
                        results.finishBatch(min(sources.count, offset + width) - offset)
                    } catch { results.fail(error) }
                }
                try results.finish(sources.count)
                try location.validateIdentity()
                return [String: ConflictEditorDirectoryIdentity]()
            }
            var created: [String: ConflictEditorDirectoryIdentity] = [:]
            for index in sources.indices {
                created = try installNow(
                    source: sources[index], expected: expected[index], location: location,
                    createdDirectories: created, cancellation: cancellation)
            }
            return created
        }
    }

    private static func installNow(
        source: RecoveryFileCapture, expected: RecoveryFileCapture, location: RepositoryLocation,
        createdDirectories: [String: ConflictEditorDirectoryIdentity], cancellation: IOCancellation
    ) throws -> [String: ConflictEditorDirectoryIdentity] {
        try cancellation.check()
        guard source.file.path == expected.file.path else { throw ModelFailure.changed }
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
                guard mkdirat(parent.descriptor, component, 0o755) == 0,
                    fsync(parent.descriptor) == 0
                else {
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
                guard unlinkat(parent.descriptor, parent.name, 0) == 0,
                    fsync(parent.descriptor) == 0
                else {
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
            guard symlinkat(&value, parent.descriptor, candidate) == 0,
                fchmodat(parent.descriptor, candidate, mode_t(source.file.mode), AT_SYMLINK_NOFOLLOW) == 0
            else {
                throw ProcessFailure.outputWrite(errno)
            }
        } else {
            guard
                try copy(
                    snapshot, directory: parent.descriptor, name: candidate,
                    mode: mode_t(source.file.mode),
                    cancellation: cancellation) == source.file.sha256
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
