import Foundation

extension RepositoryService {
    @concurrent public func fileHistoryAnchor(_ query: FileHistoryQuery, tip: String? = nil) async throws
        -> FileHistoryAnchor
    {
        try location.validateIdentity()
        try validate(query.path)
        guard !query.path.isEmpty, query.author.utf8.count <= 1024, query.message.utf8.count <= 4096,
            !query.author.contains("\0"), !query.message.contains("\0"),
            query.since.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
            query.until.map({ $0.timeIntervalSince1970.isFinite }) ?? true
        else { throw ModelFailure.invalidPath }
        guard
            [query.since, query.until].compactMap({ $0 }).allSatisfy({
                (-62_135_596_800...253_402_300_799).contains($0.timeIntervalSince1970)
            })
        else { throw ModelFailure.invalidPath }
        if let since = query.since, let until = query.until, since > until {
            throw ModelFailure.unsupported(L10n.text("开始时间不能晚于结束时间。"))
        }
        let selected: String?
        if let tip {
            try await verifyCommit(tip)
            selected = tip
        } else {
            selected = try await head()
        }
        guard let selected else {
            return FileHistoryAnchor(id: UUID(), tip: nil, query: query, location: location, records: [])
        }
        // Git --follow changes its path while emitting diffs. --skip/--grep can
        // hide the rename that advances that path, silently losing older history.
        // Snapshot bounded path metadata first, then filter exact immutable OIDs.
        let args = [
            "log", "--root", "--no-use-mailmap", "--topo-order", "--full-history",
            "--diff-merges=first-parent", "--no-color",
            "--no-decorate", "--no-notes", "--no-show-signature", "--no-ext-diff", "--no-textconv",
            "--format=%x00%H%x00", "--name-status", "-z", "--find-renames=50%",
            query.followRenames ? "--follow" : "--no-follow", "--max-count=100001", selected, "--",
            query.path,
        ]
        let result = try await engine.run(args, in: location.root, timeout: 60, outputLimit: 8 * 1024 * 1024)
        var records = try FileHistoryParser.parse(result.stdout)
        guard records.count <= 100_000 else {
            throw ModelFailure.unsupported(L10n.text("文件历史超过读取上限，请从较近的提交开始查询。"))
        }
        for record in records {
            try validate(record.path)
            if let old = record.oldPath { try validate(old) }
        }
        if !records.isEmpty
            && (!query.author.isEmpty || !query.message.isEmpty || query.since != nil || query.until != nil)
        {
            var filters = [
                "log", "--no-use-mailmap", "--no-walk=unsorted", "--no-notes", "--no-show-signature",
                "--no-decorate",
                "--format=%H", "--fixed-strings", "--regexp-ignore-case",
            ]
            if !query.author.isEmpty { filters.append("--author=" + query.author) }
            if !query.message.isEmpty { filters.append("--grep=" + query.message) }
            if let since = query.since {
                filters.append("--since-as-filter=" + ISO8601DateFormatter().string(from: since))
            }
            if let until = query.until {
                filters.append("--until=" + ISO8601DateFormatter().string(from: until))
            }
            filters.append("--stdin")
            let ids = records.map(\.oid)
            let filtered = try await engine.run(
                filters, in: location.root, input: Data((ids.joined(separator: "\n") + "\n").utf8),
                timeout: 60, outputLimit: 8 * 1024 * 1024
            ).stdout
            guard filtered.isEmpty || filtered.last == 10, let text = String(data: filtered, encoding: .utf8)
            else { throw ModelFailure.changed }
            let matches = Set(text.split(separator: "\n").map(String.init))
            guard matches.isSubset(of: Set(ids)) else { throw ModelFailure.changed }
            records = records.filter { matches.contains($0.oid) }
        }
        try Task.checkCancellation()
        try location.validateIdentity()
        return FileHistoryAnchor(
            id: UUID(), tip: selected, query: query, location: location, records: records)
    }

    @concurrent public func fileHistoryPage(
        _ anchor: FileHistoryAnchor, after cursor: FileHistoryCursor? = nil, count: Int = 100
    ) async throws -> FileHistoryPage {
        try location.validateIdentity()
        let offset = cursor?.offset ?? 0
        guard anchor.location == location, (1...200).contains(count), offset >= 0,
            offset <= anchor.records.count, cursor == nil || cursor?.anchorID == anchor.id
        else { throw ModelFailure.changed }
        let selected = Array(anchor.records.dropFirst(offset).prefix(count))
        guard !selected.isEmpty else { return FileHistoryPage(entries: [], next: nil) }
        let ids = selected.map(\.oid)
        let objects = try await engine.run(
            ["cat-file", "--batch"], in: location.root,
            input: Data((ids.joined(separator: "\n") + "\n").utf8), outputLimit: 16 * 1024 * 1024)
        let commits = try CommitParser.batch(objects.stdout, expected: ids)
        try Task.checkCancellation()
        try location.validateIdentity()
        return FileHistoryPage(
            entries: zip(commits, selected).map {
                FileHistoryEntry(commit: $0.0, path: $0.1.path, oldPath: $0.1.oldPath, status: $0.1.status)
            },
            next: anchor.records.count > offset + count
                ? FileHistoryCursor(anchorID: anchor.id, offset: offset + count) : nil)
    }
}
