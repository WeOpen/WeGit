import Foundation

public struct PatchFileChange: Identifiable, Sendable {
    public let path: String
    public let oldPath: String?
    public let additions: Int?
    public let deletions: Int?
    public let binary: Bool
    public var id: String { path }
}

public struct PatchPlan: Identifiable, Sendable {
    public let id: UUID
    public let layer: RecoveryLayer
    public let files: [PatchFileChange]
    public let patchBytes: Int
    let location: RepositoryLocation
    let head: String?
    let branch: String
    let index: SelectedIndexSnapshot
    let sharedIndex: RecoverySharedIndexSnapshot?
    let originals: [RecoveryFileCapture]
    let desired: [RecoveryFileCapture]
    let auxiliary: [RecoveryFileCapture]
    let configuration: [String: String?]
    let globalAttributes: IgnoreGlobalFile
    let candidateIndex: Data?
    let objectPack: Data?
    let newObjects: [String]
}

enum PatchReadBudget {
    static let bytes = 32 * 1024 * 1024
    static let files = 1000
}
