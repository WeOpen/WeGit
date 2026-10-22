import Foundation

public struct GitTag: Equatable, Identifiable, Sendable {
    public let reference: String
    public let objectID: String
    public let targetCommit: String?
    public let annotated: Bool
    public let symbolicTarget: String?
    public var name: String { String(reference.dropFirst("refs/tags/".count)) }
    public var id: String { Data(reference.utf8).base64EncodedString() }
}

public struct TagList: Sendable {
    public let entries: [GitTag]
    public let hasMore: Bool
}

public enum TagKind: String, CaseIterable, Identifiable, Sendable {
    case lightweight, annotated
    public var id: String { rawValue }
    public var title: String {
        self == .lightweight ? L10n.text("轻量标签") : L10n.text("附注标签")
    }
}

public struct TagCreationPlan: Sendable {
    public let name: String
    public let targetCommit: String
    public let kind: TagKind
    public let message: String
    public let signingRequired: Bool
    let head: String?
    let configuration: Data
    let location: RepositoryLocation
}

public struct TagPushPlan: Sendable {
    public let tag: GitTag
    public let remote: GitRemote
    public let pushURLIndex: Int
    public let expectedRemoteObject: String?
    let head: String?
    let location: RepositoryLocation
}

public enum TagPushResult: Sendable { case pushed, alreadyPresent }
public enum TagPushVerification: Sendable { case matches, absent, different }

public struct TagPushOutcomeUnknown: Error, LocalizedError, Sendable {
    public let plan: TagPushPlan
    public let details: String
    public var errorDescription: String? { L10n.text("标签推送结果尚未确认，请先核对远端，不要直接重复推送。") }
}
