import Foundation

public struct FileHistoryQuery: Equatable, Sendable {
    public var path: String
    public var followRenames: Bool
    public var author: String
    public var message: String
    public var since: Date?
    public var until: Date?
    public init(
        path: String, followRenames: Bool = true, author: String = "", message: String = "",
        since: Date? = nil, until: Date? = nil
    ) {
        self.path = path
        self.followRenames = followRenames
        self.author = author
        self.message = message
        self.since = since
        self.until = until
    }
}
public struct FileHistoryAnchor: Sendable {
    public let id: UUID
    public let tip: String?
    public let query: FileHistoryQuery
    let location: RepositoryLocation
    let records: [FileHistoryRecord]
}
public struct FileHistoryCursor: Equatable, Sendable {
    let anchorID: UUID
    let offset: Int
}
public struct FileHistoryEntry: Identifiable, Sendable {
    public let commit: GitCommit
    public let path: String
    public let oldPath: String?
    public let status: Character
    public var id: String { commit.id }
}
public struct FileHistoryPage: Sendable {
    public let entries: [FileHistoryEntry]
    public let next: FileHistoryCursor?
}
struct FileHistoryRecord: Sendable {
    let oid: String
    let path: String
    let oldPath: String?
    let status: Character
}
enum FileHistoryParser {
    static func parse(_ data: Data) throws -> [FileHistoryRecord] {
        guard data.isEmpty || data.last == 0 else { throw ModelFailure.changed }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0
        var values: [FileHistoryRecord] = []
        var seen: Set<String> = []
        func field() throws -> String {
            guard index < fields.count, let text = String(data: fields[index], encoding: .utf8) else {
                throw ModelFailure.changed
            }
            index += 1
            return text
        }
        while index < fields.count - 1 {
            guard try field().isEmpty else { throw ModelFailure.changed }
            let oid = try field()
            guard GitObjectID.valid(oid), try field().isEmpty else { throw ModelFailure.changed }
            let rawStatus = try field()
            // Only the record header owns a newline; filenames are never trimmed.
            guard rawStatus.hasPrefix("\n"), let status = rawStatus.dropFirst().first,
                "ACDMRT".contains(status)
            else { throw ModelFailure.changed }
            let code = String(rawStatus.dropFirst())
            let first = try field()
            guard !first.isEmpty else { throw ModelFailure.changed }
            let path: String
            let old: String?
            if status == "R" || status == "C" {
                guard let score = Int(code.dropFirst()), (0...100).contains(score) else {
                    throw ModelFailure.changed
                }
                old = first
                path = try field()
                guard !path.isEmpty else { throw ModelFailure.changed }
            } else {
                guard code.count == 1 else { throw ModelFailure.changed }
                old = nil
                path = first
            }
            guard index < fields.count, fields[index].isEmpty else {
                throw ModelFailure.unsupported(L10n.text("请输入单个文件的仓库相对路径。"))
            }
            guard seen.insert(oid).inserted else { throw ModelFailure.changed }
            values.append(FileHistoryRecord(oid: oid, path: path, oldPath: old, status: status))
        }
        return values
    }
}
