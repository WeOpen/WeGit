import Foundation

public struct TaskSwitchPlan: Sendable {
    public let target: GitBranch
    public let head: String
    public let branch: String
    public let message: String
    public let includeUntracked: Bool
    public let files: [FileChange]
    let location: RepositoryLocation
    let index: SelectedIndexSnapshot
    let sharedIndex: RecoverySharedIndexSnapshot?
    let metadata: [RecoveryFileMetadata]
    let captures: [RecoveryFileCapture]
}

public struct StashBranchPlan: Sendable {
    public let entry: GitStash
    public let name: String
    public let base: String
    public let head: String
    public let branch: String
    public let dropAfterApply: Bool
    public let files: [String]
    let list: StashList
    let location: RepositoryLocation
    let index: SelectedIndexSnapshot
    let sharedIndex: RecoverySharedIndexSnapshot?
    let metadata: [RecoveryFileMetadata]
    let captures: [RecoveryFileCapture]
}

public enum TaskSwitchOutcome: Sendable {
    case switched(GitStash)
    case savedNeedsReview(GitStash, String)
}

public enum StashBranchOutcome: Sendable {
    case restored(String, StashRestoreOutcome)
    case branchCreatedNeedsReview(String, String)
}
