import Darwin
import Foundation

public struct CloneOptions: Sendable, Equatable {
    public let branch: String?
    public let singleBranch: Bool
    public let depth: Int?
    public let recurseSubmodules: Bool
    public init(
        branch: String? = nil, singleBranch: Bool = false, depth: Int? = nil, recurseSubmodules: Bool = false
    ) {
        self.branch = branch
        self.singleBranch = singleBranch
        self.depth = depth
        self.recurseSubmodules = recurseSubmodules
    }
    func validated() throws {
        guard depth == nil || (1...Int(Int32.max)).contains(depth!) else { throw ModelFailure.invalidPath }
        if let branch {
            guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.contains("\0"), !branch.contains("@{")
            else { throw ModelFailure.invalidPath }
        }
    }
    var arguments: [String] {
        var result: [String] = []
        if let branch { result += ["--branch", branch] }
        if singleBranch {
            result.append("--single-branch")
        } else if depth != nil {
            result.append("--no-single-branch")
        }
        if let depth { result += ["--depth", String(depth)] }
        if depth != nil { result.append("--no-local") }
        result.append(recurseSubmodules ? "--recurse-submodules" : "--no-recurse-submodules")
        return result
    }
}

public struct CloneRequest: Sendable {
    public let address: String
    public let parent: URL
    public let folderName: String
    public let options: CloneOptions
    public init(address: String, parent: URL, folderName: String, options: CloneOptions = CloneOptions()) {
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.parent = parent
        self.folderName = folderName
        self.options = options
    }

    public func validatedDestination() throws -> URL {
        try options.validated()
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
        running = true
        defer { running = false }
        try Task.checkCancellation()
        let destination = try request.validatedDestination()
        let parent = destination.deletingLastPathComponent()
        let parentIdentity = try RepositoryNodeIdentity.read(parent, directory: true)
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw ModelFailure.changed }
        defer { Darwin.close(parentFD) }
        var parentInfo = stat()
        guard fstat(parentFD, &parentInfo) == 0, parentInfo.st_dev == parentIdentity.device,
            parentInfo.st_ino == parentIdentity.inode,
            parentInfo.st_birthtimespec.tv_sec == parentIdentity.bornSeconds,
            parentInfo.st_birthtimespec.tv_nsec == parentIdentity.bornNanoseconds
        else { throw ModelFailure.changed }
        var entry = stat()
        guard fstatat(parentFD, request.folderName, &entry, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw ModelFailure.unsupported(L10n.text("目标已存在或无法创建。请选择另一个文件夹名称。"))
        }
        if let branch = request.options.branch {
            let checked = try await engine.run(["check-ref-format", "--branch", branch], in: parent).text
                .removingLastNewline
            guard checked == branch else { throw ModelFailure.invalidPath }
        }
        // Clone into an operation-owned sibling. Publish by exclusive rename;
        // a destination that arrives during download never receives Git writes.
        let name = ".WeGit-clone-" + UUID().uuidString
        guard mkdirat(parentFD, name, 0o700) == 0 else { throw ModelFailure.changed }
        let staging = parent.appending(path: name, directoryHint: .isDirectory)
        let identity = try FileStamp.read(staging)
        let stagingFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stagingFD >= 0 else { throw ModelFailure.changed }
        defer { Darwin.close(stagingFD) }
        var published = false
        onProgress(CloneProgress(stage: .connecting))
        let sink = CloneProgressSink(onProgress)
        do {
            _ = try await engine.run(
                ["clone", "--progress"] + request.options.arguments + ["--", request.address, staging.path],
                timeout: 600, onStderr: { sink.consume($0) }, activityRepository: destination)
            try Task.checkCancellation()
            onProgress(CloneProgress(stage: .validating))
            guard try FileStamp.read(staging).sameObject(as: identity),
                try RepositoryNodeIdentity.read(parent, directory: true) == parentIdentity
            else { throw ModelFailure.changed }
            _ = try await RepositoryService.discover(staging, engine: engine)
            try Task.checkCancellation()
            guard renameatx_np(parentFD, name, parentFD, request.folderName, UInt32(RENAME_EXCL)) == 0,
                fsync(parentFD) == 0
            else { throw ModelFailure.changed }
            published = true
            let result = try await RepositoryService.discover(destination, engine: engine)
            guard try FileStamp.read(destination).sameObject(as: identity),
                try RepositoryNodeIdentity.read(parent, directory: true) == parentIdentity
            else { throw ModelFailure.changed }
            return result
        } catch {
            // Only record ownership after the process has stopped. Never auto-delete a failed clone.
            if !published, (try? FileStamp.read(staging))?.sameObject(as: identity) == true,
                (try? RepositoryNodeIdentity.read(parent, directory: true)) == parentIdentity,
                renameatx_np(parentFD, name, parentFD, request.folderName, UInt32(RENAME_EXCL)) == 0
            {
                published = true
                _ = fsync(parentFD)
            }
            let retained = WorktreePreservationDirectory.path(
                for: stagingFD, fallback: published ? destination : staging)
            let snapshot = try? DirectorySnapshot.capture(retained)
            let owned = (try? FileStamp.read(retained))?.sameObject(as: identity) == true
            let token =
                owned
                ? snapshot.map { CloneCleanupToken(id: UUID(), directory: retained, snapshot: $0) } : nil
            if let token { pendingCleanup[token.id] = token }
            throw CloneFailure(
                message: error is CancellationError
                    ? L10n.text("操作已取消。未完成的目录会保留供检查。") : error.localizedDescription,
                details: (error as? GitFailure)?.details ?? "",
                retainedDirectory: owned ? retained : nil, cleanup: token)
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
    let bornSeconds: Int
    let bornNanos: Int

    static func read(_ url: URL) throws -> FileStamp {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ModelFailure.changed }
        return FileStamp(
            device: info.st_dev, inode: info.st_ino, mode: info.st_mode, size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec,
            bornSeconds: info.st_birthtimespec.tv_sec, bornNanos: info.st_birthtimespec.tv_nsec)
    }
    func sameObject(as other: FileStamp) -> Bool {
        device == other.device && inode == other.inode
            && (mode & UInt16(S_IFMT)) == (other.mode & UInt16(S_IFMT))
            && bornSeconds == other.bornSeconds && bornNanos == other.bornNanos
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
