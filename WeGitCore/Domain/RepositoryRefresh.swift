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
        let metadata = Set([location.gitDirectory.path, location.commonDirectory.path])
        for (path, flag) in zip(paths, flags) {
            if flag & unreliable != 0 { return .all }
            if path == location.root.path || metadata.contains(path) { return .all }
            if let base = metadata.first(where: { path.hasPrefix($0 + "/") }) {
                let relative = String(path.dropFirst(base.count + 1))
                if relative.hasPrefix("objects/") || relative.hasPrefix("logs/")
                    || relative.hasPrefix("refs/wegit/") || relative.hasSuffix(".lock")
                {
                    continue
                }
                if relative == "index" {
                    result.formUnion([.status, .diff])
                } else if relative == "HEAD" || relative == "packed-refs" || relative.hasPrefix("refs/")
                    || relative.hasPrefix("rebase-") || relative.hasSuffix("_HEAD") || relative == "sequencer"
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
