import Darwin
import Foundation

final class MailPatchStore: @unchecked Sendable {
    let location: RepositoryLocation
    let url: URL
    private let directory: Int32
    private let identity: RepositoryNodeIdentity
    init(location: RepositoryLocation) throws {
        try location.validateIdentity()
        self.location = location
        let parent = try SelectedIndexSnapshot.openDirectory(location)
        defer { Darwin.close(parent) }
        if mkdirat(parent, "wegit-mail-patches", 0o700) != 0, errno != EEXIST { throw ModelFailure.changed }
        let fd = openat(parent, "wegit-mail-patches", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            Darwin.close(fd)
            throw ModelFailure.changed
        }
        url = location.gitDirectory.appending(path: "wegit-mail-patches")
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
    static func existingRecord(location: RepositoryLocation) throws -> MailPatchRecord? {
        try location.validateIdentity()
        let parent = try SelectedIndexSnapshot.openDirectory(location)
        defer { Darwin.close(parent) }
        let directory = openat(parent, "wegit-mail-patches", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0 {
            guard errno == ENOENT else { throw ModelFailure.changed }
            return nil
        }
        defer { Darwin.close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw ModelFailure.changed
        }
        guard let data = try read(directory, name: "active.json", limit: 2 * 1024 * 1024) else { return nil }
        let record = try JSONDecoder().decode(MailPatchRecord.self, from: data)
        try validateRecord(record, location: location)
        return record
    }
    private static func validateRecord(_ record: MailPatchRecord, location: RepositoryLocation) throws {
        guard record.format == 1, record.workspaceID == location.persistenceID,
            record.originalHead == nil || GitObjectID.valid(record.originalHead!),
            (1...100).contains(record.entries.count), (0...record.entries.count).contains(record.next),
            Set(record.skipped ?? []).count == (record.skipped ?? []).count,
            (record.skipped ?? []).allSatisfy({ (0..<record.entries.count).contains($0) }),
            record.expectedIndexSHA256 == nil || record.expectedIndexSHA256!.count == 64,
            record.expectedConfigurationSHA256 == nil || record.expectedConfigurationSHA256!.count == 64,
            record.entries.enumerated().allSatisfy({
                $0.element.number == $0.offset + 1 && $0.element.sha256.count == 64
                    && $0.element.paths.count <= 1000 && $0.element.subject.utf8.count <= 4096
                    && ($0.element.body?.utf8.count ?? 0) <= 64 * 1024
                    && $0.element.body?.contains("\0") != true
                    && $0.element.author.utf8.count <= 4096 && $0.element.email.utf8.count <= 4096
                    && ($0.element.authorDate?.utf8.count ?? 0) <= 4096
            })
        else { throw ModelFailure.changed }
    }
    private static func read(_ directory: Int32, name: String, limit: Int) throws -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw ModelFailure.changed }
            return nil
        }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_uid == getuid(), before.st_mode & 0o077 == 0,
            before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), before.st_size >= 0, before.st_size <= limit
        else { throw ModelFailure.changed }
        let data =
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
        var after = stat()
        var named = stat()
        guard fstat(fd, &after) == 0, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            SnapshotFileStamp(before) == SnapshotFileStamp(after),
            SnapshotFileStamp(after) == SnapshotFileStamp(named),
            data.count == before.st_size
        else { throw ModelFailure.changed }
        return data
    }
    func save(_ record: MailPatchRecord, expected: MailPatchRecord?) throws {
        try validate()
        try Self.validateRecord(record, location: location)
        guard try Self.existingRecord(location: location) == expected else { throw ModelFailure.changed }
        let data = try JSONEncoder().encode(record)
        guard data.count <= 2 * 1024 * 1024 else { throw ModelFailure.changed }
        let temporary = "record-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ModelFailure.changed }
        defer {
            Darwin.close(fd)
            unlinkat(directory, temporary, 0)
        }
        try RecoveryFileIO.write(data, descriptor: fd, cancellation: IOCancellation())
        guard fsync(fd) == 0, try Self.existingRecord(location: location) == expected,
            renameat(directory, temporary, directory, "active.json") == 0, fsync(directory) == 0
        else { throw ModelFailure.changed }
    }
    func close(_ record: MailPatchRecord) throws {
        try validate()
        guard !record.phase.pending, try Self.existingRecord(location: location) == record else {
            throw ModelFailure.changed
        }
        let name = "closed-" + record.id.uuidString + ".json"
        guard renameatx_np(directory, "active.json", directory, name, UInt32(RENAME_EXCL)) == 0,
            fsync(directory) == 0
        else { throw ModelFailure.changed }
        // Completed inputs are an internal cache; unknown or changed files are
        // retained rather than recursively deleting the directory.
        try? discardInputs(record)
        try? trimClosedRecords()
    }

    private func discardInputs(_ record: MailPatchRecord) throws {
        try validate()
        let name = record.id.uuidString
        let folder = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if folder < 0 {
            guard errno == ENOENT else { throw ModelFailure.changed }
            return
        }
        defer { Darwin.close(folder) }
        var identity = stat()
        guard fstat(folder, &identity) == 0, identity.st_uid == getuid(), identity.st_mode & 0o077 == 0 else {
            throw ModelFailure.changed
        }
        var inputs: [(String, SnapshotFileStamp)] = []
        var total = 0
        for (index, entry) in record.entries.enumerated() {
            let file = String(format: "%04d", index + 1)
            var before = stat()
            guard fstatat(folder, file, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw ModelFailure.changed }
            guard let bytes = try Self.read(folder, name: file, limit: PatchReadBudget.bytes - total),
                RecoveryFileIO.hash(bytes) == entry.sha256
            else { throw ModelFailure.changed }
            total += bytes.count
            var info = stat()
            guard fstatat(folder, file, &info, AT_SYMLINK_NOFOLLOW) == 0,
                SnapshotFileStamp(before) == SnapshotFileStamp(info)
            else { throw ModelFailure.changed }
            inputs.append((file, SnapshotFileStamp(info)))
        }
        for (file, stamp) in inputs {
            try validate()
            var namedFolder = stat()
            var info = stat()
            guard fstatat(directory, name, &namedFolder, AT_SYMLINK_NOFOLLOW) == 0,
                namedFolder.st_dev == identity.st_dev, namedFolder.st_ino == identity.st_ino,
                namedFolder.st_birthtimespec.tv_sec == identity.st_birthtimespec.tv_sec,
                namedFolder.st_birthtimespec.tv_nsec == identity.st_birthtimespec.tv_nsec,
                fstatat(folder, file, &info, AT_SYMLINK_NOFOLLOW) == 0, SnapshotFileStamp(info) == stamp,
                unlinkat(folder, file, 0) == 0
            else { throw ModelFailure.changed }
        }
        guard fsync(folder) == 0 else { throw ModelFailure.changed }
        if unlinkat(directory, name, AT_REMOVEDIR) != 0, errno != ENOTEMPTY { throw ModelFailure.changed }
        guard fsync(directory) == 0 else { throw ModelFailure.changed }
    }

    private func trimClosedRecords() throws {
        try validate()
        let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey])
        try validate()
        var closed: [(String, Date)] = []
        for file in urls {
            let name = file.lastPathComponent
            guard name.hasPrefix("closed-"), name.hasSuffix(".json"),
                UUID(uuidString: String(name.dropFirst(7).dropLast(5))) != nil
            else { continue }
            let date =
                try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                ?? .distantPast
            closed.append((name, date))
        }
        closed.sort { $0.1 > $1.1 }
        for (index, item) in closed.enumerated()
        where index >= RecoveryBudget.records || Date().timeIntervalSince(item.1) > RecoveryBudget.days {
            guard let data = try Self.read(directory, name: item.0, limit: 2 * 1024 * 1024) else { continue }
            let record = try JSONDecoder().decode(MailPatchRecord.self, from: data)
            try Self.validateRecord(record, location: location)
            guard !record.phase.pending, item.0 == "closed-" + record.id.uuidString + ".json" else {
                throw ModelFailure.changed
            }
            try discardInputs(record)
            var before = stat()
            guard fstatat(directory, item.0, &before, AT_SYMLINK_NOFOLLOW) == 0,
                try Self.read(directory, name: item.0, limit: 2 * 1024 * 1024) == data
            else { throw ModelFailure.changed }
            try validate()
            var after = stat()
            guard fstatat(directory, item.0, &after, AT_SYMLINK_NOFOLLOW) == 0,
                SnapshotFileStamp(before) == SnapshotFileStamp(after), unlinkat(directory, item.0, 0) == 0,
                fsync(directory) == 0
            else { throw ModelFailure.changed }
        }
    }

    func persistMails(_ plan: MailPatchPlan, id: UUID) throws -> [URL] {
        try validate()
        guard mkdirat(directory, id.uuidString, 0o700) == 0 else { throw ModelFailure.changed }
        let target = openat(directory, id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard target >= 0 else { throw ModelFailure.changed }
        defer { Darwin.close(target) }
        var total = 0
        var urls: [URL] = []
        for (index, source) in plan.mails.enumerated() {
            let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw ModelFailure.changed }
            defer { Darwin.close(input) }
            var before = stat()
            guard fstat(input, &before) == 0, before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                before.st_size > 0, before.st_size <= PatchReadBudget.bytes - total
            else { throw ModelFailure.changed }
            let data =
                try FileHandle(fileDescriptor: input, closeOnDealloc: false).read(
                    upToCount: PatchReadBudget.bytes - total + 1) ?? Data()
            var after = stat()
            var named = stat()
            guard fstat(input, &after) == 0, lstat(source.path, &named) == 0,
                SnapshotFileStamp(before) == SnapshotFileStamp(after),
                SnapshotFileStamp(after) == SnapshotFileStamp(named), data.count == before.st_size,
                RecoveryFileIO.hash(data) == plan.entries[index].sha256
            else { throw ModelFailure.changed }
            total += data.count
            let name = String(format: "%04d", index + 1)
            let fd = openat(target, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ModelFailure.changed }
            defer { Darwin.close(fd) }
            try RecoveryFileIO.write(data, descriptor: fd, cancellation: IOCancellation())
            guard fsync(fd) == 0 else { throw ModelFailure.changed }
            urls.append(url.appending(path: id.uuidString).appending(path: name))
        }
        guard fsync(target) == 0, fsync(directory) == 0 else { throw ModelFailure.changed }
        return urls
    }
}
