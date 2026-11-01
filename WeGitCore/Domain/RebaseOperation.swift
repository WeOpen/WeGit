import Foundation

public enum RebaseDisposition: String, Sendable {
    case upToDate, fastForward, replay
}

/// The selected target ref remains a snapshot; execution uses its full object ID.
public struct RebasePlan: Sendable {
    public let branch: String
    public let head: String
    public let target: GitBranch
    public let startingPoint: String?
    public let commits: [GitCommit]
    public let disposition: RebaseDisposition
    public let preserveMerges: Bool
    public let publishedCommits: Set<String>
    public let conflictPaths: [String]
    public var hasWork: Bool { disposition != .upToDate }
    let location: RepositoryLocation
    let index: Data
    let writePaths: Set<String>
    let resultTree: String?
}

public enum RebaseBackend: String, Sendable {
    case merge = "rebase-merge"
    case apply = "rebase-apply"
}

struct RebaseStateFile: Hashable, Sendable {
    let identity: RepositoryNodeIdentity
    let bytes: Data
}

/// A recovery action is tied to the actual Git sequence, not just `.rebase`.
public struct RebaseRecovery: Hashable, Sendable {
    public let backend: RebaseBackend
    public let originalHead: String
    public let branchRef: String
    public let onto: String
    public let stoppedCommit: String?
    public let rescheduledCommit: String?
    public let completedSteps: Int
    public let remainingSteps: Int
    public let head: String
    public let continuationRestriction: String?
    public let abortRestriction: String?
    public let interactiveSequence: Bool
    public let interactiveEditPause: Bool
    public let expectedCommitCount: Int?
    let interactiveSession: InteractiveRebaseSessionDescriptor?
    let interactiveMessageEditor: InteractiveRebaseEditorDescriptor?
    public var canContinue: Bool { continuationRestriction == nil }
    public var canAbort: Bool { abortRestriction == nil }
    public var branchName: String { String(branchRef.dropFirst("refs/heads/".count)) }
    public var originalReference: String {
        "refs/wegit/rebase/" + location.persistenceID + "/" + originalHead
    }
    let location: RepositoryLocation
    let directoryIdentity: RepositoryNodeIdentity
    let files: [String: RebaseStateFile]
    let markers: [String: RebaseStateFile]
    let rewritten: [String: String]
    let remaining: [RebaseStep]
    let originals: [String]
    let index: Data
}

enum RebaseStep: Hashable, Sendable {
    case pick(String)
    case reword(String)
    case edit(String)
    case squash(String)
    case fixup(String)
    case drop(String)
    case label(String)
    case reset(String)
    case merge(String, [String])
    case noop

    var object: String? {
        switch self {
        case .pick(let value), .reword(let value), .edit(let value), .squash(let value), .fixup(let value),
            .drop(let value), .merge(let value, _):
            value
        default: nil
        }
    }

    var createsCommit: Bool {
        switch self {
        case .pick, .reword, .edit, .merge: true
        default: false
        }
    }

    var interactiveCommand: String? {
        switch self {
        case .pick(let id): "pick \(id)"
        case .reword(let id): "reword \(id)"
        case .edit(let id): "edit \(id)"
        case .squash(let id): "squash \(id)"
        case .fixup(let id): "fixup \(id)"
        case .drop(let id): "drop \(id)"
        default: nil
        }
    }

    var isInteractiveTransform: Bool {
        switch self {
        case .reword, .edit, .squash, .fixup, .drop: true
        default: false
        }
    }
}

public enum RebaseRecoveryAction: Equatable, Sendable {
    case continueOperation, abort
}

/// Confirmation captures the index (including staged resolutions) and the exact
/// remaining sequence. Preparing this plan does not write to the user's objects.
public struct RebaseRecoveryPlan: Sendable {
    public let action: RebaseRecoveryAction
    public let recovery: RebaseRecovery
    let writePaths: Set<String>
    let files: [FileChange]
    let resultTree: String?
    let resetBeforeRetry: Bool
}

public enum RebaseOutcome: Sendable {
    case completed(String)
    case conflicts(RebaseRecovery, Int)
    case paused(RebaseRecovery, String)
    case unchanged
    case aborted(String)
}

public struct RebaseOutcomeUnknown: Error, LocalizedError, Sendable {
    public let previousHead: String
    public let observedHead: String?
    public let details: String
    public let originalReference: String?
    public var errorDescription: String? {
        L10n.text("变基结果需要核对。请检查原提交、HEAD、暂存区和进行中的操作；不会自动再次执行。")
    }
}

enum RebaseBudget {
    static let commits = 2_000
    static let steps = commits * 4 + 16
    static let metadataBytes = 32 * 1024 * 1024
    static let stateBytes = 8 * 1024 * 1024
    static let stateFileBytes = 4 * 1024 * 1024
    static let entries = 100_000
    static let stateFiles = 128
    static let previewBytes = 64 * 1024 * 1024
    static var exceeded: ModelFailure {
        .unsupported(L10n.text("变基记录超过安全读取上限，请缩小范围或在 Terminal 中处理。"))
    }
}
