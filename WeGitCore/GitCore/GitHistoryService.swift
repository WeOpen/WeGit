import Foundation

extension RepositoryService {
    @concurrent public func readCommit(_ id: String) async throws -> GitCommit {
        try location.validateIdentity()
        guard GitObjectID.valid(id) else { throw ModelFailure.invalidPath }
        let data = try await engine.run(
            ["cat-file", "--batch"], in: location.root, input: Data((id + "\n").utf8)
        ).stdout
        guard let commit = try CommitParser.batch(data, expected: [id]).first else {
            throw ModelFailure.changed
        }
        return commit
    }

    public func history(limit: Int = 200, tips: [String]? = nil, query: String = "") async throws
        -> [GitCommit]
    {
        guard (1...10_000).contains(limit), tips?.allSatisfy(GitObjectID.valid) ?? true else {
            throw ModelFailure.unsupported("一次读取的历史范围无效；大型历史请使用分页接口。")
        }
        let base = try await historyAnchor(query: query)
        let anchor = HistoryAnchor(
            id: base.id, location: base.location, head: base.head, scope: base.scope, query: base.query,
            searchField: base.searchField, matchingOID: base.matchingOID,
            references: base.references, tips: tips ?? base.tips, isShallow: base.isShallow)
        var result: [GitCommit] = []
        var cursor: HistoryCursor?
        repeat {
            let page = try await historyPage(anchor, after: cursor, count: min(200, limit - result.count))
            result += page.commits
            cursor = page.next
        } while cursor != nil && result.count < limit
        return result
    }

    public func commitDiff(_ commit: GitCommit, parent: String? = nil) async throws -> String {
        try location.validateIdentity()
        guard GitObjectID.valid(commit.id), commit.parents.allSatisfy(GitObjectID.valid),
            parent == nil || commit.parents.contains(parent!)
        else { throw ModelFailure.invalidPath }
        let selected = parent ?? commit.parents.first
        let args =
            selected.map {
                ["diff", "--no-ext-diff", "--no-textconv", "--no-color", $0, commit.id, "--"]
            } ?? ["show", "--format=", "--no-ext-diff", "--no-textconv", "--no-color", commit.id, "--"]
        return try await engine.run(args, in: location.root).text
    }

}
