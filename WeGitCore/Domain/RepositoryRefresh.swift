import CoreServices
import Foundation

public struct RepositoryRefreshScope: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let status = Self(rawValue: 1 << 0)
    public static let references = Self(rawValue: 1 << 1)
    public static let history = Self(rawValue: 1 << 2)
    public static let diff = Self(rawValue: 1 << 3)
    public static let configuration = Self(rawValue: 1 << 4)
    public static let all: Self = [.status, .references, .history, .diff, .configuration]

    public static func events(paths: [String], flags: [FSEventStreamEventFlags], location: RepositoryLocation)
        -> Self
    {
        guard paths.count == flags.count else { return .all }
        let unreliable = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount)
        var result: Self = []
        // A linked git directory is nested under common/worktrees. Match the most
        // specific path first, never a Set's arbitrary prefix iteration order.
        let metadata = Array(Set([location.gitDirectory.path, location.commonDirectory.path]))
            .sorted { $0.count > $1.count }
        for (path, flag) in zip(paths, flags) {
            if flag & unreliable != 0 { return .all }
            if path == location.root.path || metadata.contains(path) { return .all }
            if let base = metadata.first(where: { path.hasPrefix($0 + "/") }) {
                let relative = String(path.dropFirst(base.count + 1))
                if base == location.commonDirectory.path {
                    if relative.hasPrefix("worktrees/") {
                        let components = relative.split(separator: "/", maxSplits: 2)
                        // Other worktrees' HEAD/registration changes affect branch
                        // occupancy, but their indexes and sequencers are private.
                        if components.count < 3
                            || ["HEAD", "gitdir", "commondir", "locked"].contains(String(components[2]))
                        {
                            result.formUnion(.references)
                        }
                        continue
                    }
                    if relative == "worktrees" {
                        result.formUnion(.references)
                        continue
                    }
                    if location.isLinkedWorktree {
                        if relative == "HEAD" {
                            result.formUnion(.references)
                            continue
                        }
                        if relative == "index" || relative == "config.worktree"
                            || relative.hasPrefix("rebase-") || relative == "sequencer"
                            || relative.hasPrefix("sequencer/") || relative.hasSuffix("_HEAD")
                            || relative == "AUTO_MERGE" || relative == "COMMIT_EDITMSG"
                            || relative.hasPrefix("refs/bisect/") || relative.hasPrefix("refs/worktree/")
                            || relative.hasPrefix("refs/rewritten/")
                        {
                            continue
                        }
                    }
                }
                // Removing a non-top stash may change only the reflog, leaving
                // refs/stash at the same object. The Stash browser reloads with status.
                if relative == "logs/refs/stash" {
                    result.formUnion(.status)
                    continue
                }
                if relative.hasPrefix("objects/") || relative.hasPrefix("logs/")
                    || relative.hasPrefix("refs/wegit/") || relative.hasSuffix(".lock")
                {
                    continue
                }
                if relative == "index" {
                    result.formUnion([.status, .diff])
                } else if relative == "HEAD" || relative == "packed-refs" || relative.hasPrefix("refs/")
                    || relative.hasPrefix("rebase-") || relative.hasSuffix("_HEAD") || relative == "sequencer"
                    || relative.hasPrefix("sequencer/")
                {
                    result.formUnion([.status, .references, .history, .diff])
                } else {
                    result.formUnion(.all)
                }
            } else if path.hasPrefix(location.root.path + "/") {
                result.formUnion([.status, .diff])
            } else {
                result.formUnion(.all)
            }
        }
        return result
    }
}

public struct RepositoryReadSnapshot: Sendable {
    public let status: RepositoryStatus
    public let branches: [GitBranch]?
    public let remotes: [String]?
    public let scope: RepositoryRefreshScope
    public let readAt: Date
}
