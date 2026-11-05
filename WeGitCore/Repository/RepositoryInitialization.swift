import Darwin
import Foundation

public struct RepositoryInitializationRequest: Sendable {
    public let directory: URL
    public let branch: String
    public init(directory: URL, branch: String = "main") {
        self.directory = directory
        self.branch = branch
    }
}

public struct RepositoryInitializationPlan: Identifiable, Sendable {
    public let id: UUID
    public let directory: URL
    public let branch: String
    let identity: RepositoryNodeIdentity
}

public struct RepositoryInitializationFailure: Error, LocalizedError, Sendable {
    public let message: String
    public let createdDirectory: URL?
    public let retainedSetupDirectory: URL?
    public var errorDescription: String? { message }
}

/// Initialize away from ordinary files, then publish only a new .git directory.
/// A foreign .git that arrives after preview is never reinitialized or replaced.
public actor RepositoryInitializationCoordinator {
    private let engine: GitEngine
    private var running = false
    public init(engine: GitEngine) { self.engine = engine }

    public func prepare(_ request: RepositoryInitializationRequest) async throws
        -> RepositoryInitializationPlan
    {
        let directory = request.directory.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.isFileURL, FileManager.default.isWritableFile(atPath: directory.path),
            !request.branch.isEmpty, !request.branch.hasPrefix("-"), !request.branch.contains("\0"),
            !request.branch.contains("@{")
        else { throw ModelFailure.unsupported(L10n.text("请选择可写目录并输入有效的初始分支名称。")) }
        let identity = try RepositoryNodeIdentity.read(directory, directory: true)
        try await validateDestination(directory, identity: identity)
        let branch = try await engine.run(["check-ref-format", "--branch", request.branch], in: directory)
            .text.removingLastNewline
        guard branch == request.branch else { throw ModelFailure.invalidPath }
        try await validateDestination(directory, identity: identity)
        return RepositoryInitializationPlan(
            id: UUID(), directory: directory, branch: branch, identity: identity)
    }

    public func initialize(_ plan: RepositoryInitializationPlan) async throws -> RepositoryLocation {
        guard !running else { throw ModelFailure.unsupported(L10n.text("已有仓库建立操作正在进行，请等待或取消。")) }
        running = true
        defer { running = false }
        try Task.checkCancellation()
        try await validateDestination(plan.directory, identity: plan.identity)
        let target = try InitializationDirectory(plan.directory, expected: plan.identity)
        let stagingURL = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: plan.directory, create: true)
        let staging = try InitializationDirectory(stagingURL)
        var published: RepositoryNodeIdentity?
        var retained: URL?
        var cleanupAttempted = false
        defer { if !cleanupAttempted { _ = staging.removeIfOwned() } }
        do {
            // Ordinary init preserves Git templates/configuration, but all their
            // writes stay in this operation's private replacement directory.
            _ = try await engine.run(
                ["init", "--initial-branch=" + plan.branch, "--", staging.url.path],
                in: staging.url, timeout: 60)
            try Task.checkCancellation()
            try staging.validate()
            let git = try RepositoryNodeIdentity.read(staging.url.appending(path: ".git"), directory: true)
            try await validateDestination(plan.directory, identity: plan.identity)
            try target.validate()
            guard
                renameatx_np(staging.descriptor, ".git", target.descriptor, ".git", UInt32(RENAME_EXCL)) == 0
            else {
                throw ModelFailure.changed
            }
            published = git
            guard fsync(target.descriptor) == 0 else { throw ProcessFailure.outputWrite(errno) }
            let location = try await RepositoryService.discover(plan.directory, engine: engine)
            guard location.rootIdentity == plan.identity, location.gitIdentity == git else {
                throw ModelFailure.changed
            }
            let status = try await RepositoryService(location: location, engine: engine).status()
            guard status.head == nil, status.branch == plan.branch else { throw ModelFailure.changed }
            return location
        } catch {
            // Cancellation after publish is a created repository, not a rollback.
            // Never remove its metadata or restart init without another inspection.
            let created = published != nil ? target.actualURL : nil
            let message =
                created == nil
                ? L10n.text("仓库尚未建立；原目录内容保留。")
                : L10n.text("仓库元数据已建立，打开结果需要核对；请重新打开该目录。")
            let details = Redaction.text((error as? GitFailure)?.details ?? error.localizedDescription)
            cleanupAttempted = true
            if !staging.removeIfOwned() { retained = staging.actualURL }
            throw RepositoryInitializationFailure(
                message: message + "\n" + details,
                createdDirectory: created, retainedSetupDirectory: retained)
        }
    }

    private func validateDestination(_ directory: URL, identity: RepositoryNodeIdentity) async throws {
        try Task.checkCancellation()
        guard try RepositoryNodeIdentity.read(directory, directory: true) == identity,
            try RepositoryNodeIdentity.readIfPresent(directory.appending(path: ".git")) == nil
        else { throw ModelFailure.unsupported(L10n.text("目录已变化或已有 Git 元数据，请重新选择。")) }
        let result = try await engine.run(
            ["rev-parse", "--absolute-git-dir"], in: directory,
            accepted: [0, 128], outputLimit: 8192)
        guard result.exitCode == 128 else {
            throw ModelFailure.unsupported(L10n.text("此目录已经位于仓库中，不会隐式建立嵌套仓库。"))
        }
        let error = String(decoding: result.stderr, as: UTF8.self)
        guard error.hasPrefix("fatal: not a git repository") else { throw ModelFailure.changed }
        guard try RepositoryNodeIdentity.read(directory, directory: true) == identity else {
            throw ModelFailure.changed
        }
    }
}

private final class InitializationDirectory {
    let url: URL
    let descriptor: Int32
    private let identity: RepositoryNodeIdentity
    init(_ url: URL, expected: RepositoryNodeIdentity? = nil) throws {
        self.url = url
        identity = try RepositoryNodeIdentity.read(url, directory: true)
        guard expected == nil || identity == expected else { throw ModelFailure.changed }
        descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ModelFailure.changed }
        do { try validate() } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
    deinit { Darwin.close(descriptor) }
    func validate() throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode,
            info.st_birthtimespec.tv_sec == identity.bornSeconds,
            info.st_birthtimespec.tv_nsec == identity.bornNanoseconds,
            try RepositoryNodeIdentity.read(url, directory: true) == identity
        else { throw ModelFailure.changed }
    }
    var actualURL: URL { WorktreePreservationDirectory.path(for: descriptor, fallback: url) }
    func removeIfOwned() -> Bool {
        guard (try? RepositoryNodeIdentity.read(url, directory: true)) == identity else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch { return false }
    }
}
