import Foundation

public enum ModelFailure: Error, LocalizedError, Sendable {
    case invalidOutput(String)
    case unsupported(String)
    case changed, invalidPath, repositoryReplaced
    public var errorDescription: String? {
        switch self {
        case .invalidOutput(let value): L10n.text("Git 输出无法可靠解析：\(value)")
        case .unsupported(let value): value
        case .changed: L10n.text("仓库或文件已变化，请刷新后重新确认。")
        case .invalidPath: L10n.text("文件路径不属于当前仓库或无法安全表示。")
        case .repositoryReplaced: L10n.text("仓库目录已移动、被替换或 Git 目录指向已变化，请重新打开仓库。")
        }
    }
}

public struct CommitOutcomeUnknown: Error, LocalizedError, Sendable {
    public let previousHead: String?
    public let observedHead: String
    public let details: String
    public var errorDescription: String? {
        L10n.text("操作未返回完整结果，但 HEAD 已变为 \(observedHead.prefix(12))。请先核对该提交；不会自动重新提交或推送。")
    }
}

public struct RepositoryLocation: Hashable, Sendable, Identifiable {
    public let root: URL
    public let gitDirectory: URL
    public let commonDirectory: URL
    let rootIdentity: RepositoryNodeIdentity
    let gitIdentity: RepositoryNodeIdentity
    let markerIdentity: RepositoryNodeIdentity
    let commonIdentity: RepositoryNodeIdentity
    let commonMarkerIdentity: RepositoryNodeIdentity?
    let worktreeLinkIdentity: RepositoryNodeIdentity?
    public var isLinkedWorktree: Bool { gitDirectory != commonDirectory }
    public var id: String { root.path }
    public var name: String { root.lastPathComponent }
}

public struct FileChange: Hashable, Sendable, Identifiable {
    public let path: String
    public let oldPath: String?
    public let index: Character
    public let worktree: Character
    public let conflict: Bool
    public let untracked: Bool
    public var id: String { path }
    public var staged: Bool { !conflict && !untracked && index != "." }
    public var unstaged: Bool { !conflict && !untracked && worktree != "." }
    public var layers: [DiffLayer] {
        if conflict { return [.conflict] }
        if untracked { return [.untracked] }
        return (staged ? [.staged] : []) + (unstaged ? [.unstaged] : [])
    }
    public var filename: String { (path as NSString).lastPathComponent }
    public func symbol(for layer: DiffLayer) -> String {
        if conflict { return "U" }
        if untracked { return "?" }
        return String(layer == .staged ? index : worktree)
    }
}

public enum Sequencer: String, Sendable {
    case none, merge, rebase, cherryPick, revert, unknown
    public var title: String {
        switch self {
        case .none: L10n.text("无进行中操作")
        case .merge: L10n.text("合并")
        case .rebase: L10n.text("变基")
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        case .unknown: L10n.text("未支持的 Git 序列操作")
        }
    }
}
public enum DiffLayer: String, CaseIterable, Sendable { case unstaged, staged, untracked, conflict, commit }

public struct RepositoryStatus: Sendable {
    public var branch = ""
    public var head: String?
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?
    public var files: [FileChange] = []
    public var sequencer: Sequencer = .none
    public var singleCommitRecovery: SingleCommitRecovery?
    public var conflicts: [FileChange] { files.filter(\.conflict) }
    public var isDetached: Bool { branch == "(detached)" }
    public var displayBranch: String { isDetached ? "Detached · \(head?.prefix(7) ?? "")" : branch }
    public init() {}
}

public enum StatusParser {
    public static func parse(_ data: Data) throws -> RepositoryStatus {
        guard data.isEmpty || data.last == 0 else { throw ModelFailure.invalidOutput(L10n.text("状态记录被截断")) }
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var result = RepositoryStatus()
        var i = 0
        while i < records.count {
            guard let record = String(data: Data(records[i]), encoding: .utf8) else {
                throw ModelFailure.invalidOutput(L10n.text("文件名编码不受支持，已停止读取，避免错误操作。"))
            }
            i += 1
            if record.hasPrefix("# branch.head ") {
                result.branch = String(record.dropFirst(14))
                continue
            }
            if record.hasPrefix("# branch.oid ") {
                let oid = String(record.dropFirst(13))
                result.head = oid == "(initial)" ? nil : oid
                continue
            }
            if record.hasPrefix("# branch.upstream ") {
                result.upstream = String(record.dropFirst(18))
                continue
            }
            if record.hasPrefix("# branch.ab ") {
                let fields = record.split(separator: " ")
                guard fields.count == 4 else { throw ModelFailure.invalidOutput("branch.ab") }
                result.ahead = Int(fields[2].dropFirst())
                result.behind = Int(fields[3].dropFirst())
                continue
            }
            if record.hasPrefix("#") || record.hasPrefix("!") { continue }
            if record.hasPrefix("? ") {
                result.files.append(
                    FileChange(
                        path: String(record.dropFirst(2)), oldPath: nil, index: ".", worktree: "?",
                        conflict: false, untracked: true))
                continue
            }
            let type = record.first
            let count = type == "1" ? 8 : type == "2" ? 9 : type == "u" ? 10 : 0
            guard count > 0 else { throw ModelFailure.invalidOutput(L10n.text("未知状态记录")) }
            let fields = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
            guard fields.count == count + 1, fields[1].count == 2 else {
                throw ModelFailure.invalidOutput(L10n.text("不完整的状态记录"))
            }
            var oldPath: String?
            if type == "2" {
                guard i < records.count, let old = String(data: Data(records[i]), encoding: .utf8) else {
                    throw ModelFailure.invalidOutput(L10n.text("重命名路径缺失"))
                }
                oldPath = old
                i += 1
            }
            let xy = Array(fields[1])
            result.files.append(
                FileChange(
                    path: String(fields[count]), oldPath: oldPath, index: xy[0], worktree: xy[1],
                    conflict: type == "u", untracked: false))
        }
        return result
    }
}

public struct DiffLine: Identifiable, Hashable, Sendable {
    public let id: Int
    public let kind: Character
    public let content: String
    public let oldLine: Int?
    public let newLine: Int?
    public let truncated: Bool
    public let hasNewline: Bool

    public init(
        id: Int, kind: Character, content: String, oldLine: Int?, newLine: Int?, truncated: Bool = false,
        hasNewline: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.oldLine = oldLine
        self.newLine = newLine
        self.truncated = truncated
        self.hasNewline = hasNewline
    }
}

public struct DiffHunk: Identifiable, Hashable, Sendable {
    public let id: Int
    public let header: String
    public let lines: [DiffLine]
    public let raw: String
}

public struct DiffReadOptions: Hashable, Sendable {
    public var contextLines: Int
    public var ignoreWhitespace: Bool
    public init(contextLines: Int = 3, ignoreWhitespace: Bool = false) {
        self.contextLines = contextLines
        self.ignoreWhitespace = ignoreWhitespace
    }
}

public struct FileDiff: Sendable {
    public var options = DiffReadOptions()
    public let path: String
    public let layer: DiffLayer
    public let raw: Data
    public let header: String
    public let hunks: [DiffHunk]
    public let binary: Bool
    public let preview: String?
    public let head: String?
    public let indexTree: String?
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == "+" }) } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count(where: { $0.kind == "-" }) } }
    public var canApplyHunk: Bool {
        !options.ignoreWhitespace && options.contextLines > 0 && !binary && preview == nil && !hunks.isEmpty
            && (layer == .unstaged || layer == .staged)
            && !header.contains("new file mode") && !header.contains("deleted file mode")
            && !header.contains("rename from") && !header.contains("old mode")
    }
}

public struct GitCommit: Sendable, Identifiable, Hashable {
    public let id: String
    public let parents: [String]
    public let author: String
    public let date: Date
    public let message: String
    public let authorEmail: String
    public let committer: String
    public let committerEmail: String
    public let committedAt: Date
    public let shallowBoundary: Bool

    public init(
        id: String, parents: [String], author: String, date: Date, message: String,
        authorEmail: String = "", committer: String? = nil, committerEmail: String = "",
        committedAt: Date? = nil, shallowBoundary: Bool = false
    ) {
        self.id = id
        self.parents = parents
        self.author = author
        self.date = date
        self.message = message
        self.authorEmail = authorEmail
        self.committer = committer ?? author
        self.committerEmail = committerEmail
        self.committedAt = committedAt ?? date
        self.shallowBoundary = shallowBoundary
    }
    public var subject: String { String(message.split(separator: "\n", maxSplits: 1).first ?? "") }
}

public struct GitBranch: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let oid: String
    public let current: Bool
    public let upstream: String
    public let upstreamRef: String?
    public let ahead: Int?
    public let behind: Int?
    public let worktreePath: String?
    public let symbolicTarget: String?
    public var remote: Bool { id.hasPrefix("refs/remotes/") }

    public init(
        id: String, name: String, oid: String, current: Bool, upstream: String,
        upstreamRef: String? = nil, ahead: Int? = nil, behind: Int? = nil,
        worktreePath: String? = nil, symbolicTarget: String? = nil
    ) {
        self.id = id
        self.name = name
        self.oid = oid
        self.current = current
        self.upstream = upstream
        self.upstreamRef = upstreamRef
        self.ahead = ahead
        self.behind = behind
        self.worktreePath = worktreePath
        self.symbolicTarget = symbolicTarget
    }
}

public struct GraphRow: Sendable {
    public let column: Int
    public let connections: [(Int, Int)]
    public let width: Int
    public let incomingColumns: [Int]
    public init(column: Int, connections: [(Int, Int)], width: Int, incomingColumns: [Int] = []) {
        self.column = column
        self.connections = connections
        self.width = width
        self.incomingColumns = incomingColumns
    }
}

public enum GraphLayout {
    public static func rows(_ commits: [GitCommit]) -> [GraphRow] {
        var layout = CommitGraphLayoutEngine()
        return layout.append(commits)
    }
}
