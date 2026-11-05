import Foundation

public enum IgnoreRuleKind: String, CaseIterable, Sendable {
    case file, directory, fileExtension
    public var title: String {
        switch self {
        case .file: L10n.text("此文件")
        case .directory: L10n.text("所在目录")
        case .fileExtension: L10n.text("同扩展名")
        }
    }
}

public enum IgnoreRuleScope: String, CaseIterable, Sendable {
    case repository, local
    public var title: String { self == .repository ? ".gitignore" : ".git/info/exclude" }
}

public struct IgnoreRulePlan: Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let pattern: String
    public let kind: IgnoreRuleKind
    public let scope: IgnoreRuleScope
    public let matchedPaths: [String]
    let location: RepositoryLocation
    let sources: IgnoreRuleSources
    let filePlan: FileModificationPlan?
    let before: Data?
    let after: Data
}

public struct IgnoreRuleOutcome: Sendable {
    public let plan: IgnoreRulePlan
    public let recovery: RecoveryRecord?
    let localAfter: CommonExcludesSnapshot?
}

struct IgnoreRuleSources: Sendable {
    let head: String?
    let index: SelectedIndexSnapshot
    let captures: [RecoveryFileCapture]
    let local: CommonExcludesSnapshot
    let global: IgnoreGlobalFile
    let ignoreCase: String?
}

struct IgnoreGlobalFile: Sendable, Equatable {
    let setting: String?
    let path: URL
    let resolved: URL
    let identity: RepositoryNodeIdentity?
    let stamp: SnapshotFileStamp?
    let bytes: Data?
}
