import Foundation

public struct CommitQueueSelection: Sendable {
    public let target: String
    public let mainline: Int?
    public init(target: String, mainline: Int? = nil) {
        self.target = target
        self.mainline = mainline
    }
}

public struct CommitQueueItem: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case pending, committed, skipped }
    public let objectID: String
    public let subject: String
    public let mainline: Int?
    public var state: State
    public var result: String?
    public var id: String { objectID }
}

public enum CommitQueuePhase: String, Codable, Sendable {
    case ready, running, waiting, needsVerification, completed, aborted
    public var pending: Bool { self != .completed && self != .aborted }
}

public struct CommitQueueRecord: Codable, Equatable, Sendable, Identifiable {
    public let format: Int
    public let id: UUID
    public let workspaceID: String
    public let operation: SingleCommitOperation
    public let originalHead: String
    public let branch: String
    public let createdAt: Date
    public var items: [CommitQueueItem]
    public var next: Int
    public var currentHead: String
    public var phase: CommitQueuePhase
    public var expectedTree: String?
    public var expectedIndexSHA256: String?
    public var details: String?
    public var current: CommitQueueItem? { items.indices.contains(next) ? items[next] : nil }
}

public struct CommitQueuePlan: Sendable {
    public let operation: SingleCommitOperation
    public let items: [CommitQueueItem]
    public let first: SingleCommitPlan
    let location: RepositoryLocation
}

public struct CommitQueueOutcomeUnknown: Error, LocalizedError, Sendable {
    public let recordID: UUID
    public let details: String
    public var errorDescription: String? {
        L10n.text("提交队列结果需要核对。已完成的提交和剩余顺序已保留，不会自动重试。")
    }
}
