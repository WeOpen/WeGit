import CryptoKit
import Darwin
import Foundation

private final class RecoveryCaptureResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: [RecoveryFileCapture]] = [:]
    private var failure: (any Error)?
    func store(_ files: [RecoveryFileCapture], offset: Int) { lock.withLock { values[offset] = files } }
    func fail(_ error: any Error) { lock.withLock { if failure == nil { failure = error } } }
    func finish(count: Int) throws -> [RecoveryFileCapture] {
        try lock.withLock {
            if let failure { throw failure }
            let result = values.sorted { $0.key < $1.key }.flatMap(\.value)
            guard result.count == count else { throw ModelFailure.changed }
            return result
        }
    }
}

/// Durable per-worktree storage, anchored at the opened Git directory. Flat UUID
/// directories contain bounded regular files, never arbitrary user paths.
final class RecoveryStore: @unchecked Sendable {
    let location: RepositoryLocation
    let url: URL
    private let descriptor: Int32
    private let identity: RepositoryNodeIdentity

    init(location: RepositoryLocation) throws {
        try location.validateIdentity()
        self.location = location
        let parent = try SelectedIndexSnapshot.openDirectory(location)
        defer { Darwin.close(parent) }
        let name = "wegit-recovery"
        if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw ProcessFailure.outputWrite(errno) }
        guard fsync(parent) == 0 else { throw ProcessFailure.outputWrite(errno) }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            Darwin.close(fd)
            throw ModelFailure.unsupported(L10n.text("恢复目录的类型、所有者或权限异常。"))
        }
        url = location.gitDirectory.appending(path: name, directoryHint: .isDirectory)
        do { identity = try RepositoryNodeIdentity.read(url, directory: true) } catch {
            Darwin.close(fd)
            throw error
        }
        descriptor = fd
    }
    deinit { Darwin.close(descriptor) }

    func validate() throws {
        try location.validateIdentity()
        guard try RepositoryNodeIdentity.read(url, directory: true) == identity else {
            throw ModelFailure.changed
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode
        else {
            throw ModelFailure.changed
        }
    }

    private func open(_ id: UUID) throws -> Int32 {
        try validate()
        let fd = openat(descriptor, id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            Darwin.close(fd)
            throw ModelFailure.changed
        }
        return fd
    }

    private func read(_ name: String, in directory: Int32, limit: Int) throws -> Data {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { throw ModelFailure.changed }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            before.st_size >= 0, before.st_size <= limit, before.st_uid == getuid()
        else { throw ModelFailure.changed }
        let data =
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
        var after = stat()
        guard fstat(fd, &after) == 0, SnapshotFileStamp(before) == SnapshotFileStamp(after),
            data.count == before.st_size
        else {
            throw ModelFailure.changed
        }
        return data
    }

    func record(_ id: UUID) throws -> RecoveryRecord {
        let directory = try open(id)
        defer { Darwin.close(directory) }
        let record = try JSONDecoder().decode(
            RecoveryRecord.self, from: read("record.json", in: directory, limit: 2 * 1024 * 1024))
        guard record.format == 1, record.id == id, record.workspaceID == location.persistenceID,
            record.files.count <= RecoveryBudget.files,
            record.indexBytes >= 0, record.indexBytes <= 32 * 1024 * 1024,
            record.indexMode <= 0o777,
            record.indexTree == nil || (record.indexSHA256 != nil && GitObjectID.valid(record.indexTree!)),
            Set(record.files.map(\.path)).count == record.files.count,
            Set(record.files.map(\.storageName)).count == record.files.count,
            record.sharedIndex == nil
                || (record.indexSHA256 != nil && Self.validSharedIndex(record.sharedIndex!))
        else { throw ModelFailure.changed }
        for file in record.files {
            try RecoveryFileIO.validate(file.path)
            guard file.bytes >= 0, file.bytes <= RecoveryBudget.bytes, file.mode <= 0o777,
                file.storageName.hasPrefix("blob-"), file.storageName.count <= 32,
                file.storageName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                file.kind == .absent ? file.sha256 == nil && file.bytes == 0 : file.sha256?.count == 64
            else {
                throw ModelFailure.changed
            }
        }
        guard record.totalBytes <= RecoveryBudget.bytes else { throw ModelFailure.changed }
        return record
    }

    static func validSharedIndex(_ value: RecoverySharedIndex) -> Bool {
        value.name.hasPrefix("sharedindex.")
            && GitObjectID.valid(String(value.name.dropFirst("sharedindex.".count)))
            && value.mode <= 0o777 && (0...(32 * 1024 * 1024)).contains(value.bytes)
            && value.sha256.count == 64
            && value.sha256.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    func records() throws -> [RecoveryRecord] {
        try validate()
        let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        guard entries.count <= 1000 else { throw RecoveryBudget.exceeded }
        let values = try entries.compactMap { entry -> RecoveryRecord? in
            guard let id = UUID(uuidString: entry.lastPathComponent), id.uuidString == entry.lastPathComponent
            else { return nil }
            return try record(id)
        }
        try validate()
        return values.sorted { $0.createdAt > $1.createdAt }
    }

    private func write(_ name: String, data: Data, directory: Int32, cancellation: IOCancellation) throws {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProcessFailure.outputWrite(errno) }
        defer { Darwin.close(fd) }
        try RecoveryFileIO.write(data, descriptor: fd, cancellation: cancellation)
        guard fsync(fd) == 0 else { throw ProcessFailure.outputWrite(errno) }
    }

    func save(_ record: RecoveryRecord) throws {
        let directory = try open(record.id)
        defer { Darwin.close(directory) }
        let name = "record-" + UUID().uuidString
        defer { unlinkat(directory, name, 0) }
        try write(
            name, data: JSONEncoder().encode(record), directory: directory, cancellation: IOCancellation())
        try validate()
        guard renameat(directory, name, directory, "record.json") == 0, fsync(directory) == 0 else {
            throw ProcessFailure.outputWrite(errno)
        }
    }

    @concurrent func persist(
        operation: String, head: String?, branch: String, target: String?,
        index: SelectedIndexSnapshot, files: [RecoveryFileCapture],
        sharedIndex: RecoverySharedIndexSnapshot? = nil
    ) async throws -> RecoveryRecord {
        try await SnapshotIO.run { [self] cancellation in
            try validate()
            let size = files.reduce((index.bytes?.count ?? 0) + (sharedIndex?.data.count ?? 0)) {
                $0 + $1.file.bytes
            }
            guard files.count <= RecoveryBudget.files, size <= RecoveryBudget.bytes else {
                throw RecoveryBudget.exceeded
            }
            guard try records().reduce(size, { $0 + $1.totalBytes }) <= RecoveryBudget.retainedBytes else {
                throw RecoveryBudget.exceeded
            }
            let id = UUID()
            guard mkdirat(descriptor, id.uuidString, 0o700) == 0 else {
                throw ProcessFailure.outputWrite(errno)
            }
            let directory = try open(id)
            defer { Darwin.close(directory) }
            let value = RecoveryRecord(
                format: 1, id: id, workspaceID: location.persistenceID, createdAt: Date(),
                operation: operation, head: head, branch: branch, target: target,
                files: files.map(\.file), indexSHA256: index.bytes.map(RecoveryFileIO.hash),
                indexMode: UInt16(index.mode), indexBytes: index.bytes?.count ?? 0,
                sharedIndex: sharedIndex?.file, indexTree: nil,
                state: .prepared, observedHead: nil, details: nil)
            // A crash during copying still leaves a visible prepared record.
            // No Git write begins until every byte below is copied and verified.
            try save(value)
            if let bytes = index.bytes {
                try write("index", data: bytes, directory: directory, cancellation: cancellation)
            }
            if let sharedIndex {
                guard Self.validSharedIndex(sharedIndex.file),
                    sharedIndex.data.count == sharedIndex.file.bytes,
                    RecoveryFileIO.hash(sharedIndex.data) == sharedIndex.file.sha256
                else { throw ModelFailure.changed }
                try write(
                    sharedIndex.file.name, data: sharedIndex.data, directory: directory,
                    cancellation: cancellation)
            }
            let results = RecoveryCaptureResults()
            // Bounded durable-copy batches overlap fsync latency. Hashing reads
            // retain their separate two-batch limit below.
            let width = max(1, (files.count + 3) / 4)
            DispatchQueue.concurrentPerform(iterations: files.isEmpty ? 0 : (files.count + width - 1) / width)
            { batch in
                let offset = batch * width
                do {
                    let selected = Array(files[offset..<min(files.count, offset + width)])
                    for file in selected {
                        try cancellation.check()
                        guard let snapshot = file.snapshot else { continue }
                        guard
                            try RecoveryFileIO.copy(
                                snapshot, directory: directory, name: file.file.storageName,
                                cancellation: cancellation) == file.file.sha256
                        else { throw ModelFailure.changed }
                    }
                    results.store(selected, offset: offset)
                } catch { results.fail(error) }
            }
            _ = try results.finish(count: files.count)
            try cancellation.check()
            try save(value)
            try validate()
            guard fsync(descriptor) == 0 else { throw ProcessFailure.outputWrite(errno) }
            return value
        }
    }

    @concurrent func captureIndex(_ record: RecoveryRecord) async throws
        -> (Data?, RecoverySharedIndexSnapshot?)
    {
        try await SnapshotIO.run { [self] cancellation in
            try cancellation.check()
            guard try self.record(record.id) == record else { throw ModelFailure.changed }
            let directory = try open(record.id)
            defer { Darwin.close(directory) }
            let result = try readCapturedIndex(record, directory: directory, include: true)
            try cancellation.check()
            guard try self.record(record.id) == record else { throw ModelFailure.changed }
            return result
        }
    }

    private func readCapturedIndex(_ record: RecoveryRecord, directory: Int32, include: Bool) throws
        -> (Data?, RecoverySharedIndexSnapshot?)
    {
        let index: Data?
        if include, let hash = record.indexSHA256 {
            let bytes = try read("index", in: directory, limit: 32 * 1024 * 1024)
            guard RecoveryFileIO.hash(bytes) == hash, bytes.count == record.indexBytes else {
                throw ModelFailure.changed
            }
            index = bytes
        } else {
            index = nil
        }
        var sharedIndex: RecoverySharedIndexSnapshot?
        if include, let shared = record.sharedIndex {
            let data = try read(shared.name, in: directory, limit: 32 * 1024 * 1024)
            guard data.count == shared.bytes, RecoveryFileIO.hash(data) == shared.sha256 else {
                throw ModelFailure.changed
            }
            sharedIndex = RecoverySharedIndexSnapshot(file: shared, data: data)
        }
        return (index, sharedIndex)
    }

    @concurrent func capture(_ record: RecoveryRecord, includeFiles: Bool = true, includeIndex: Bool = true)
        async throws
        -> ([RecoveryFileCapture], Data?, RecoverySharedIndexSnapshot?)
    {
        try await SnapshotIO.run { [self] cancellation in
            guard try self.record(record.id) == record else { throw ModelFailure.changed }
            let directory = try open(record.id)
            defer { Darwin.close(directory) }
            let (index, sharedIndex) = try readCapturedIndex(
                record, directory: directory, include: includeIndex)
            let storage = try SnapshotDirectory()
            try storage.validate()
            let temporary = Darwin.open(storage.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard temporary >= 0 else { throw ModelFailure.changed }
            defer { Darwin.close(temporary) }
            let selectedFiles = includeFiles ? record.files : []
            let width = max(1, (selectedFiles.count + 1) / 2)
            let results = RecoveryCaptureResults()
            DispatchQueue.concurrentPerform(
                iterations: selectedFiles.isEmpty ? 0 : (selectedFiles.count + width - 1) / width
            ) { batch in
                let offset = batch * width
                do {
                    let files = try selectedFiles[offset..<min(selectedFiles.count, offset + width)].map {
                        file -> RecoveryFileCapture in
                        if file.kind == .absent {
                            return RecoveryFileCapture(
                                file: file, snapshot: nil, version: nil, parents: [], missingParent: nil)
                        }
                        let source = openat(directory, file.storageName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                        guard source >= 0 else { throw ModelFailure.changed }
                        defer { Darwin.close(source) }
                        var info = stat()
                        guard fstat(source, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                            info.st_size == file.bytes
                        else {
                            throw ModelFailure.changed
                        }
                        let url = storage.url.appending(path: file.storageName)
                        if fclonefileat(source, temporary, file.storageName, UInt32(CLONE_NOOWNERCOPY)) == 0 {
                            let output = openat(
                                temporary, file.storageName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                            guard output >= 0 else { throw ModelFailure.changed }
                            defer { Darwin.close(output) }
                            let digest = try RecoveryFileIO.hashFile(
                                output, expectedBytes: file.bytes, cancellation: cancellation)
                            var after = stat()
                            guard digest == file.sha256, fstat(source, &after) == 0,
                                SnapshotFileStamp(after) == SnapshotFileStamp(info),
                                fchmod(output, 0o600) == 0
                            else { throw ModelFailure.changed }
                            return RecoveryFileCapture(
                                file: file,
                                snapshot: try SnapshotFile(
                                    directory: storage, url: url, verifiedSHA256: digest),
                                version: nil, parents: [], missingParent: nil)
                        }
                        guard [EXDEV, ENOTSUP, EINVAL].contains(errno) else {
                            throw ProcessFailure.outputWrite(errno)
                        }
                        let output = Darwin.open(
                            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                        guard output >= 0 else { throw ProcessFailure.outputWrite(errno) }
                        defer { Darwin.close(output) }
                        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                        var copied = 0
                        while true {
                            try cancellation.check()
                            let count = Darwin.read(source, &buffer, buffer.count)
                            if count < 0 && errno == EINTR { continue }
                            guard count >= 0 else { throw ModelFailure.changed }
                            if count == 0 { break }
                            copied += count
                            guard copied <= file.bytes else { throw ModelFailure.changed }
                            try RecoveryFileIO.write(
                                buffer.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: count) },
                                descriptor: output, cancellation: cancellation)
                        }
                        guard copied == file.bytes else { throw ModelFailure.changed }
                        var after = stat()
                        guard fstat(source, &after) == 0, SnapshotFileStamp(after) == SnapshotFileStamp(info)
                        else {
                            throw ModelFailure.changed
                        }
                        let snapshot = try SnapshotFile(directory: storage, url: url)
                        let handle = try snapshot.open()
                        defer { Darwin.close(handle) }
                        var digest = CryptoKit.SHA256()
                        while true {
                            try cancellation.check()
                            let data =
                                try FileHandle(fileDescriptor: handle, closeOnDealloc: false).read(
                                    upToCount: 65536)
                                ?? Data()
                            if data.isEmpty { break }
                            digest.update(data: data)
                        }
                        let checksum = RecoveryFileIO.hex(digest.finalize())
                        guard checksum == file.sha256 else {
                            throw ModelFailure.changed
                        }
                        return RecoveryFileCapture(
                            file: file,
                            snapshot: try SnapshotFile(
                                directory: storage, url: url, verifiedSHA256: checksum),
                            version: nil, parents: [], missingParent: nil)
                    }
                    results.store(files, offset: offset)
                } catch { results.fail(error) }
            }
            let files = try results.finish(count: selectedFiles.count)
            try cancellation.check()
            try storage.validate()
            guard try self.record(record.id) == record else { throw ModelFailure.changed }
            return (files, index, sharedIndex)
        }
    }

    func validateRemoval(_ record: RecoveryRecord) throws {
        guard try self.record(record.id) == record else { throw ModelFailure.changed }
        let directory = try open(record.id)
        defer { Darwin.close(directory) }
        _ = try removalNames(record, directory: directory)
        try validate()
    }

    private func removalNames(_ record: RecoveryRecord, directory: Int32) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: url.appending(path: record.id.uuidString).path)
        let allowed = Set(
            record.files.filter { $0.kind != .absent }.map(\.storageName) + ["record.json", "index"]
                + (record.sharedIndex.map { [$0.name] } ?? []))
        guard Set(names).isSubset(of: allowed) else { throw ModelFailure.changed }
        for name in names {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), info.st_uid == getuid()
            else { throw ModelFailure.changed }
        }
        return names
    }

    func remove(_ record: RecoveryRecord) throws {
        guard try self.record(record.id) == record else { throw ModelFailure.changed }
        let directory = try open(record.id)
        defer { Darwin.close(directory) }
        let names = try removalNames(record, directory: directory)
        try validate()
        for name in names {
            guard unlinkat(directory, name, 0) == 0 else { throw ProcessFailure.outputWrite(errno) }
        }
        guard unlinkat(descriptor, record.id.uuidString, AT_REMOVEDIR) == 0, fsync(descriptor) == 0 else {
            throw ProcessFailure.outputWrite(errno)
        }
    }
}
