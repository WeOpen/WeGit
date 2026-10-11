import CryptoKit
import Darwin
import Foundation

/// Private, process-owned storage. Cancellation and releasing the last snapshot remove the
/// directory only while its identity still matches the directory this process created.
final class SnapshotDirectory: @unchecked Sendable {
    let url: URL
    private let device: dev_t
    private let inode: ino_t

    init() throws {
        let root = try DiffSnapshotStorage.root()
        let template = root.appending(path: "snapshot-\(getpid())-XXXXXX").path
        var bytes = Array(template.utf8CString)
        guard mkdtemp(&bytes) != nil else { throw ProcessFailure.outputWrite(errno) }
        url = URL(
            fileURLWithPath: String(
                decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ProcessFailure.outputWrite(errno) }
        device = info.st_dev
        inode = info.st_ino
    }

    deinit {
        let path = url
        let device = device
        let inode = inode
        DispatchQueue.global(qos: .utility).async {
            var info = stat()
            if lstat(path.path, &info) == 0, info.st_dev == device, info.st_ino == inode {
                try? FileManager.default.removeItem(at: path)
            }
        }
    }
}

public enum DiffSnapshotStorage {
    static func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "org.weopen.WeGit.snapshots")
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw ProcessFailure.outputWrite(errno) }
        try validateRoot(url)
        return url
    }

    private static func validateRoot(_ root: URL) throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR),
            info.st_uid == getuid(), info.st_mode & 0o077 == 0
        else { throw ModelFailure.unsupported("差异缓存目录的类型或权限异常，请检查临时目录。") }
    }

    /// Only dead-process directories in the private cache are eligible. A running app,
    /// including a different build of WeGit, keeps ownership of all its snapshots.
    public static func removeAbandoned() async throws {
        let root = try root()
        try await removeAbandoned(in: root)
    }

    static func removeAbandoned(in root: URL) async throws {
        try await SnapshotIO.run { cancellation in
            try validateRoot(root)
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            {
                try cancellation.check()
                let pieces = url.lastPathComponent.split(separator: "-")
                guard pieces.count == 3, pieces[0] == "snapshot", pieces[2].count == 6,
                    pieces[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                    let pid = pid_t(pieces[1]), pid > 0, pid != getpid()
                else { continue }
                guard kill(pid, 0) == -1, errno == ESRCH else { continue }
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR),
                    info.st_uid == getuid(), info.st_mode & 0o077 == 0
                else { continue }
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}

final class IOCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

enum SnapshotIO {
    static func run<T: Sendable>(_ operation: @escaping @Sendable (IOCancellation) throws -> T) async throws
        -> T
    {
        let cancellation = IOCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try operation(cancellation)) } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

struct SnapshotFileStamp: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

/// No file contents are stored in this value. Each page opens a validated read descriptor.
struct SnapshotFile: Sendable {
    let directory: SnapshotDirectory
    let url: URL
    let stamp: SnapshotFileStamp

    init(directory: SnapshotDirectory, url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            info.st_size >= 0
        else { throw ModelFailure.changed }
        self.directory = directory
        self.url = url
        stamp = SnapshotFileStamp(info)
    }

    func open() throws -> Int32 {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        do { try validate(fd) } catch {
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    func validate(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, SnapshotFileStamp(info) == stamp else {
            throw ModelFailure.changed
        }
    }
}

struct SnapshotLine: Sendable {
    let offset: Int
    let nextOffset: Int
    let prefix: Data
    let terminated: Bool
    var byteCount: Int { nextOffset - offset - (terminated ? 1 : 0) }
    var truncated: Bool { byteCount > prefix.count }
}

/// A 64 KiB input buffer and bounded line prefix allow even one enormous line to be scanned
/// without allocating that line. Callers own this reader on a dedicated SnapshotIO queue.
final class SnapshotLineReader {
    private let file: SnapshotFile
    private let descriptor: Int32
    private let cancellation: IOCancellation
    private let hashes: Bool
    private let chunkSize: Int
    private var buffer = Data()
    private var position = 0
    private var cursor: Int
    private var eof = false
    private var hash = SHA256()
    private var encoding = UTF8Validation()
    private(set) var containsNUL = false
    private(set) var bytesRead = 0

    init(
        file: SnapshotFile, offset: Int = 0, hashes: Bool = false, chunkSize: Int = 64 * 1024,
        cancellation: IOCancellation
    ) throws {
        guard offset >= 0, offset <= file.stamp.size else { throw ModelFailure.changed }
        self.file = file
        self.cancellation = cancellation
        self.hashes = hashes
        self.chunkSize = min(64 * 1024, max(4096, chunkSize))
        cursor = offset
        let fd = try file.open()
        if lseek(fd, off_t(offset), SEEK_SET) < 0 {
            Darwin.close(fd)
            throw ModelFailure.changed
        }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }

    func next(prefixLimit: Int = 8192) throws -> SnapshotLine? {
        let start = cursor
        var prefix = Data()
        var terminated = false
        while true {
            try cancellation.check()
            if position == buffer.count {
                if eof { break }
                var bytes = [UInt8](repeating: 0, count: chunkSize)
                var count: Int
                repeat {
                    count = Darwin.read(descriptor, &bytes, bytes.count)
                } while count < 0 && errno == EINTR
                guard count >= 0 else { throw ProcessFailure.outputWrite(errno) }
                if count == 0 {
                    eof = true
                    break
                }
                bytesRead += count
                buffer = Data(bytes.prefix(count))
                position = 0
                if hashes {
                    hash.update(data: buffer)
                    encoding.consume(buffer)
                    containsNUL = containsNUL || buffer.contains(0)
                }
            }
            let newline = buffer[position...].firstIndex(of: 10)
            let end = newline.map { $0 + 1 } ?? buffer.count
            let prefixEnd = min(end, position + max(0, prefixLimit - prefix.count))
            if prefixEnd > position { prefix.append(buffer[position..<prefixEnd]) }
            cursor += end - position
            position = end
            if newline != nil {
                terminated = true
                break
            }
        }
        guard cursor > start else { return nil }
        if terminated && prefix.count == cursor - start { prefix.removeLast() }
        return SnapshotLine(offset: start, nextOffset: cursor, prefix: prefix, terminated: terminated)
    }

    func validate() throws {
        try cancellation.check()
        try file.validate(descriptor)
    }
    var digest: String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
    var validUTF8: Bool { encoding.valid && encoding.remaining == 0 }
}

struct UTF8Validation {
    var valid = true
    var remaining = 0
    private var lower: UInt8 = 0x80
    private var upper: UInt8 = 0xBF

    mutating func consume(_ data: Data) {
        guard valid else { return }
        for byte in data {
            if remaining > 0 {
                guard (lower...upper).contains(byte) else {
                    valid = false
                    return
                }
                remaining -= 1
                lower = 0x80
                upper = 0xBF
                continue
            }
            switch byte {
            case 0...0x7F: continue
            case 0xC2...0xDF: remaining = 1
            case 0xE0:
                remaining = 2
                lower = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF: remaining = 2
            case 0xED:
                remaining = 2
                upper = 0x9F
            case 0xF0:
                remaining = 3
                lower = 0x90
            case 0xF1...0xF3: remaining = 3
            case 0xF4:
                remaining = 3
                upper = 0x8F
            default:
                valid = false
                return
            }
        }
    }
}
