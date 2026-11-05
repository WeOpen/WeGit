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

public struct ReflogVersion: Equatable, Sendable {
    let workspaceID: String
    let ref: String
    let fingerprint: String?
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

public struct RecoverySharedIndex: Codable, Equatable, Sendable {
    let name: String
    let mode: UInt16
    let bytes: Int
    let sha256: String
}

struct RecoverySharedIndexSnapshot: Sendable, Equatable {
    let file: RecoverySharedIndex
    let data: Data
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
    public let sharedIndex: RecoverySharedIndex?
    public var indexTree: String?
    public var pendingIndexTree: String? = nil
    public var pendingObjectBytes: Int? = nil
    public var state: State
    public var observedHead: String?
    public var details: String?
    public var title: String {
        switch operation {
        case "reset-soft": "Soft Reset"
        case "reset-mixed": "Mixed Reset"
        case "reset-hard": "Hard Reset"
        case "restore-backup": L10n.text("恢复前备份")
        case "discard-lines": L10n.text("丢弃所选行")
        case "file-restore": L10n.text("恢复历史文件")
        case "ignore-rule": L10n.text("忽略规则")
        case "apply-patch": L10n.text("应用补丁")
        default: L10n.text("内容备份")
        }
    }
    public var totalBytes: Int {
        files.reduce(indexBytes + (sharedIndex?.bytes ?? 0) + (pendingObjectBytes ?? 0)) { $0 + $1.bytes }
    }
}

public struct ResetPlan: Sendable, Identifiable {
    public let id: UUID
    public let mode: ResetMode
    public let target: GitCommit
    public let head: String
    public let branch: String
    public let files: [String]
    public let publishedTrackingRefs: [String]
    public var backupBytes: Int {
        captures.reduce((index.bytes?.count ?? 0) + (sharedIndex?.data.count ?? 0)) { $0 + $1.file.bytes }
    }
    let location: RepositoryLocation
    let index: SelectedIndexSnapshot
    let captures: [RecoveryFileCapture]
    let indexedFiles: [RecoveryFileMetadata]
    let sharedIndex: RecoverySharedIndexSnapshot?
    let sourceRef: String?
    let trackedPaths: Set<String>
    let submoduleDirectories: Set<String>
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
    let sourceSharedIndex: RecoverySharedIndexSnapshot?
    let currentSharedIndex: RecoverySharedIndexSnapshot?
}

public struct FileModificationPlan: Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let sourceRevision: String?
    public let layer: RecoveryLayer
    public let selectedLineCount: Int?
    public let originalBytes: Int
    public let resultBytes: Int
    public let deletesFile: Bool
    public let resultPreview: String?
    let operation: String
    let location: RepositoryLocation
    let head: String?
    let branch: String
    let index: SelectedIndexSnapshot
    let sharedIndex: RecoverySharedIndexSnapshot?
    let current: RecoveryFileCapture
    let desired: RecoveryFileCapture
    let candidateIndex: Data?
    let filterPath: String?
    let sourceObject: String?
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
    static let metadataFiles = 100000
    static let records = 20
    static let days: TimeInterval = 7 * 86400
    static var exceeded: ModelFailure {
        .unsupported(L10n.text("备份超过文件数或空间上限。请先导出或清理恢复记录；工作文件尚未修改。"))
    }
}
