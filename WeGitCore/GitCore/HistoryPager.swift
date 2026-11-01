import Foundation

extension RepositoryService {
    @concurrent
    public func historyAnchor(
        scope: HistoryScope = .all, query: String = "", searchField: HistorySearchField = .message
    ) async throws -> HistoryAnchor {
        try location.validateIdentity()
        guard query.utf8.count <= 4096, !query.contains("\0") else {
            throw ModelFailure.unsupported(L10n.text("历史搜索内容过长或包含无效字符。"))
        }
        let currentHead = try await head()
        let output = try await engine.run(
            ["show-ref", "--head", "--dereference"], in: location.root, accepted: [0, 1])
        guard output.stdout.isEmpty || output.stdout.last == 10,
            let text = String(data: output.stdout, encoding: .utf8)
        else { throw ModelFailure.invalidOutput(L10n.text("引用列表被截断或包含不支持的编码")) }
        var objects: [String: String] = [:]
        for row in text.split(separator: "\n") {
            let parts = row.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, GitObjectID.valid(String(parts[0])) else {
                throw ModelFailure.invalidOutput(L10n.text("引用记录无效"))
            }
            objects[String(parts[1])] = String(parts[0])
        }
        var references: [GitReference] = []
        for name in objects.keys.sorted() where !name.hasSuffix("^{}") {
            let kind: GitReference.Kind
            if name == "HEAD" {
                kind = .head
            } else if name.hasPrefix("refs/heads/") {
                kind = .localBranch
            } else if name.hasPrefix("refs/remotes/") && !name.hasSuffix("/HEAD") {
                kind = .remoteBranch
            } else if name.hasPrefix("refs/tags/") {
                kind = .tag
            } else {
                continue
            }
            references.append(
                GitReference(id: name, target: objects[name + "^{}"] ?? objects[name]!, kind: kind))
        }
        let candidates = Array(Set(references.map(\.target))).sorted()
        if !candidates.isEmpty {
            let checked = try await engine.run(
                ["cat-file", "--batch-check=%(objectname) %(objecttype)"], in: location.root,
                input: Data((candidates.joined(separator: "\n") + "\n").utf8))
            guard checked.stdout.last == 10, let text = String(data: checked.stdout, encoding: .utf8) else {
                throw ModelFailure.invalidOutput(L10n.text("引用对象类型记录被截断"))
            }
            let rows = text.split(separator: "\n")
            guard rows.count == candidates.count else {
                throw ModelFailure.invalidOutput(L10n.text("引用对象数量不匹配"))
            }
            var commits: Set<String> = []
            for (index, row) in rows.enumerated() {
                let fields = row.split(separator: " ")
                guard fields.count == 2, fields[0] == candidates[index], fields[1] != "missing" else {
                    throw ModelFailure.invalidOutput(L10n.text("引用指向缺失或无效对象"))
                }
                if fields[1] == "commit" { commits.insert(candidates[index]) }
            }
            references.removeAll { !commits.contains($0.target) }
        }
        let shallow = try await engine.run(["rev-parse", "--is-shallow-repository"], in: location.root).text
            .removingLastNewline
        guard shallow == "true" || shallow == "false", try await head() == currentHead else {
            throw ModelFailure.changed
        }
        let tips =
            scope == .currentBranch
            ? currentHead.map { [$0] } ?? [] : Array(Set(references.map(\.target))).sorted()
        let matchingOID = searchField == .sha && !query.isEmpty ? try await resolveSearchSHA(query) : nil
        return HistoryAnchor(
            id: UUID(), location: location, head: currentHead, scope: scope, query: query,
            searchField: searchField, matchingOID: matchingOID,
            references: references, tips: tips, isShallow: shallow == "true")
    }

    @concurrent
    public func historyPage(_ anchor: HistoryAnchor, after cursor: HistoryCursor? = nil, count: Int = 200)
        async throws -> HistoryPage
    {
        try location.validateIdentity()
        guard anchor.location == location, (1...200).contains(count),
            cursor == nil || cursor?.anchorID == anchor.id, (cursor?.offset ?? 0) >= 0,
            anchor.tips.allSatisfy(GitObjectID.valid)
        else { throw ModelFailure.changed }
        if anchor.tips.isEmpty { return HistoryPage(commits: [], next: nil) }
        if anchor.searchField == .sha && !anchor.query.isEmpty {
            guard cursor == nil else { throw ModelFailure.changed }
            guard let oid = anchor.matchingOID else { return HistoryPage(commits: [], next: nil) }
            let revisions = [oid] + anchor.tips.map { "^" + $0 }
            let outside = try await engine.run(
                ["rev-list", "--max-count=1", "--stdin"], in: location.root,
                input: Data((revisions.joined(separator: "\n") + "\n").utf8))
            guard outside.stdout.isEmpty else { return HistoryPage(commits: [], next: nil) }
            let lineage = try await engine.run(
                ["rev-list", "--parents", "--max-count=1", oid, "--"], in: location.root
            ).text
                .split(whereSeparator: \.isWhitespace)
            let shallow: Set<String> = anchor.isShallow && lineage.count == 1 ? [oid] : []
            let objects = try await engine.run(
                ["cat-file", "--batch"], in: location.root, input: Data((oid + "\n").utf8))
            return HistoryPage(
                commits: try CommitParser.batch(objects.stdout, expected: [oid], shallow: shallow), next: nil)
        }
        let offset = cursor?.offset ?? 0
        guard offset <= Int.max - count else { throw ModelFailure.invalidOutput(L10n.text("历史分页范围超出上限")) }
        var arguments = [
            "rev-list", "--topo-order", "--parents", "--max-count=\(count + 1)", "--skip=\(offset)",
        ]
        if !anchor.query.isEmpty {
            let option = anchor.searchField == .author ? "--author=" : "--grep="
            arguments += ["--fixed-strings", "--regexp-ignore-case", option + anchor.query]
        }
        arguments.append("--stdin")
        let result = try await engine.run(
            arguments, in: location.root,
            input: Data((anchor.tips.joined(separator: "\n") + "\n").utf8))
        guard result.stdout.isEmpty || result.stdout.last == 10,
            let text = String(data: result.stdout, encoding: .utf8)
        else {
            throw ModelFailure.invalidOutput(L10n.text("历史标识记录被截断"))
        }
        var ids: [String] = []
        var shallow: Set<String> = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            guard let id = fields.first, fields.allSatisfy(GitObjectID.valid), !ids.contains(id) else {
                throw ModelFailure.invalidOutput(L10n.text("历史标识或父提交记录无效"))
            }
            ids.append(id)
            if anchor.isShallow && fields.count == 1 { shallow.insert(id) }
        }
        guard ids.count <= count + 1 else { throw ModelFailure.invalidOutput(L10n.text("历史页超出请求范围")) }
        let hasMore = ids.count > count
        let selected = Array(ids.prefix(count))
        if selected.isEmpty { return HistoryPage(commits: [], next: nil) }
        let objects = try await engine.run(
            ["cat-file", "--batch"], in: location.root,
            input: Data((selected.joined(separator: "\n") + "\n").utf8))
        let commits = try CommitParser.batch(objects.stdout, expected: selected, shallow: shallow)
        try location.validateIdentity()
        return HistoryPage(
            commits: commits, next: hasMore ? HistoryCursor(anchorID: anchor.id, offset: offset + count) : nil
        )
    }

    private func resolveSearchSHA(_ query: String) async throws -> String? {
        let prefix = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (4...64).contains(prefix.utf8.count),
            prefix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else {
            throw ModelFailure.unsupported(L10n.text("请输入至少 4 位的十六进制提交 SHA。"))
        }
        let output = try await engine.run(
            ["rev-parse", "--disambiguate=" + prefix], in: location.root, outputLimit: 64 * 1024)
        let ids = output.text.split(separator: "\n").map(String.init)
        guard output.stdout.isEmpty || output.stdout.last == 10,
            ids.allSatisfy(GitObjectID.valid), ids.count <= 1024
        else {
            throw ModelFailure.unsupported(L10n.text("SHA 前缀匹配过多对象，请输入更多位数。"))
        }
        if ids.isEmpty { return nil }
        let checked = try await engine.run(
            ["cat-file", "--batch-check=%(objectname) %(objecttype)"], in: location.root,
            input: Data((ids.joined(separator: "\n") + "\n").utf8))
        let rows = checked.text.split(separator: "\n")
        guard rows.count == ids.count, checked.stdout.last == 10 else {
            throw ModelFailure.invalidOutput(L10n.text("SHA 查询结果被截断"))
        }
        var commits: [String] = []
        for (id, row) in zip(ids, rows) {
            let fields = row.split(separator: " ")
            guard fields.count == 2, fields[0] == id, fields[1] != "missing" else {
                throw ModelFailure.invalidOutput(L10n.text("SHA 查询对象无效"))
            }
            if fields[1] == "commit" { commits.append(id) }
        }
        guard commits.count <= 1 else { throw ModelFailure.unsupported(L10n.text("SHA 前缀匹配多个提交，请输入更多位数。")) }
        return commits.first
    }
}
