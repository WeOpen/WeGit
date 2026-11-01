import Foundation

public struct RemoteConfigValue: Equatable, Sendable {
    public let key: String
    public let scope: String
    public let origin: String
    public let value: String
    public var displayValue: String { Redaction.text(value) }
}

public struct ManagedRemote: Identifiable, Sendable {
    public let name: String
    public let values: [RemoteConfigValue]
    public let fetchURLs: [String]
    public let pushURLs: [String]
    public let upstreamBranches: [String]
    public let canEdit: Bool
    public let canDelete: Bool
    public var id: String { name }
    public var displayFetchURLs: [String] { fetchURLs.map(Redaction.text) }
    public var displayPushURLs: [String] { (pushURLs.isEmpty ? fetchURLs : pushURLs).map(Redaction.text) }
}

public struct RemoteManagementSnapshot: Sendable {
    public let remotes: [ManagedRemote]
    let records: [RemoteConfigValue]
    let token: Data
    let file: RemoteConfigFile
    let location: RepositoryLocation
}

public enum RemoteChange: Sendable {
    case add(name: String, fetchURL: String, pushURL: String?)
    case update(name: String, fetchURL: String, pushURL: String?)
    case remove(name: String)
}
