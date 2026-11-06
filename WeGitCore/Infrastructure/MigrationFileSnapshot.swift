import CryptoKit
import Darwin
import Foundation
import SQLite3

public enum ApplicationMigrationFailure: Error, LocalizedError, Sendable {
    case invalid, changed, exceeded, database, timedOut, rollbackActive
    public var errorDescription: String? {
        switch self {
        case .invalid: L10n.text("迁移数据无法读取，原始数据已保留。")
        case .changed: L10n.text("迁移数据已变化，请核对后重试。")
        case .exceeded: L10n.text("迁移数据超过读取上限，原始数据已保留。")
        case .database: L10n.text("最近仓库数据库无法读取，原始数据已保留。")
        case .timedOut: L10n.text("迁移超过时间预算，原始数据已保留。")
        case .rollbackActive: L10n.text("已恢复旧版数据，继续使用 v2.0 需要明确恢复迁移。")
        }
    }
}

struct MigrationFileVersion: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let mode: UInt32
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let bornSeconds: Int64
    let bornNanoseconds: Int64
    init(_ value: stat) {
        device = UInt64(UInt32(bitPattern: value.st_dev))
        inode = value.st_ino
        size = value.st_size
        mode = UInt32(value.st_mode)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        bornSeconds = Int64(value.st_birthtimespec.tv_sec)
        bornNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
    }
}

struct MigrationStoreImage: Codable, Sendable {
    struct File: Codable, Sendable {
        let name: String
        let sourceVersion: MigrationFileVersion
        let sha256: String
        let bytes: Int
    }
    let source: URL?
    let sourceDirectory: MigrationDirectoryIdentity?
    let files: [File]
    var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }
}

public struct MigrationDirectoryIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let bornSeconds: Int64
    public let bornNanoseconds: Int64
    static func read(_ url: URL) throws -> Self? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ApplicationMigrationFailure.changed
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ApplicationMigrationFailure.invalid }
        return Self(
            device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino,
            bornSeconds: Int64(info.st_birthtimespec.tv_sec),
            bornNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
    }
}

public struct ApplicationStoreSnapshot: Codable, Sendable {
    public let sourceStoreURL: URL
    public let storeURL: URL
    public let sha256: String
    public let bytes: Int
}

public struct ApplicationStoreBackup: Codable, Sendable {
    public let sourceStoreURL: URL
    public let data: Data
    public let sha256: String
    public let directoryIdentity: MigrationDirectoryIdentity
    public let sourceFingerprint: String?
    public var bytes: Int { data.count }
    public init(
        sourceStoreURL: URL, data: Data, sha256: String, directoryIdentity: MigrationDirectoryIdentity,
        sourceFingerprint: String? = nil
    ) {
        self.sourceStoreURL = sourceStoreURL
        self.data = data
        self.sha256 = sha256
        self.directoryIdentity = directoryIdentity
        self.sourceFingerprint = sourceFingerprint
    }
}

public struct ApplicationStoreRestoreReceipt: Sendable {
    public let retainedStoreDirectory: URL
    public let restoredSHA256: String
}

enum MigrationFileSnapshot {
    static let maximumStoreBytes = 64 * 1024 * 1024
    static let maximumPreferencesBytes = 8 * 1024 * 1024
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func canonicalPath(_ url: URL) -> String {
        guard url.isFileURL, !url.path.contains("\0") else { return url.path }
        var candidate = url.standardizedFileURL
        var suffix: [String] = []
        while true {
            if let value = realpath(candidate.path, nil) {
                let base = String(cString: value)
                free(value)
                return suffix.reversed().reduce(URL(fileURLWithPath: base)) { $0.appending(path: $1) }.path
            }
            if candidate.path == "/" { return url.path }
            suffix.append(candidate.lastPathComponent)
            candidate.deleteLastPathComponent()
        }
    }
    static func storeFingerprint(_ source: URL) throws -> String {
        struct Entry: Encodable {
            let name: String
            let version: MigrationFileVersion?
            let dataSHA256: String?
        }
        struct Value: Encodable {
            let directory: MigrationDirectoryIdentity?
            let files: [Entry]
        }
        let parent = URL(
            fileURLWithPath: canonicalPath(source.deletingLastPathComponent()), isDirectory: true)
        let directory = try MigrationDirectoryIdentity.read(parent)
        let names = [
            source.lastPathComponent, source.lastPathComponent + "-wal", source.lastPathComponent + "-shm",
        ]
        var files: [Entry] = []
        var initial: [String: MigrationFileVersion] = [:]
        for name in names {
            if let value = try version(parent.appending(path: name)) { initial[name] = value }
        }
        guard initial.values.reduce(Int64(0), { $0 + max(0, $1.size) }) <= maximumStoreBytes else {
            throw ApplicationMigrationFailure.exceeded
        }
        for name in names {
            let url = parent.appending(path: name)
            let before = initial[name]
            let sha: String?
            if before != nil, !name.hasSuffix("-shm") {
                sha = digest(try read(url, limit: maximumStoreBytes))
            } else {
                sha = nil
            }
            guard try version(url) == before else { throw ApplicationMigrationFailure.changed }
            files.append(Entry(name: name, version: before, dataSHA256: sha))
        }
        for name in names {
            guard try version(parent.appending(path: name)) == initial[name] else {
                throw ApplicationMigrationFailure.changed
            }
        }
        guard try MigrationDirectoryIdentity.read(parent) == directory else {
            throw ApplicationMigrationFailure.changed
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(Value(directory: directory, files: files)))
    }
    static func check(_ started: TimeInterval) throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime - started < 2 else {
            throw ApplicationMigrationFailure.timedOut
        }
    }

    static func version(_ url: URL) throws -> MigrationFileVersion? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw ApplicationMigrationFailure.changed
        }
        guard value.st_mode & S_IFMT == S_IFREG else { throw ApplicationMigrationFailure.invalid }
        return MigrationFileVersion(value)
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        guard let expected = try version(url), expected.size >= 0, expected.size <= limit else {
            throw ApplicationMigrationFailure.exceeded
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ApplicationMigrationFailure.changed }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, MigrationFileVersion(before) == expected else {
            throw ApplicationMigrationFailure.changed
        }
        var data = Data()
        data.reserveCapacity(Int(expected.size))
        var bytes = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            try Task.checkCancellation()
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ApplicationMigrationFailure.changed }
            if count == 0 { break }
            guard data.count <= limit - count else { throw ApplicationMigrationFailure.exceeded }
            data.append(contentsOf: bytes.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, MigrationFileVersion(after) == expected,
            try version(url) == expected, Int64(data.count) == expected.size
        else { throw ApplicationMigrationFailure.changed }
        return data
    }

    static func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ApplicationMigrationFailure.changed }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ApplicationMigrationFailure.changed }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw ApplicationMigrationFailure.changed }
        try syncDirectory(url.deletingLastPathComponent())
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ApplicationMigrationFailure.changed }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ApplicationMigrationFailure.changed }
    }

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
            throw ApplicationMigrationFailure.invalid
        }
    }

    static func capture(_ source: URL?, into directory: URL, started: TimeInterval) throws
        -> MigrationStoreImage
    {
        try makeDirectory(directory)
        guard let source else { return MigrationStoreImage(source: nil, sourceDirectory: nil, files: []) }
        let names = [
            source.lastPathComponent, source.lastPathComponent + "-wal", source.lastPathComponent + "-shm",
        ]
        let parent = source.deletingLastPathComponent().resolvingSymlinksInPath()
        let sourceDirectory = try MigrationDirectoryIdentity.read(parent)
        var before: [String: MigrationFileVersion] = [:]
        for name in names {
            if let value = try version(parent.appending(path: name)) { before[name] = value }
        }
        guard before.isEmpty || before[source.lastPathComponent] != nil else {
            throw ApplicationMigrationFailure.database
        }
        guard before.values.reduce(Int64(0), { $0 + max(0, $1.size) }) <= maximumStoreBytes else {
            throw ApplicationMigrationFailure.exceeded
        }
        var files: [MigrationStoreImage.File] = []
        for name in names where before[name] != nil {
            try check(started)
            let bytes = try read(parent.appending(path: name), limit: maximumStoreBytes)
            guard try version(parent.appending(path: name)) == before[name] else {
                throw ApplicationMigrationFailure.changed
            }
            try writeExclusive(bytes, to: directory.appending(path: name))
            files.append(
                .init(name: name, sourceVersion: before[name]!, sha256: digest(bytes), bytes: bytes.count))
        }
        let image = MigrationStoreImage(
            source: parent.appending(path: source.lastPathComponent),
            sourceDirectory: sourceDirectory, files: files)
        try verifySource(image, started: started)
        return image
    }

    static func verifySource(_ image: MigrationStoreImage, started: TimeInterval) throws {
        guard let source = image.source else { return }
        guard try MigrationDirectoryIdentity.read(source.deletingLastPathComponent()) == image.sourceDirectory
        else {
            throw ApplicationMigrationFailure.changed
        }
        let names = [
            source.lastPathComponent, source.lastPathComponent + "-wal", source.lastPathComponent + "-shm",
        ]
        for name in names {
            try check(started)
            let expected = image.files.first { $0.name == name }
            let current = try version(source.deletingLastPathComponent().appending(path: name))
            guard current == expected?.sourceVersion else { throw ApplicationMigrationFailure.changed }
            if let expected {
                let bytes = try read(
                    source.deletingLastPathComponent().appending(path: name), limit: maximumStoreBytes)
                guard digest(bytes) == expected.sha256 else { throw ApplicationMigrationFailure.changed }
            }
        }
    }

    static func verifyArchive(_ image: MigrationStoreImage, directory: URL) throws {
        guard image.files.count <= 3, image.files.allSatisfy({ (0...maximumStoreBytes).contains($0.bytes) }),
            image.totalBytes <= maximumStoreBytes
        else {
            throw ApplicationMigrationFailure.invalid
        }
        let base = image.source?.lastPathComponent ?? "Repositories.store"
        let names: Set<String> = [base, base + "-wal", base + "-shm"]
        guard Set(image.files.map(\.name)).count == image.files.count else {
            throw ApplicationMigrationFailure.invalid
        }
        for file in image.files {
            guard names.contains(file.name), file.bytes >= 0 else {
                throw ApplicationMigrationFailure.invalid
            }
            let bytes = try read(directory.appending(path: file.name), limit: maximumStoreBytes)
            guard bytes.count == file.bytes, digest(bytes) == file.sha256 else {
                throw ApplicationMigrationFailure.changed
            }
        }
    }

    /// SQLite only opens this task-owned input copy. The original DB and sealed raw
    /// archive are not SQLite-opened, because even READONLY WAL access can change SHM.
    static func databaseBackup(from source: URL, to destination: URL, started: TimeInterval) throws {
        let header = try read(source, limit: maximumStoreBytes)
        guard header.prefix(16) == Data("SQLite format 3\0".utf8) else {
            throw ApplicationMigrationFailure.database
        }
        guard try version(destination) == nil else { throw ApplicationMigrationFailure.changed }
        var input: OpaquePointer?
        var output: OpaquePointer?
        guard
            sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
                == SQLITE_OK,
            let input
        else {
            if let input { sqlite3_close_v2(input) }
            throw ApplicationMigrationFailure.database
        }
        defer { sqlite3_close_v2(input) }
        guard
            sqlite3_open_v2(
                destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
                nil) == SQLITE_OK,
            let output
        else {
            if let output { sqlite3_close_v2(output) }
            throw ApplicationMigrationFailure.database
        }
        defer { sqlite3_close_v2(output) }
        sqlite3_busy_timeout(input, 50)
        sqlite3_busy_timeout(output, 50)
        guard sqlite3_exec(input, "BEGIN", nil, nil, nil) == SQLITE_OK,
            let backup = sqlite3_backup_init(output, "main", input, "main")
        else { throw ApplicationMigrationFailure.database }
        var finished = false
        defer {
            if !finished { sqlite3_backup_finish(backup) }
            sqlite3_exec(input, "ROLLBACK", nil, nil, nil)
        }
        while true {
            try check(started)
            let result = sqlite3_backup_step(backup, 256)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_OK else { throw ApplicationMigrationFailure.database }
        }
        guard sqlite3_backup_finish(backup) == SQLITE_OK else { throw ApplicationMigrationFailure.database }
        finished = true
        guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw ApplicationMigrationFailure.database
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(output, "PRAGMA quick_check(1)", -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw ApplicationMigrationFailure.database }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
            String(cString: text) == "ok", sqlite3_step(statement) == SQLITE_DONE
        else { throw ApplicationMigrationFailure.database }
        try check(started)
    }
}
