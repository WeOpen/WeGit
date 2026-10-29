import Foundation

/// A preview fixes its repository, original diff, index and work-file bytes.
public struct SelectedLinesPlan: Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let layer: DiffLayer
    public let patch: Data
    public let selectedLineCount: Int
    public let beforeBlob: String?
    public let afterBlob: String?
    let location: RepositoryLocation
    let head: String?
    let branch: String
    let diff: FileDiff
    let index: SelectedIndexSnapshot
    let workFile: Data?
    let candidateIndex: Data
    let candidateBlob: Data
}

public struct SelectedLinesOutcomeUnknown: Error, LocalizedError, Sendable {
    public let path: String
    public var errorDescription: String? {
        L10n.text("暂存区可能已更新。请刷新并核对文件；不会自动重复操作。")
    }
}
