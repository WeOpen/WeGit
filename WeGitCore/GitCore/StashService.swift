import Foundation

extension RepositoryService {
    @concurrent public func stashes(limit: Int = 200) async throws -> StashList {
        try location.validateIdentity()
        guard (1...10_000).contains(limit) else { throw ModelFailure.invalidPath }
        let raw = try await engine.run(
            [
                "stash", "list", "--no-color", "--encoding=UTF-8", "-z", "--format=%gd%x00%H%x00%ct%x00%gs",
                "--max-count=\(limit + 1)",
            ],
            in: location.root, outputLimit: 8 * 1024 * 1024, literalPathspecs: false
        ).stdout
        let entries = try StashParser.parse(raw)
        try location.validateIdentity()
        return StashList(
            entries: Array(entries.prefix(limit)), hasMore: entries.count > limit, limit: limit,
            token: raw, location: location)
    }

    @concurrent public func stashContents(_ entry: GitStash, in list: StashList) async throws -> StashContents
    {
        guard list.location == location, list.entries.contains(entry) else { throw ModelFailure.changed }
        let working = try await readCommit(entry.objectID)
        guard working.parents.count == 2 || working.parents.count == 3 else {
            throw ModelFailure.unsupported(L10n.text("此记录不是支持的 Stash 格式。"))
        }
        let index = try await readCommit(working.parents[1])
        guard index.parents == [working.parents[0]] else {
            throw ModelFailure.unsupported(L10n.text("此记录的暂存区基准无法可靠识别。"))
        }
        let untracked = working.parents.count == 3 ? try await readCommit(working.parents[2]) : nil
        guard untracked?.parents.isEmpty ?? true else {
            throw ModelFailure.unsupported(L10n.text("此记录的未跟踪文件基准无法可靠识别。"))
        }
        return StashContents(working: working, index: index, base: working.parents[0], untracked: untracked)
    }

    public func createStash(
        message: String, includeUntracked: Bool, expectedHead: String?, expectedFiles: [FileChange]? = nil
    ) async throws
        -> GitStash
    {
        try await queue.perform {
            try await verifyHead(expectedHead)
            let state = try await status()
            guard state.head != nil, state.sequencer == .none, state.conflicts.isEmpty else {
                throw ModelFailure.unsupported(L10n.text("请先创建提交并完成当前 Git 操作或冲突。"))
            }
            guard expectedFiles == nil || state.files == expectedFiles else { throw ModelFailure.changed }
            guard !message.contains("\0"), message.utf8.count <= 4096 else { throw ModelFailure.invalidPath }
            guard state.files.contains(where: { !$0.untracked || includeUntracked }) else {
                throw ModelFailure.unsupported(L10n.text("没有可保存的改动，请检查是否需要包含未跟踪文件。"))
            }
            try await protectStashObstructions(state, includeUntracked: includeUntracked)
            let previous = try await stashes()
            // These commands take no file pathspec. Forcing literal pathspecs
            // also affects Git's internal clean command and can leave specially
            // named untracked files behind after they have been saved.
            var arguments = ["stash", "push"]
            if !message.isEmpty { arguments += ["--message", message] }
            if includeUntracked { arguments.append("--include-untracked") }
            try await verifyHead(expectedHead)
            do {
                _ = try await engine.run(arguments, in: location.root, timeout: 120, literalPathspecs: false)
            } catch {
                let observed = await Task.detached { try? await stashes() }.value
                if let observed, observed.token != previous.token {
                    throw ModelFailure.unsupported(L10n.text("暂存操作未完整返回，记录列表已变化。请刷新核对，不要直接重复保存。"))
                }
                throw error
            }
            let fresh = try await stashes()
            guard fresh.token != previous.token, let created = fresh.entries.first else {
                throw ModelFailure.unsupported(L10n.text("未能确认新的储藏，请核对工作区和记录列表。"))
            }
            return created
        }
    }

    public func restoreStash(
        _ entry: GitStash, in list: StashList, restoreIndex: Bool, pop: Bool, expectedHead: String?
    ) async throws -> StashRestoreOutcome {
        try await queue.perform {
            try await verifyHead(expectedHead)
            let state = try await status()
            guard state.head != nil, state.sequencer == .none, state.files.allSatisfy(\.untracked) else {
                throw ModelFailure.unsupported(L10n.text("恢复前请先提交或保存已跟踪文件的改动，并完成进行中的 Git 操作。"))
            }
            let contents = try await stashContents(entry, in: list)
            try await protectStashRestore(contents, restoreIndex: restoreIndex)
            try await verifyStashEntry(entry, in: list)
            var arguments = ["stash", "apply"]
            if restoreIndex { arguments.append("--index") }
            arguments.append(entry.objectID)
            try await verifyHead(expectedHead)
            do {
                _ = try await engine.run(arguments, in: location.root, timeout: 120, literalPathspecs: false)
            } catch {
                let fresh = await Task.detached { try? await status() }.value
                if let fresh, !fresh.conflicts.isEmpty {
                    throw ModelFailure.unsupported(L10n.text("恢复产生冲突，储藏已保留。请在更改页面解决冲突，再正常提交；这不是可中止的合并操作。"))
                }
                throw error
            }
            guard pop else { return .applied }
            do {
                // Apply is pinned to the immutable object. Removal is a separate
                // operation, permitted only while the confirmed reflog is unchanged.
                try await verifyHead(expectedHead)
                try await verifyStashEntry(entry, in: list)
                try await dropStashEntry(entry)
                return .popped
            } catch {
                return .appliedNeedsReview(error.localizedDescription)
            }
        }
    }

    public func deleteStash(_ entry: GitStash, in list: StashList, expectedHead: String?) async throws {
        try await queue.perform {
            try await verifyHead(expectedHead)
            try await verifyStashEntry(entry, in: list)
            try await dropStashEntry(entry)
        }
    }

    /// Git's numeric reflog selectors can move after preflight when another
    /// process writes. Check the actual removed object and restore it immediately
    /// if it was not the confirmed object. Never silently accept a different drop.
    private func dropStashEntry(_ entry: GitStash) async throws {
        let directory = try await SnapshotIO.run { _ in try SnapshotDirectory() }
        defer { withExtendedLifetime(directory) {} }
        let receipt = directory.url.appending(path: "stash-drop.txt")
        var failure: (any Error)?
        do {
            _ = try await engine.run(
                ["stash", "drop", entry.selector], in: location.root, outputLimit: 4096,
                stdoutFile: receipt, literalPathspecs: false)
        } catch { failure = error }
        // A cancelled command can already have changed the reflog. Read its
        // private receipt in a fresh task before deciding how to report it.
        let data = await Task.detached { try? Data(contentsOf: receipt) }.value
        if let data, let text = String(data: data, encoding: .utf8) {
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Dropped "), line.hasSuffix(")"), let open = line.lastIndex(of: "(") {
                let removed = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
                if GitObjectID.valid(removed) {
                    if removed == entry.objectID {
                        if let failure { throw failure }
                        return
                    }
                    do {
                        _ = try await Task.detached {
                            try await engine.run(
                                ["stash", "store", "--message", L10n.text("并发变化后恢复的储藏"), removed],
                                in: location.root, literalPathspecs: false)
                        }.value
                    } catch {
                        throw ModelFailure.unsupported(
                            L10n.text("记录列表发生并发变化，恢复移除记录未完成。请保留此对象并核对：") + removed)
                    }
                    throw ModelFailure.unsupported(L10n.text("记录列表在操作时发生变化，移除的记录已重新保存，请刷新核对。"))
                }
            }
        }
        if let failure { throw failure }
        throw ModelFailure.unsupported(L10n.text("删除结果未能可靠确认，请刷新记录列表后核对。"))
    }

    private func verifyStashEntry(_ entry: GitStash, in list: StashList) async throws {
        guard list.location == location, list.entries.contains(entry) else { throw ModelFailure.changed }
        let fresh = try await stashes(limit: list.limit)
        guard fresh.token == list.token, fresh.entries.contains(entry) else { throw ModelFailure.changed }
    }

    private func protectStashObstructions(_ state: RepositoryStatus, includeUntracked: Bool) async throws {
        let indexed = try await stashIndexFiles()
        let rawHead = try await engine.run(
            ["ls-tree", "-r", "-z", "--full-tree", "HEAD"], in: location.root, outputLimit: 32 * 1024 * 1024
        ).stdout
        var targets = indexed
        for record in rawHead.split(separator: 0) {
            guard let tab = record.firstIndex(of: 9),
                let header = String(data: record[..<tab], encoding: .utf8),
                let path = String(data: record[record.index(after: tab)...], encoding: .utf8)
            else { throw ModelFailure.changed }
            if header.hasPrefix("160000 ") {
                throw ModelFailure.unsupported(L10n.text("当前版本不在包含子模块的仓库中执行 Stash。"))
            }
            targets.insert(path)
        }
        var saved = indexed
        if includeUntracked {
            let untracked = Set(state.files.filter(\.untracked).map(\.path))
            targets.formUnion(untracked)
            saved.formUnion(untracked)
        }
        try await StashWorktreeGuard.validate(paths: targets, tracked: saved, location: location)
    }

    private func stashIndexFiles() async throws -> Set<String> {
        let raw = try await engine.run(
            ["ls-files", "--stage", "-v", "-z"], in: location.root, outputLimit: 32 * 1024 * 1024
        ).stdout
        var paths: Set<String> = []
        for record in raw.split(separator: 0) {
            guard let tab = record.firstIndex(of: 9),
                let header = String(data: record[..<tab], encoding: .utf8),
                let path = String(data: record[record.index(after: tab)...], encoding: .utf8)
            else { throw ModelFailure.changed }
            let fields = header.split(separator: " ")
            guard fields.count == 4, fields[0] == "H", fields[3] == "0" else {
                throw ModelFailure.unsupported(L10n.text("请先处理特殊索引标记或未合并条目，再执行 Stash。"))
            }
            guard fields[1] != "160000" else {
                throw ModelFailure.unsupported(L10n.text("当前版本不在包含子模块的仓库中执行 Stash。"))
            }
            paths.insert(path)
        }
        return paths
    }

    private func protectStashRestore(_ contents: StashContents, restoreIndex: Bool) async throws {
        let working = try await commitComparison(id: contents.working.id, parent: contents.base)
        var paths = Set(working.files.flatMap { [$0.path] + [$0.oldPath].compactMap { $0 } })
        if restoreIndex {
            let index = try await commitComparison(id: contents.index.id, parent: contents.base)
            paths.formUnion(index.files.flatMap { [$0.path] + [$0.oldPath].compactMap { $0 } })
        }
        if let untracked = contents.untracked {
            let comparison = try await commitComparison(id: untracked.id)
            paths.formUnion(comparison.files.map(\.path))
        }
        let tracked = try await stashIndexFiles()
        try await StashWorktreeGuard.validate(paths: paths, tracked: tracked, location: location)
    }
}
