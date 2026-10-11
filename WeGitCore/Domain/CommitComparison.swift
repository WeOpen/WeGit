import Foundation

public struct CommitFileChange: Identifiable, Hashable, Sendable {
    public let path: String
    public let oldPath: String?
    public let status: Character
    public let additions: Int?
    public let deletions: Int?
    public let binary: Bool
    public var id: String { path }
}

public struct CommitComparison: Sendable {
    public let commit: GitCommit
    public let parent: String?
    public let files: [CommitFileChange]
    let location: RepositoryLocation
}

enum CommitFilesParser {
    static func parse(names: Data, statistics: Data) throws -> [CommitFileChange] {
        guard names.isEmpty || names.last == 0, statistics.isEmpty || statistics.last == 0 else {
            throw ModelFailure.invalidOutput("提交文件记录被截断")
        }
        func path(_ bytes: Data.SubSequence) throws -> String {
            guard !bytes.isEmpty, let text = String(data: bytes, encoding: .utf8) else {
                throw ModelFailure.invalidOutput("提交文件路径无法可靠表示")
            }
            return text
        }
        let records = names.split(separator: 0, omittingEmptySubsequences: true)
        var files: [(String, String?, Character)] = []
        var index = 0
        while index < records.count {
            let code = String(decoding: records[index], as: UTF8.self)
            guard let status = code.first, "ACDMRT".contains(status) else {
                throw ModelFailure.invalidOutput("提交文件状态无效")
            }
            index += 1
            guard index < records.count else { throw ModelFailure.invalidOutput("提交文件路径缺失") }
            let first = try path(records[index])
            index += 1
            if status == "R" || status == "C" {
                guard let score = Int(code.dropFirst()), (0...100).contains(score), index < records.count
                else {
                    throw ModelFailure.invalidOutput("重命名或复制记录不完整")
                }
                let second = try path(records[index])
                index += 1
                files.append((second, first, status))
            } else {
                guard code.count == 1 else { throw ModelFailure.invalidOutput("提交文件状态包含额外字符") }
                files.append((first, nil, status))
            }
        }
        let stats = statistics.split(separator: 0, omittingEmptySubsequences: false)
        var values: [String: (Int, Int, Bool)] = [:]
        index = 0
        while index < stats.count - 1 {
            let fields = stats[index].split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw ModelFailure.invalidOutput("提交增删统计缺失") }
            index += 1
            let name: String
            if fields[2].isEmpty {
                guard index + 1 < stats.count - 1 else { throw ModelFailure.invalidOutput("重命名增删统计被截断") }
                _ = try path(stats[index])
                name = try path(stats[index + 1])
                index += 2
            } else {
                name = try path(fields[2])
            }
            let binary = fields[0] == Data("-".utf8) && fields[1] == Data("-".utf8)
            let added = binary ? 0 : Int(String(decoding: fields[0], as: UTF8.self)) ?? -1
            let deleted = binary ? 0 : Int(String(decoding: fields[1], as: UTF8.self)) ?? -1
            let previous = values[name] ?? (0, 0, false)
            guard added >= 0, deleted >= 0, added <= Int.max - previous.0, deleted <= Int.max - previous.1
            else {
                throw ModelFailure.invalidOutput("提交增删统计无效")
            }
            values[name] = (previous.0 + added, previous.1 + deleted, previous.2 || binary)
        }
        guard Set(files.map(\.0)).count == files.count else { throw ModelFailure.invalidOutput("提交文件记录重复") }
        guard Set(values.keys) == Set(files.map(\.0)) else {
            throw ModelFailure.invalidOutput("提交文件列表与增删统计不一致")
        }
        return try files.map { file in
            guard let value = values[file.0] else { throw ModelFailure.invalidOutput("提交文件缺少增删统计") }
            return CommitFileChange(
                path: file.0, oldPath: file.1, status: file.2,
                additions: value.2 ? nil : value.0, deletions: value.2 ? nil : value.1, binary: value.2)
        }
    }
}
