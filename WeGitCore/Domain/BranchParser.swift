import Foundation

public enum BranchParser {
    public static let format =
        [
            "%(refname)", "%(objectname)", "%(HEAD)", "%(upstream)",
            "%(upstream:short)", "%(upstream:track,nobracket)", "%(worktreepath)", "%(symref)",
        ].joined(separator: "%00") + "%00"

    public static func parse(_ data: Data) throws -> [GitBranch] {
        if data.isEmpty { return [] }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.last == Data([10]), (fields.count - 1).isMultiple(of: 8) else {
            throw ModelFailure.invalidOutput("分支记录被截断")
        }
        var branches: [GitBranch] = []
        for offset in stride(from: 0, to: fields.count - 1, by: 8) {
            var first = fields[offset]
            if offset > 0 {
                guard first.first == 10 else { throw ModelFailure.invalidOutput("分支记录缺少结束符") }
                first = first.dropFirst()
            }
            let bytes = [first] + Array(fields[(offset + 1)..<(offset + 8)])
            let values = try bytes.map { bytes -> String in
                guard let value = String(data: bytes, encoding: .utf8) else {
                    throw ModelFailure.invalidOutput("分支名称或路径编码不受支持")
                }
                return value
            }
            let ref = values[0]
            guard GitObjectID.valid(values[1]), ref.hasPrefix("refs/heads/") || ref.hasPrefix("refs/remotes/")
            else {
                throw ModelFailure.invalidOutput("分支引用无效")
            }
            let remote = ref.hasPrefix("refs/remotes/")
            if remote && !values[7].isEmpty { continue }
            var ahead: Int?
            var behind: Int?
            if !values[3].isEmpty && values[5] != "gone" {
                ahead = 0
                behind = 0
                if !values[5].isEmpty {
                    for field in values[5].split(separator: ",") {
                        let parts = field.trimmingCharacters(in: .whitespaces).split(separator: " ")
                        guard parts.count == 2, let count = Int(parts[1]), count >= 0 else {
                            throw ModelFailure.invalidOutput("分支领先/落后数据无效")
                        }
                        if parts[0] == "ahead" {
                            ahead = count
                        } else if parts[0] == "behind" {
                            behind = count
                        } else {
                            throw ModelFailure.invalidOutput("无法识别分支跟踪状态")
                        }
                    }
                }
            }
            branches.append(
                GitBranch(
                    id: ref,
                    name: String(ref.dropFirst(remote ? "refs/remotes/".count : "refs/heads/".count)),
                    oid: values[1],
                    current: values[2] == "*", upstream: values[4],
                    upstreamRef: values[3].isEmpty ? nil : values[3],
                    ahead: ahead, behind: behind, worktreePath: values[6].isEmpty ? nil : values[6],
                    symbolicTarget: values[7].isEmpty ? nil : values[7]))
        }
        guard Set(branches.map(\.id)).count == branches.count else {
            throw ModelFailure.invalidOutput("分支记录重复")
        }
        return branches
    }
}

public struct BranchDeletionPlan: Sendable, Identifiable {
    public var id: String { branch.id + "@" + branch.oid }
    public let branch: GitBranch
    public let head: String?
    public let mergeTarget: String
    public let mergeTargetOID: String?
    public let merged: Bool
    let location: RepositoryLocation
}
