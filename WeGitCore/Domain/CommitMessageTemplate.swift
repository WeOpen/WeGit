import Foundation

public struct CommitMessageTemplate: Sendable {
    public let source: GitSettingRecord
    public let url: URL
    public let bytes: Data
    public let sha256: String
    /// A failed decode remains available as original bytes, never replacement text.
    public let text: String?
}
