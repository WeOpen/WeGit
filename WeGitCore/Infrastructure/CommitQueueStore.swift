import Darwin
import Foundation

final class CommitQueueStore: @unchecked Sendable {
    let location: RepositoryLocation
    private let directory: Int32
    private let identity: RepositoryNodeIdentity
    private let url: URL

    init(location: RepositoryLocation) throws {
        try location.validateIdentity()
        self.location = location
        let parent = try SelectedIndexSnapshot.openDirectory(location)
        defer { Darwin.close(parent) }
        let name = "wegit-commit-queue"
        if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw ProcessFailure.outputWrite(errno) }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            Darwin.close(fd)
            throw ModelFailure.changed
        }
        url = location.gitDirectory.appending(path: name)
        do { identity = try RepositoryNodeIdentity.read(url, directory: true) } catch {
            Darwin.close(fd)
            throw error
        }
        directory = fd
    }
    deinit { Darwin.close(directory) }

    private func validate() throws {
        try location.validateIdentity()
        guard try RepositoryNodeIdentity.read(url, directory: true) == identity else {
            throw ModelFailure.changed
        }
    }

    static func existingRecord(location: RepositoryLocation) throws -> CommitQueueRecord? {
        try location.validateIdentity()
        let root = try SelectedIndexSnapshot.openDirectory(location)
        defer { Darwin.close(root) }
        let directory = openat(root, "wegit-commit-queue", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0 {
            guard errno == ENOENT else { throw ModelFailure.changed }
            return nil
        }
        defer { Darwin.close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
            directoryInfo.st_mode & 0o077 == 0
        else { throw ModelFailure.changed }
        let bytes = try read(directory, name: "active.json")
        guard let bytes else { return nil }
        let record = try JSONDecoder().decode(CommitQueueRecord.self, from: bytes)
        try validateRecord(record, location: location)
        try location.validateIdentity()
        return record
    }

    func record() throws -> CommitQueueRecord? {
        try validate()
        guard let bytes = try Self.read(directory, name: "active.json") else { return nil }
        let record = try JSONDecoder().decode(CommitQueueRecord.self, from: bytes)
        try Self.validateRecord(record, location: location)
        return record
    }

    private static func read(_ directory: Int32, name: String) throws -> Data? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT else { throw ModelFailure.changed }
            return nil
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_uid == getuid(), before.st_mode & 0o077 == 0,
            before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), before.st_size >= 0,
            before.st_size <= 2 * 1024 * 1024
        else { throw ModelFailure.changed }
        let bytes =
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(
                upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        var after = stat()
        var named = stat()
        guard fstat(descriptor, &after) == 0, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            SnapshotFileStamp(before) == SnapshotFileStamp(after),
            SnapshotFileStamp(after) == SnapshotFileStamp(named),
            bytes.count == before.st_size
        else { throw ModelFailure.changed }
        return bytes
    }

    private static func validateRecord(_ value: CommitQueueRecord, location: RepositoryLocation) throws {
        guard value.format == 1, value.workspaceID == location.persistenceID,
            (1...100).contains(value.items.count), (0...value.items.count).contains(value.next),
            GitObjectID.valid(value.originalHead), GitObjectID.valid(value.currentHead),
            !value.branch.isEmpty, value.branch.utf8.count <= 1024, !value.branch.contains("\0"),
            !value.branch.contains("\n"), !value.branch.contains("\r"),
            Set(value.items.map(\.objectID)).count == value.items.count,
            value.expectedTree == nil || GitObjectID.valid(value.expectedTree!),
            value.expectedIndexSHA256 == nil || value.expectedIndexSHA256?.count == 64,
            value.items.allSatisfy({
                GitObjectID.valid($0.objectID) && $0.subject.utf8.count <= 4096
                    && ($0.mainline == nil || (1...64).contains($0.mainline!))
                    && ($0.result == nil || GitObjectID.valid($0.result!))
            })
        else { throw ModelFailure.changed }
        if value.phase == .completed {
            guard value.next == value.items.count else { throw ModelFailure.changed }
        }
        for (index, item) in value.items.enumerated() {
            guard index < value.next ? item.state != .pending : item.state == .pending,
                item.state == .committed ? item.result != nil : item.result == nil
            else { throw ModelFailure.changed }
        }
    }

    func save(_ value: CommitQueueRecord, expected: CommitQueueRecord?) throws {
        try validate()
        try Self.validateRecord(value, location: location)
        guard try record() == expected else { throw ModelFailure.changed }
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 2 * 1024 * 1024 else { throw ModelFailure.changed }
        let temporary = "record-" + UUID().uuidString
        let descriptor = openat(
            directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ProcessFailure.outputWrite(errno) }
        defer {
            Darwin.close(descriptor)
            unlinkat(directory, temporary, 0)
        }
        try RecoveryFileIO.write(bytes, descriptor: descriptor, cancellation: IOCancellation())
        guard fsync(descriptor) == 0 else { throw ProcessFailure.outputWrite(errno) }
        try validate()
        guard try record() == expected, renameat(directory, temporary, directory, "active.json") == 0,
            fsync(directory) == 0
        else { throw ModelFailure.changed }
    }

    func remove(_ expected: CommitQueueRecord) throws {
        try validate()
        guard !expected.phase.pending, try record() == expected else { throw ModelFailure.changed }
        let holding = "closed-" + expected.id.uuidString
        guard renameatx_np(directory, "active.json", directory, holding, UInt32(RENAME_EXCL)) == 0 else {
            throw ModelFailure.changed
        }
        guard let bytes = try Self.read(directory, name: holding),
            try JSONDecoder().decode(CommitQueueRecord.self, from: bytes) == expected
        else { throw ModelFailure.changed }
        guard unlinkat(directory, holding, 0) == 0, fsync(directory) == 0 else { throw ModelFailure.changed }
    }
}
