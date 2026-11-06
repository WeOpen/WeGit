import Foundation

public enum SubmoduleChangeOperation: String, CaseIterable, Sendable {
    case add, remove, changeSource
    public var title: String {
        switch self {
        case .add: L10n.text("添加子模块")
        case .remove: L10n.text("移除子模块")
        case .changeSource: L10n.text("更改子模块来源")
        }
    }
}

public struct SubmoduleRetention: Sendable {
    public let files: URL
    public let gitData: URL?
    public let initialized: Bool
    public let dirty: Bool
    public let untracked: Bool
    public let ignored: Bool
    /// Bounded presence probe: 0 means none, 1 means at least one, nil means unknown.
    public let independentCommits: Int?
    public let nestedPaths: [String]
    public let locks: [String]
    public let invalid: Bool
}

public struct SubmoduleChangePlan: Identifiable, Sendable {
    public let id: UUID
    public let operation: SubmoduleChangeOperation
    public let path: String
    public let name: String
    public let previousSource: String?
    public let source: String?
    public let recordedOID: String?
    public let indexOID: String?
    public let targetOID: String?
    public let retention: SubmoduleRetention
    public let gitmodulesPreview: String
    public let downloadsRepository: Bool
    public let synchronizeChildRemote: Bool
    public let childRemoteSource: String?
    public var actualChildOID: String? { child.head }
    let location: RepositoryLocation
    let head: String?
    let branch: String
    let index: SelectedIndexSnapshot
    let sharedIndex: RecoverySharedIndexSnapshot?
    let gitmodules: RecoveryFileCapture
    let desiredGitmodules: RecoveryFileCapture
    let config: SelectedIndexSnapshot
    let configAfter: Data
    let effectiveConfig: Data
    let child: SubmoduleChildSnapshot
    let destinationParents: [ConflictEditorDirectoryIdentity]
    let candidateIndex: Data?
    let childRemote: SubmoduleChildRemoteSnapshot?
}

struct SubmoduleChildRemoteSnapshot: Sendable {
    let location: RepositoryLocation
    let config: SelectedIndexSnapshot
    let configIdentity: RepositoryNodeIdentity
    let effectiveConfig: Data
    let source: String
    let after: Data
}

struct SubmoduleChildSnapshot: Sendable {
    let location: RepositoryLocation?
    let directory: RepositoryNodeIdentity?
    let marker: RepositoryNodeIdentity?
    let head: String?
    let branch: String?
    let index: SelectedIndexSnapshot?
    let status: Data?
    let retention: SubmoduleRetention
}

public struct SubmoduleChangeReceipt: Codable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable { case prepared, started, completed, needsVerification }
    public let id: UUID
    public let format: Int
    public let recoveryID: UUID
    public let workspaceID: String
    public let operation: String
    public let path: String
    public let originalHead: String?
    public let originalChildHead: String?
    public let targetOID: String?
    public let retainedFiles: URL
    public var retainedGitData: URL?
    public var retainedDownload: URL?
    public let receiptFile: URL
    public let originalConfigurationSHA256: String
    public let childRemoteSyncRequested: Bool
    public let retainedChildConfiguration: URL?
    public let originalChildConfigurationSHA256: String?
    public var phase: Phase
    public var downloaded = false
    public var childInstalled = false
    public var gitmodulesWritten = false
    public var configurationWritten = false
    public var indexWritten = false
    public var childConfigurationWritten = false
    public var detail: String?
}

public struct SubmoduleChangeOutcomeUnknown: Error, LocalizedError, Sendable {
    public let receipt: SubmoduleChangeReceipt
    public var errorDescription: String? {
        L10n.text("子模块操作结果需要核对。已保留文件、Git 数据和回执；不会自动重试。")
    }
}

public enum LFSRuleAction: String, CaseIterable, Sendable {
    case track, untrack
    public var title: String { self == .track ? L10n.text("LFS 跟踪") : L10n.text("取消 LFS 跟踪") }
}

public struct LFSAttributeRule: Identifiable, Hashable, Sendable {
    public let source: String
    public let line: Int
    public let pattern: String
    public let attributes: String
    public var id: String { source + ":" + String(line) }
}

public struct LFSRuleMatch: Identifiable, Sendable {
    public let path: String
    public let filter: String
    public let diff: String
    public let merge: String
    public let text: String
    public let filterSource: String?
    public var id: String { path }
}

public struct LFSRulePlan: Identifiable, Sendable {
    public let id: UUID
    public let pattern: String
    public let action: LFSRuleAction
    public let installation: LFSInstallation
    public let before: String
    public let after: String
    public let rules: [LFSAttributeRule]
    public let matchedPaths: [LFSRuleMatch]
    let location: RepositoryLocation
    let modification: FileModificationPlan
    let captures: [RecoveryFileCapture]
    let global: IgnoreGlobalFile
    let info: LFSInfoAttributesSnapshot
    let ignoreCase: String?
    let knownPaths: [String]
    let originalAttributes: Data
    let resultAttributes: Data
}

struct LFSInfoAttributesSnapshot: Sendable, Equatable {
    let snapshot: SelectedIndexSnapshot
    let directory: RepositoryNodeIdentity?
    let file: RepositoryNodeIdentity?
    var bytes: Data? { snapshot.bytes }
}

public struct LFSRuleOutcome: Sendable {
    public let plan: LFSRulePlan
    public let recovery: RecoveryRecord
}
