import Foundation

public struct GitStash: Equatable, Identifiable, Sendable {
    public let selector: String
    public let objectID: String
    public let createdAt: Date
    public let message: String
    public var id: String { selector + "|" + objectID }
    public var branch: String? {
        let prefix = message.hasPrefix("WIP on ") ? "WIP on " : message.hasPrefix("On ") ? "On " : nil
        guard let prefix, let end = message.dropFirst(prefix.count).firstIndex(of: ":") else { return nil }
        return String(message[message.index(message.startIndex, offsetBy: prefix.count)..<end])
    }
}

public struct StashList: Sendable {
    public let entries: [GitStash]
    public let hasMore: Bool
    let limit: Int
    let token: Data
    let location: RepositoryLocation
}

public struct StashContents: Sendable {
    public let working: GitCommit
    public let index: GitCommit
    public let base: String
    public let untracked: GitCommit?
}

public enum StashRestoreOutcome: Sendable {
    case applied
    case popped
    /// Working contents were applied. A concurrent list change or uncertain
    /// deletion must never cause the UI to retry the whole restoration.
    case appliedNeedsReview(String)
}

enum StashParser {
    static func parse(_ data: Data) throws -> [GitStash] {
        guard data.isEmpty || data.last == 0 else {
            throw ModelFailure.invalidOutput(L10n.text("储藏列表被截断"))
        }
        guard !data.isEmpty else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        fields.removeLast()
        guard fields.count.isMultiple(of: 4) else {
            throw ModelFailure.invalidOutput(L10n.text("储藏字段数量无效"))
        }
        return try stride(from: 0, to: fields.count, by: 4).map { offset in
            let selector = String(decoding: fields[offset], as: UTF8.self)
            let object = String(decoding: fields[offset + 1], as: UTF8.self)
            let time = String(decoding: fields[offset + 2], as: UTF8.self)
            guard selector.hasPrefix("stash@{"), selector.hasSuffix("}"),
                let index = Int(selector.dropFirst(7).dropLast()), index >= 0,
                selector == "stash@{\(index)}", GitObjectID.valid(object), let seconds = Int64(time),
                seconds >= 0, let message = String(data: Data(fields[offset + 3]), encoding: .utf8)
            else { throw ModelFailure.invalidOutput(L10n.text("储藏无法可靠解析")) }
            return GitStash(
                selector: selector, objectID: object, createdAt: Date(timeIntervalSince1970: Double(seconds)),
                message: message)
        }
    }
}
