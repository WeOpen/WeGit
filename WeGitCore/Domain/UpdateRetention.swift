import Foundation

public enum UpdateRetentionState: String, Codable, Sendable {
    case preparing, prepared, awaitingLaunch, completed, rolledBack, blocked, unverified, busy
}

public struct UpdateRetentionEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let directory: URL
    public let created: Date?
    public let version: String?
    public let build: UInt64?
    public let state: UpdateRetentionState
    public let bytes: Int64?
    public let canClean: Bool
    /// Stable reason code. It never contains paths, process arguments or retained user data.
    public let detail: String?
}

public struct UpdateRetentionInventory: Sendable {
    public let entries: [UpdateRetentionEntry]
    public let totalBytes: Int64?
    public let capacityBlocked: Bool
}

public struct UpdateRetentionCleanupPlan: Sendable {
    public let entry: UpdateRetentionEntry
    public var bytes: Int64? { entry.bytes }
    let target: URL
    let scope: UpdateHandoffScope
    let parent: UpdateNodeIdentity
    let tree: UpdateRetentionTree
    let binding: String
}
