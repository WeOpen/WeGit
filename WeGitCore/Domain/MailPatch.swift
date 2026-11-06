import Foundation

public struct MailPatchSource: Sendable {
    public let name: String
    public let bytes: Data
    public init(name: String, bytes: Data) {
        self.name = name
        self.bytes = bytes
    }
}

public struct MailPatchEntry: Codable, Equatable, Sendable, Identifiable {
    public let number: Int
    public let subject: String
    public let author: String
    public let email: String
    public let body: String?
    public let authorDate: String?
    public let paths: [String]
    public let sha256: String
    public var id: Int { number }
}

public enum MailPatchPhase: String, Codable, Sendable {
    case running, waiting, needsVerification, completed, aborted, dismissed
    public var pending: Bool { self != .completed && self != .aborted && self != .dismissed }
}

struct MailPatchNativeState: Sendable {
    let next: Int
    let total: Int
    let token: String
    let originalHead: String?
    let mailHashes: [String]

    func belongs(to record: MailPatchRecord) -> Bool {
        originalHead == record.originalHead && total == record.entries.count
            && mailHashes == record.entries.map(\.sha256)
    }
}

public struct MailPatchRecord: Codable, Equatable, Sendable, Identifiable {
    public let format: Int
    public let id: UUID
    public let workspaceID: String
    public let originalHead: String?
    public let branch: String
    public let entries: [MailPatchEntry]
    public let recoveryID: UUID
    public var phase: MailPatchPhase
    public var next: Int
    public var skipped: [Int]?
    public var expectedIndexSHA256: String?
    public var expectedConfigurationSHA256: String?
    public var nativeToken: String?
    public var details: String?
}

public struct MailPatchPlan: Sendable {
    public let entries: [MailPatchEntry]
    public let branch: String
    public let head: String?
    public let paths: [String]
    let location: RepositoryLocation
    let index: SelectedIndexSnapshot
    let sharedIndex: RecoverySharedIndexSnapshot?
    let metadata: [RecoveryFileMetadata]
    let captures: [RecoveryFileCapture]
    let storage: SnapshotDirectory
    let mails: [URL]
    let configurationSHA256: String

    public func moving(from: Int, to: Int) throws -> MailPatchPlan {
        guard entries.indices.contains(from), entries.indices.contains(to) else {
            throw ModelFailure.invalidPath
        }
        var order = Array(entries.indices)
        let selected = order.remove(at: from)
        order.insert(selected, at: to)
        let reordered = order.enumerated().map { position, original in
            let entry = entries[original]
            return MailPatchEntry(
                number: position + 1, subject: entry.subject, author: entry.author, email: entry.email,
                body: entry.body, authorDate: entry.authorDate, paths: entry.paths, sha256: entry.sha256)
        }
        return MailPatchPlan(
            entries: reordered, branch: branch, head: head, paths: paths, location: location,
            index: index, sharedIndex: sharedIndex, metadata: metadata, captures: captures,
            storage: storage, mails: order.map { mails[$0] }, configurationSHA256: configurationSHA256)
    }
}
