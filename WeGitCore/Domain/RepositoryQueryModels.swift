import Foundation

public enum RepositoryQueryScope: String, CaseIterable, Sendable {
    case all, commits, trackedPaths, branches, tags, stashes, worktrees, commands
    public var title: String {
        switch self {
        case .all: L10n.text("全部")
        case .commits: L10n.text("提交")
        case .trackedPaths: L10n.text("已跟踪路径")
        case .branches: L10n.text("分支")
        case .tags: L10n.text("标签")
        case .stashes: L10n.text("储藏")
        case .worktrees: L10n.text("工作树")
        case .commands: L10n.text("命令")
        }
    }
    var categories: [Self] { self == .all ? Self.allCases.filter { $0 != .all } : [self] }
}

/// Command availability is a display snapshot. Execution must revalidate in the app.
public struct RepositoryQueryCommand: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let enabled: Bool
    public let reason: String
    public let shortcut: String
    public init(
        id: String, title: String, symbol: String, enabled: Bool = true, reason: String = "",
        shortcut: String = ""
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.enabled = enabled
        self.reason = reason
        self.shortcut = shortcut
    }
}

public enum RepositoryQueryResult: Identifiable, Sendable {
    case commit(GitCommit)
    case trackedPath(String)
    case branch(GitBranch)
    case tag(GitTag)
    case stash(GitStash)
    case worktree(GitWorktree)
    case command(RepositoryQueryCommand)
    public var id: String {
        switch self {
        case .commit(let value): "commit:" + value.id
        case .trackedPath(let value): "path:" + Data(value.utf8).base64EncodedString()
        case .branch(let value): "branch:" + value.id
        case .tag(let value): "tag:" + value.id
        case .stash(let value): "stash:" + value.id
        case .worktree(let value): "worktree:" + value.id
        case .command(let value): "command:" + value.id
        }
    }
    public var scope: RepositoryQueryScope {
        switch self {
        case .commit: .commits
        case .trackedPath: .trackedPaths
        case .branch: .branches
        case .tag: .tags
        case .stash: .stashes
        case .worktree: .worktrees
        case .command: .commands
        }
    }
    public var title: String {
        switch self {
        case .commit(let value): value.subject
        case .trackedPath(let value): value
        case .branch(let value): value.name
        case .tag(let value): value.name
        case .stash(let value): value.message
        case .worktree(let value): value.path
        case .command(let value): value.title
        }
    }
    public var detail: String {
        switch self {
        case .commit(let value): "\(value.id.prefix(12)) · \(value.author)"
        case .branch(let value): String(value.oid.prefix(12))
        case .tag(let value): String(value.objectID.prefix(12))
        case .stash(let value): value.selector
        case .worktree(let value): value.branchName ?? "HEAD"
        case .command(let value): value.enabled ? value.shortcut : value.reason
        case .trackedPath: ""
        }
    }
    public var enabled: Bool {
        if case .command(let value) = self { return value.enabled }
        return true
    }
}

/// Metadata is read once per query. Later pages reuse it and fixed commit tips.
public struct RepositoryQueryAnchor: Sendable {
    public let id: UUID
    public let location: RepositoryLocation
    public let scope: RepositoryQueryScope
    public let query: String
    public let commitField: HistorySearchField
    let metadata: [RepositoryQueryScope: [RepositoryQueryResult]]
    let history: HistoryAnchor?
}

public struct RepositoryQueryCursor: Sendable {
    let anchorID: UUID
    var offsets: [RepositoryQueryScope: Int] = [:]
    var historyCursor: HistoryCursor?
    var bufferedCommits: [GitCommit] = []
    var historyFinished = false
    var categoryIndex = 0
    var returnedCount = 0
}

public struct RepositoryQueryPage: Sendable {
    public let results: [RepositoryQueryResult]
    public let next: RepositoryQueryCursor?
}
