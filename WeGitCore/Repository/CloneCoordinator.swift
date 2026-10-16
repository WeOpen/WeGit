import Darwin
import Foundation

public struct CloneRequest: Sendable {
    public let address: String
    public let parent: URL
    public let folderName: String
    public init(address: String, parent: URL, folderName: String) {
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.parent = parent
        self.folderName = folderName
    }

    public func validatedDestination() throws -> URL {
        guard !address.isEmpty, !address.hasPrefix("-"), !address.contains("\0"),
            !folderName.isEmpty, folderName != ".", folderName != "..",
            !folderName.contains("/"), !folderName.contains("\0")
        else { throw ModelFailure.unsupported(L10n.text("请输入有效的仓库地址和单个文件夹名称。")) }
        if let components = URLComponents(string: address) {
            let http = ["http", "https"].contains(components.scheme?.lowercased() ?? "")
            let secretQuery =
                components.queryItems?.contains {
                    ["token", "access_token", "password", "auth", "authorization"].contains(
                        $0.name.lowercased())
                } ?? false
            guard components.password == nil, !(http && components.user != nil), !secretQuery else {
                throw ModelFailure.unsupported(L10n.text("请使用不含密码或 Token 的地址，通过系统凭证认证。"))
            }
        }
        let directory = parent.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue, FileManager.default.isWritableFile(atPath: directory.path)
        else { throw ModelFailure.unsupported(L10n.text("请选择已存在且可写的保存目录。")) }
        return directory.appendingPathComponent(folderName, isDirectory: true)
    }
}

public struct CloneProgress: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case connecting, enumerating, counting, compressing, receiving, resolving, checkingOut, validating
        public var title: String {
            switch self {
            case .connecting: L10n.text("连接仓库")
            case .enumerating: L10n.text("枚举对象")
            case .counting: L10n.text("统计对象")
            case .compressing: L10n.text("压缩对象")
            case .receiving: L10n.text("接收对象")
            case .resolving: L10n.text("解析增量")
            case .checkingOut: L10n.text("检出文件")
            case .validating: L10n.text("检查克隆结果")
            }
        }
    }
    public let stage: Stage
    /// This is the current Git stage's fraction, never an estimated overall clone percentage.
    public let fraction: Double?
    public init(stage: Stage, fraction: Double? = nil) {
        self.stage = stage
        self.fraction = fraction
    }
}

/// Keeps partial CR/LF records across arbitrary pipe chunks. Only recognised stage data leaves this parser.
public struct CloneProgressParser: Sendable {
    private var pending = Data()
    private var previous: CloneProgress?
    public init() {}

    public mutating func consume(_ data: Data) -> [CloneProgress] {
        var result: [CloneProgress] = []
        for byte in data {
            if byte == 10 || byte == 13 {
                if let progress = Self.parse(String(decoding: pending, as: UTF8.self)), progress != previous {
                    result.append(progress)
                    previous = progress
                }
                pending.removeAll(keepingCapacity: true)
            } else if pending.count < 4096 {
                pending.append(byte)
            }
        }
        return result
    }

    private static func parse(_ line: String) -> CloneProgress? {
        let stages: [(String, CloneProgress.Stage)] = [
            ("Enumerating objects:", .enumerating), ("Counting objects:", .counting),
            ("Compressing objects:", .compressing), ("Receiving objects:", .receiving),
            ("Resolving deltas:", .resolving), ("Updating files:", .checkingOut),
            ("Checking out files:", .checkingOut), ("Filtering content:", .checkingOut),
        ]
        for (prefix, stage) in stages {
            guard let range = line.range(of: prefix) else { continue }
            let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let digits = tail.prefix(while: \.isNumber)
            let remaining = tail.dropFirst(digits.count)
            let fraction =
                remaining.hasPrefix("%")
                ? Int(digits).flatMap { (0...100).contains($0) ? Double($0) / 100 : nil } : nil
            return CloneProgress(stage: stage, fraction: fraction)
        }
        return nil
    }
}

private final class CloneProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = CloneProgressParser()
    let receive: @Sendable (CloneProgress) -> Void
    init(_ receive: @escaping @Sendable (CloneProgress) -> Void) { self.receive = receive }
    func consume(_ data: Data) {
        let updates = lock.withLock { parser.consume(data) }
        // A pipe read may contain many overwritten terminal progress records; expose its latest stage.
        if let last = updates.last { receive(last) }
    }
}

public struct CloneCleanupToken: Identifiable, Sendable {
    public let id: UUID
    public let directory: URL
    fileprivate let snapshot: DirectorySnapshot
}

public struct CloneFailure: Error, LocalizedError, Sendable {
    public let message: String
    public let details: String
    public let retainedDirectory: URL?
    public let cleanup: CloneCleanupToken?
    public var errorDescription: String? { message }
}

public protocol FileTrashing: Sendable {
    func moveToTrash(_ url: URL) throws -> URL?
}

public struct SystemTrash: FileTrashing {
    public init() {}
    public func moveToTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

public actor CloneCoordinator {
    private let engine: GitEngine
    private let trash: any FileTrashing
    private var running = false
    private var pendingCleanup: [UUID: CloneCleanupToken] = [:]

    public init(engine: GitEngine, trash: any FileTrashing = SystemTrash()) {
        self.engine = engine
        self.trash = trash
    }

    public func clone(
        _ request: CloneRequest,
        onProgress: @escaping @Sendable (CloneProgress) -> Void = { _ in }
    ) async throws -> RepositoryLocation {
        guard !running else { throw ModelFailure.unsupported(L10n.text("已有克隆操作正在进行，请等待或取消该操作。")) }
        try Task.checkCancellation()
        let destination = try request.validatedDestination()
        // mkdir is atomic: an already existing empty directory, file or symlink is never taken over.
        guard mkdir(destination.path, 0o700) == 0 else {
            throw ModelFailure.unsupported(L10n.text("目标已存在或无法创建。请选择另一个文件夹名称。"))
        }
        let identity = try FileStamp.read(destination)
        running = true
        defer { running = false }
        onProgress(CloneProgress(stage: .connecting))
        let sink = CloneProgressSink(onProgress)
        do {
            _ = try await engine.run(
                ["clone", "--progress", "--", request.address, destination.path],
                timeout: 600, onStderr: { sink.consume($0) }, activityRepository: destination)
            try Task.checkCancellation()
            onProgress(CloneProgress(stage: .validating))
            let result = try await RepositoryService.discover(destination, engine: engine)
            try Task.checkCancellation()
            return result
        } catch {
            // Only record ownership after the process has stopped. Never auto-delete a failed clone.
            let snapshot = try? DirectorySnapshot.capture(destination)
            let owned = (try? FileStamp.read(destination))?.sameObject(as: identity) == true
            let token =
                owned
                ? snapshot.map { CloneCleanupToken(id: UUID(), directory: destination, snapshot: $0) } : nil
            if let token { pendingCleanup[token.id] = token }
            throw CloneFailure(
                message: error is CancellationError
                    ? L10n.text("操作已取消。未完成的目录会保留供检查。") : error.localizedDescription,
                details: (error as? GitFailure)?.details ?? "",
                retainedDirectory: owned ? destination : nil, cleanup: token)
        }
    }

    public func forgetCleanup(_ token: CloneCleanupToken) {
        pendingCleanup.removeValue(forKey: token.id)
    }

    /// Call only after the UI confirms this exact failed operation and destination.
    public func cleanUp(_ token: CloneCleanupToken) throws -> URL? {
        guard let saved = pendingCleanup[token.id], saved.directory == token.directory else {
            throw ModelFailure.unsupported(L10n.text("此目录没有有效的克隆归属记录，请在 Finder 中检查。"))
        }
        let now = try DirectorySnapshot.capture(saved.directory)
        guard now == saved.snapshot else {
            throw ModelFailure.unsupported(L10n.text("目录在克隆失败后发生了变化，已保留全部内容。请在 Finder 中检查。"))
        }
        let result = try trash.moveToTrash(saved.directory)
        pendingCleanup.removeValue(forKey: token.id)
        return result
    }
}

private struct FileStamp: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int

    static func read(_ url: URL) throws -> FileStamp {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ModelFailure.changed }
        return FileStamp(
            device: info.st_dev, inode: info.st_ino, mode: info.st_mode, size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }
    func sameObject(as other: FileStamp) -> Bool {
        device == other.device && inode == other.inode
            && (mode & UInt16(S_IFMT)) == (other.mode & UInt16(S_IFMT))
    }
}

private struct DirectorySnapshot: Equatable, Sendable {
    let entries: [String: FileStamp]
    static func capture(_ root: URL) throws -> DirectorySnapshot {
        let before = try FileStamp.read(root)
        guard before.mode & UInt16(S_IFMT) == UInt16(S_IFDIR) else { throw ModelFailure.changed }
        var result = ["": before]
        var enumerationFailed = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: .producesRelativePathURLs,
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                })
        else { throw ModelFailure.changed }
        for case let file as URL in enumerator {
            // Bound the recovery snapshot; very large failures remain available in Finder for manual review.
            guard result.count < 20_000 else {
                throw ModelFailure.unsupported(L10n.text("目录过大，请在 Finder 中处理。"))
            }
            let path = file.relativePath
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw ModelFailure.changed
            }
            result[path] = try FileStamp.read(root.appendingPathComponent(path))
        }
        guard !enumerationFailed, try FileStamp.read(root) == before else { throw ModelFailure.changed }
        return DirectorySnapshot(entries: result)
    }
}
