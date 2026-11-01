import Foundation

public enum SubmoduleState: String, Hashable, Sendable {
    case uninitialized, clean, dirty, stagedChange, childChanged, invalid
}

public struct SubmoduleStatus: Identifiable, Hashable, Sendable {
    public let path: String
    public let url: String?
    public let recordedOID: String?
    public let indexOID: String?
    public let actualOID: String?
    public let initialized: Bool
    public let dirty: Bool
    public let state: SubmoduleState
    public var id: String { path }

    public init(
        path: String, url: String?, recordedOID: String?, indexOID: String?, actualOID: String?,
        initialized: Bool, dirty: Bool, state: SubmoduleState
    ) {
        self.path = path
        self.url = url
        self.recordedOID = recordedOID
        self.indexOID = indexOID
        self.actualOID = actualOID
        self.initialized = initialized
        self.dirty = dirty
        self.state = state
    }
}

public struct LFSInstallation: Hashable, Sendable {
    public let available: Bool
    public let version: String?
    public let detail: String?

    public init(available: Bool, version: String?, detail: String?) {
        self.available = available
        self.version = version
        self.detail = detail
    }
}

public struct LFSObjectStatus: Identifiable, Hashable, Sendable {
    public let path: String
    public let oid: String?
    public let size: Int64?
    public let isPointer: Bool
    public let objectAvailable: Bool
    public let workingTreeHydrated: Bool?
    public let detail: String?
    public var id: String { path }

    public init(
        path: String, oid: String?, size: Int64?, isPointer: Bool, objectAvailable: Bool,
        workingTreeHydrated: Bool?, detail: String?
    ) {
        self.path = path
        self.oid = oid
        self.size = size
        self.isPointer = isPointer
        self.objectAvailable = objectAvailable
        self.workingTreeHydrated = workingTreeHydrated
        self.detail = detail
    }
}
