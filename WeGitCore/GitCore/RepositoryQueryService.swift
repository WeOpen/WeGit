import Foundation

extension RepositoryService {
    @concurrent public func repositoryQueryAnchor(
        scope: RepositoryQueryScope = .all, query: String = "",
        commitField: HistorySearchField = .message, commands: [RepositoryQueryCommand] = []
    ) async throws -> RepositoryQueryAnchor {
        try Task.checkCancellation()
        try location.validateIdentity()
        guard query.utf8.count <= 1024, !query.contains("\0"), commands.count <= 256,
            Set(commands.map(\.id)).count == commands.count,
            commands.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && $0.title.utf8.count <= 4096 })
        else { throw ModelFailure.unsupported(L10n.text("搜索内容或命令列表超过读取上限。")) }
        let categories = scope.categories
        if categories.contains(.commits) {
            try await checkQueryReferenceLimit()
        }
        var metadata: [RepositoryQueryScope: [RepositoryQueryResult]] = [:]
        var history: HistoryAnchor?
        try await withThrowingTaskGroup(of: QueryRead.self) { group in
            if categories.contains(.commits) {
                group.addTask {
                    let value = try await self.historyAnchor(query: query, searchField: commitField)
                    guard value.references.count <= 10_001 else {
                        throw ModelFailure.unsupported(L10n.text("引用数量超过搜索上限。"))
                    }
                    return .history(value)
                }
            }
            if categories.contains(.trackedPaths) {
                group.addTask { .metadata(.trackedPaths, try await self.queryTrackedPaths(query)) }
            }
            if categories.contains(.branches) || categories.contains(.tags) {
                group.addTask { .references(try await self.queryReferences(query, categories: categories)) }
            }
            if categories.contains(.stashes) {
                group.addTask {
                    let list = try await self.stashes(limit: 10_000)
                    guard !list.hasMore else {
                        throw ModelFailure.unsupported(L10n.text("储藏数量超过搜索上限。"))
                    }
                    return .metadata(
                        .stashes,
                        list.entries.filter {
                            Self.queryMatches(query, [$0.message, $0.selector, $0.objectID])
                        }.map(RepositoryQueryResult.stash))
                }
            }
            if categories.contains(.worktrees) {
                group.addTask {
                    .metadata(
                        .worktrees,
                        try await self.worktrees().filter {
                            Self.queryMatches(query, [$0.path, $0.branchName ?? "", $0.head ?? ""])
                        }.map(RepositoryQueryResult.worktree))
                }
            }
            for try await value in group {
                switch value {
                case .history(let anchor): history = anchor
                case .metadata(let scope, let values): metadata[scope] = values
                case .references(let values): metadata.merge(values) { _, new in new }
                }
            }
        }
        if categories.contains(.commands) {
            metadata[.commands] = commands.filter { Self.queryMatches(query, [$0.title, $0.id]) }
                .map(RepositoryQueryResult.command)
        }
        try Task.checkCancellation()
        try location.validateIdentity()
        return RepositoryQueryAnchor(
            id: UUID(), location: location, scope: scope, query: query, commitField: commitField,
            metadata: metadata, history: history)
    }

    @concurrent public func repositoryQueryPage(
        _ anchor: RepositoryQueryAnchor, after cursor: RepositoryQueryCursor? = nil, count: Int = 100
    ) async throws -> RepositoryQueryPage {
        try Task.checkCancellation()
        try location.validateIdentity()
        guard anchor.location == location, (1...100).contains(count),
            cursor == nil || cursor?.anchorID == anchor.id
        else { throw ModelFailure.changed }
        var next = cursor ?? RepositoryQueryCursor(anchorID: anchor.id)
        let categories = anchor.scope.categories
        var results: [RepositoryQueryResult] = []
        var emptyCategories = 0
        // Both commit traversals and displayed metadata have explicit global bounds.
        while results.count < count && emptyCategories < categories.count {
            try Task.checkCancellation()
            let scope = categories[next.categoryIndex % categories.count]
            next.categoryIndex = (next.categoryIndex + 1) % categories.count
            let result: RepositoryQueryResult?
            if scope == .commits {
                if next.bufferedCommits.isEmpty && !next.historyFinished, let history = anchor.history {
                    let remaining = 100_000 - next.offsets[.commits, default: 0]
                    if remaining > 0 {
                        let page = try await historyPage(
                            history, after: next.historyCursor, count: min(100, remaining))
                        next.bufferedCommits = page.commits
                        next.historyCursor = page.next
                        next.historyFinished = page.next == nil || remaining <= page.commits.count
                    } else {
                        next.historyFinished = true
                    }
                }
                if !next.bufferedCommits.isEmpty {
                    result = .commit(next.bufferedCommits.removeFirst())
                    next.offsets[.commits, default: 0] += 1
                } else {
                    result = nil
                }
            } else {
                let offset = next.offsets[scope, default: 0]
                let values = anchor.metadata[scope] ?? []
                result = offset < values.count ? values[offset] : nil
                if result != nil { next.offsets[scope] = offset + 1 }
            }
            if let result {
                results.append(result)
                next.returnedCount += 1
                emptyCategories = 0
            } else {
                emptyCategories += 1
            }
        }
        let metadataMore = anchor.metadata.contains { scope, values in
            next.offsets[scope, default: 0] < values.count
        }
        let commitsMore = !next.bufferedCommits.isEmpty || anchor.history != nil && !next.historyFinished
        try Task.checkCancellation()
        try location.validateIdentity()
        return RepositoryQueryPage(
            results: results, next: metadataMore || commitsMore ? next : nil)
    }

    private enum QueryRead: Sendable {
        case history(HistoryAnchor)
        case metadata(RepositoryQueryScope, [RepositoryQueryResult])
        case references([RepositoryQueryScope: [RepositoryQueryResult]])
    }

    private static func queryMatches(_ query: String, _ values: [String]) -> Bool {
        query.isEmpty || values.contains { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    private func checkQueryReferenceLimit() async throws {
        let bytes = try await engine.run(
            [
                "for-each-ref", "--count=10001", "--format=%(refname)", "refs/heads", "refs/remotes",
                "refs/tags",
            ],
            in: location.root, outputLimit: 4 * 1024 * 1024
        ).stdout
        guard bytes.isEmpty || bytes.last == 10, bytes.split(separator: 10).count <= 10_000 else {
            throw ModelFailure.unsupported(L10n.text("引用数量超过搜索上限。"))
        }
    }

    private func queryTrackedPaths(_ query: String) async throws -> [RepositoryQueryResult] {
        let bytes = try await engine.run(
            ["ls-files", "--cached", "--deduplicate", "-z"], in: location.root,
            outputLimit: 32 * 1024 * 1024
        ).stdout
        guard bytes.isEmpty || bytes.last == 0 else { throw ModelFailure.changed }
        var paths: [RepositoryQueryResult] = []
        var total = 0
        for raw in bytes.split(separator: 0) {
            try Task.checkCancellation()
            total += 1
            guard total <= 100_000 else {
                throw ModelFailure.unsupported(L10n.text("已跟踪路径超过搜索上限。"))
            }
            guard let path = String(data: raw, encoding: .utf8), !path.isEmpty,
                path.utf8.count <= 8192, !path.hasPrefix("/"),
                !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                    $0 == ".." || $0 == "." || $0.isEmpty
                })
            else { throw ModelFailure.invalidPath }
            if Self.queryMatches(query, [path]) { paths.append(.trackedPath(path)) }
        }
        return paths
    }

    private func queryReferences(_ query: String, categories: [RepositoryQueryScope]) async throws
        -> [RepositoryQueryScope: [RepositoryQueryResult]]
    {
        // Querying names must not compute ahead/behind graphs for every branch.
        let format =
            [
                "%(refname)", "%(objectname)", "%(objecttype)", "%(*objectname)", "%(*objecttype)",
                "%(symref)", "%(HEAD)", "%(worktreepath)",
            ].joined(separator: "%00") + "%00"
        let raw = try await engine.run(
            [
                "for-each-ref", "--count=10001", "--sort=refname", "--format=" + format,
                "refs/heads", "refs/remotes", "refs/tags",
            ],
            in: location.root, outputLimit: 8 * 1024 * 1024
        ).stdout
        guard raw.isEmpty || raw.last == 10 else { throw ModelFailure.changed }
        if raw.isEmpty { return [:] }
        let records = raw.split(separator: 0, omittingEmptySubsequences: false)
        guard records.last == Data([10]), (records.count - 1).isMultiple(of: 8) else {
            throw ModelFailure.changed
        }
        var values: [RepositoryQueryScope: [RepositoryQueryResult]] = [:]
        var total = 0
        for offset in stride(from: 0, to: records.count - 1, by: 8) {
            try Task.checkCancellation()
            total += 1
            guard total <= 10_000 else {
                throw ModelFailure.unsupported(L10n.text("引用数量超过搜索上限。"))
            }
            var first = records[offset]
            if offset > 0 {
                guard first.first == 10 else { throw ModelFailure.changed }
                first = first.dropFirst()
            }
            let fields = [first] + Array(records[(offset + 1)..<(offset + 8)])
            let strings = try fields.map { bytes -> String in
                guard let string = String(data: bytes, encoding: .utf8) else { throw ModelFailure.changed }
                return string
            }
            let reference = strings[0]
            guard GitObjectID.valid(strings[1]),
                strings[3].isEmpty || GitObjectID.valid(strings[3])
            else { throw ModelFailure.changed }
            if reference.hasPrefix("refs/tags/") {
                guard categories.contains(.tags) else { continue }
                let tag = GitTag(
                    reference: reference, objectID: strings[1],
                    targetCommit: strings[2] == "commit"
                        ? strings[1] : strings[4] == "commit" ? strings[3] : nil,
                    annotated: strings[2] == "tag", symbolicTarget: strings[5].isEmpty ? nil : strings[5])
                if Self.queryMatches(query, [tag.name, tag.reference, tag.objectID]) {
                    values[.tags, default: []].append(.tag(tag))
                }
            } else {
                guard categories.contains(.branches), strings[5].isEmpty,
                    reference.hasPrefix("refs/heads/") || reference.hasPrefix("refs/remotes/")
                else { continue }
                let branch = GitBranch(
                    id: reference,
                    name: String(reference.dropFirst(reference.hasPrefix("refs/heads/") ? 11 : 13)),
                    oid: strings[1], current: strings[6] == "*", upstream: "",
                    worktreePath: strings[7].isEmpty ? nil : strings[7])
                if Self.queryMatches(query, [branch.name, branch.id, branch.oid]) {
                    values[.branches, default: []].append(.branch(branch))
                }
            }
        }
        return values
    }
}
