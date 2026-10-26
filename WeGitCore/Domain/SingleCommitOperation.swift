import Foundation

public enum SingleCommitOperation: String, CaseIterable, Sendable {
    case cherryPick = "cherry-pick"
    case revert

    public var title: String { self == .cherryPick ? "Cherry-pick" : "Revert" }
    public var sequencer: Sequencer { self == .cherryPick ? .cherryPick : .revert }
    var marker: String { self == .cherryPick ? "CHERRY_PICK_HEAD" : "REVERT_HEAD" }
}

public struct SingleCommitFileChange: Identifiable, Hashable, Sendable {
    public let path: String
    public let status: Character
    public var id: String { path }
}

/// A preview is bound to a repository, branch, HEAD, index and actual merge result.
/// Temporary merge objects are released before returning; no user index is written.
public struct SingleCommitPlan: Sendable {
    public let operation: SingleCommitOperation
    public let target: GitCommit
    public let head: String
    public let branch: String
    public let files: [SingleCommitFileChange]
    public let conflictPaths: [String]
    public var hasChanges: Bool { !files.isEmpty || !conflictPaths.isEmpty }
    let location: RepositoryLocation
    let index: Data
    let resultTree: String
    let writePaths: Set<String>
}

/// Only a single Git operation is eligible. External multi-commit sequencers remain
/// in Terminal, so Continue cannot unexpectedly execute a queue of other commits.
public struct SingleCommitRecovery: Hashable, Sendable {
    public let operation: SingleCommitOperation
    public let target: String
    public let head: String
    public let branch: String
    let location: RepositoryLocation
    let markerIdentity: RepositoryNodeIdentity
}

public enum SingleCommitOutcome: Sendable {
    case committed(String)
    case conflicts(Int)
    case pending(String)
}

public struct SingleCommitOutcomeUnknown: Error, LocalizedError, Sendable {
    public let operation: SingleCommitOperation
    public let previousHead: String
    public let observedHead: String?
    public let details: String
    public var errorDescription: String? {
        L10n.text("操作结果需要核对。请检查 HEAD、暂存区和进行中的 Git 操作；不会自动重复执行。")
    }
}

enum SingleCommitBudget {
    static let metadataBytes = 32 * 1024 * 1024
    static let changedBlobBytes = 64 * 1024 * 1024
    static let entries = 100_000
    static let files = 2_000
    static var exceeded: ModelFailure {
        .unsupported(L10n.text("此操作超过合并预览的读取上限，请在 Terminal 中处理。"))
    }
}
