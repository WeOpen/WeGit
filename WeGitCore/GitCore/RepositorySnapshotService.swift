import Darwin
import Foundation

extension RepositoryService {
    public func readSnapshot(
        scope requested: RepositoryRefreshScope = .all,
        previousHead: String? = nil, previousBranch: String? = nil
    ) async throws -> RepositoryReadSnapshot {
        try await queue.perform {
            // A CLI read sequence is not an atomic Git snapshot. Retry a bounded number
            // of times if HEAD, branch identity or index changes while reading it.
            for _ in 0..<3 {
                try Task.checkCancellation()
                try location.validateIdentity()
                let index = try IndexVersion.read(location.gitDirectory.appending(path: "index"))
                let state = try await status()
                var scope = requested
                if state.head != previousHead || state.branch != previousBranch {
                    scope.formUnion([.status, .references, .history, .diff])
                }
                let refs = scope.contains(.references) ? try await branches() : nil
                let remotes = scope.contains(.configuration) ? try await remotes() : nil
                let finalHead = try await head()
                let symbolic = try await engine.run(
                    ["symbolic-ref", "--quiet", "HEAD"], in: location.root,
                    accepted: [0, 1]
                ).text.removingLastNewline
                let finalBranch =
                    symbolic.hasPrefix("refs/heads/")
                    ? String(symbolic.dropFirst("refs/heads/".count)) : "(detached)"
                let current = refs?.first { $0.current }
                guard state.head == finalHead, state.branch == finalBranch,
                    index == (try IndexVersion.read(location.gitDirectory.appending(path: "index"))),
                    current == nil || (current?.oid == state.head && current?.name == state.branch)
                else { continue }
                try location.validateIdentity()
                return RepositoryReadSnapshot(
                    status: state, branches: refs, remotes: remotes, scope: scope, readAt: Date())
            }
            throw ModelFailure.changed
        }
    }
}

private struct IndexVersion: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let seconds: Int
    let nanos: Int

    static func read(_ url: URL) throws -> Self? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw ModelFailure.unsupported("无法检查 Git 索引，请确认仓库权限。")
        }
        return Self(
            device: info.st_dev, inode: info.st_ino, size: info.st_size,
            seconds: info.st_mtimespec.tv_sec, nanos: info.st_mtimespec.tv_nsec)
    }
}
