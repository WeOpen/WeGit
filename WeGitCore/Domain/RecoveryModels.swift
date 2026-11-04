import Foundation

public enum ResetMode: String, CaseIterable, Sendable {
    case soft, mixed, hard
    public var title: String { rawValue.capitalized }
    public var impact: String {
        switch self {
        case .soft: L10n.text("移动 HEAD，保留暂存区和工作文件。")
        case .mixed: L10n.text("移动 HEAD 并重置暂存区，保留工作文件。")
        case .hard: L10n.text("移动 HEAD，重置暂存区并替换受影响的工作文件。")
        }
    }
}

public enum RecoveryLayer: String, CaseIterable, Sendable {
    case worktree, index, both
    public var title: String {
        switch self {
        case .worktree: L10n.text("工作文件")
        case .index: L10n.text("暂存区")
        case .both: L10n.text("工作文件与暂存区")
        }
    }
}

public struct ReflogEntry: Identifiable, Sendable {
    public let object: String
    public let selector: String
    public let message: String
    public let date: Date?
    public let objectExists: Bool
    public let position: Int
    public var id: String { selector + ":" + object + ":\(position)" }
}

public struct RecoveryFile: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case absent, file, symbolicLink }
    public let path: String
    public let kind: Kind
    public let mode: UInt16
    public let bytes: Int
    public let sha256: String?
    let storageName: String
    public var id: String { path }
}

public struct RecoveryRecord: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case prepared, succeeded, needsVerification, restored }
    public let format: Int
    public let id: UUID
    public let workspaceID: String
    public let createdAt: Date
    public let operation: String
    public let head: String?
    public let branch: String
    public let target: String?
    public let files: [RecoveryFile]
    public let indexSHA256: String?
    public let indexMode: UInt16
    public let indexBytes: Int
    public var state: State
    public var observedHead: String?
    public var details: String?
    public var totalBytes: Int { files.reduce(indexBytes) { $0 + $1.bytes } }
}

public struct ResetPlan: Sendable, Identifiable {
    public let id: UUID
    public let mode: ResetMode
    public let target: GitCommit
    public let head: String
    public let branch: String
    public let files: [String]
    public let publishedTrackingRefs: [String]
    public var backupBytes: Int { captures.reduce(index.bytes?.count ?? 0) { $0 + $1.file.bytes } }
    let location: RepositoryLocation
    let index: SelectedIndexSnapshot
    let captures: [RecoveryFileCapture]
    let statusFiles: [FileChange]
}

public struct RecoveryRestorePlan: Sendable, Identifiable {
    public let id: UUID
    public let record: RecoveryRecord
    public let layer: RecoveryLayer
    public let currentHead: String?
    public let currentBranch: String
    let location: RepositoryLocation
    let index: SelectedIndexSnapshot
    let currentFiles: [RecoveryFileCapture]
    let sourceFiles: [RecoveryFileCapture]
    let sourceIndex: Data?
}

public struct RecoveryOutcomeUnknown: Error, LocalizedError, Sendable {
    public let recordID: UUID
    public let details: String
    public var errorDescription: String? {
        L10n.text("操作结果需要核对。原始内容已备份；请在恢复记录中检查 HEAD、暂存区和文件，不会自动重试。")
    }
}

enum RecoveryBudget {
    static let bytes = 256 * 1024 * 1024
    static let retainedBytes = 1024 * 1024 * 1024
    static let files = 1000
    static let records = 20
    static let days: TimeInterval = 7 * 86400
    static var exceeded: ModelFailure {
        .unsupported(L10n.text("备份超过文件数或空间上限。请先导出或清理恢复记录；工作文件尚未修改。"))
    }
}
