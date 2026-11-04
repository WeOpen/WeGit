import Foundation

extension RepositoryService {
    var recoveryEngine: GitEngine {
        var value = engine
        value.environment["GIT_NO_LAZY_FETCH"] = "1"
        value.environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        return value
    }

    @concurrent public func reflog(ref: String = "HEAD", offset: Int = 0, limit: Int = 100) async throws
        -> [ReflogEntry]
    {
        try location.validateIdentity()
        guard (0...1000).contains(offset), (1...100).contains(limit),
            ref == "HEAD" || ref.hasPrefix("refs/heads/")
        else { throw ModelFailure.invalidPath }
        if ref != "HEAD" { _ = try await recoveryEngine.run(["check-ref-format", ref], in: location.root) }
        let result = try await recoveryEngine.run(
            [
                "reflog", "show", "-z", "--date=unix", "--format=%H%x00%gD%x00%gs",
                "--max-count=\(limit)", "--skip=\(offset)", ref,
            ], in: location.root,
            accepted: [0, 128], outputLimit: 2 * 1024 * 1024)
        if result.exitCode == 128 { return [] }
        let rows = try Self.parseReflog(result.stdout)
        guard !rows.isEmpty else { return [] }
        let objects = Array(Set(rows.map(\.object))).sorted()
        let checked = try await recoveryEngine.run(
            ["cat-file", "--batch-check"], in: location.root,
            input: Data((objects.joined(separator: "\n") + "\n").utf8),
            outputLimit: 32 * 1024)
        let existence = checked.text.split(separator: "\n").map { $0.split(separator: " ") }
        guard existence.count == objects.count else { throw ModelFailure.changed }
        var available: Set<String> = []
        for (index, fields) in existence.enumerated() {
            guard fields.first == Substring(objects[index]), fields.count >= 2 else {
                throw ModelFailure.changed
            }
            if fields[1] == "commit" { available.insert(objects[index]) }
        }
        return rows.enumerated().map { index, entry in
            ReflogEntry(
                object: entry.object, selector: entry.selector, message: entry.message,
                date: entry.date, objectExists: available.contains(entry.object), position: offset + index)
        }
    }

    static func parseReflog(_ data: Data) throws -> [ReflogEntry] {
        guard data.isEmpty || data.last == 0 else { throw ModelFailure.invalidOutput("reflog") }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count % 3 == 0 else { throw ModelFailure.invalidOutput("reflog fields") }
        var result: [ReflogEntry] = []
        for index in stride(from: 0, to: fields.count, by: 3) {
            guard let oid = String(data: fields[index], encoding: .utf8), GitObjectID.valid(oid),
                let selector = String(data: fields[index + 1], encoding: .utf8),
                let message = String(data: fields[index + 2], encoding: .utf8)
            else { throw ModelFailure.invalidOutput("reflog entry") }
            let timestamp = selector.split(separator: "{").last?.dropLast()
            let date = timestamp.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
            result.append(
                ReflogEntry(
                    object: oid, selector: selector, message: message, date: date, objectExists: false,
                    position: index / 3))
        }
        return result
    }

    @concurrent public func recoveryRecords() async throws -> [RecoveryRecord] {
        try await SnapshotIO.run { _ in try RecoveryStore(location: location).records() }
    }

    public func removeRecoveryRecord(_ record: RecoveryRecord) async throws {
        try await withSharedOperation {
            let store = try RecoveryStore(location: location)
            try await removeRecovery(record, store: store)
        }
    }

    @concurrent public func prepareReset(target: String, mode: ResetMode = .soft) async throws -> ResetPlan {
        try await queue.perform {
            let state = try await status()
            guard let head = state.head, state.sequencer == .none, state.conflicts.isEmpty else {
                throw ModelFailure.unsupported(L10n.text("Reset 需要已有提交，并先完成当前 Git 操作。"))
            }
            let reader = RepositoryService(location: location, engine: recoveryEngine, queue: queue)
            let commit = try await reader.readCommit(target)
            let index = try SelectedIndexSnapshot.read(location: location)
            let listing = try await recoveryEngine.run(
                ["ls-files", "--stage", "-v", "-z"], in: location.root,
                outputLimit: 32 * 1024 * 1024
            ).stdout
            let entries = try recoveryIndexEntries(listing, requireOrdinary: mode != .soft)
            if mode != .soft {
                let shared = try await recoveryEngine.run(
                    ["rev-parse", "--shared-index-path"], in: location.root
                ).stdout
                guard shared.isEmpty || shared == Data([10]) else {
                    throw ModelFailure.unsupported(L10n.text("此索引使用拆分存储；请先使用 Soft Reset 保留暂存区。"))
                }
            }
            let changed = try await recoveryEngine.run(
                ["diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", head, commit.id, "--"],
                in: location.root, outputLimit: 32 * 1024 * 1024
            ).stdout
            var paths = Set(try recoveryPaths(changed))
            for file in state.files where !file.untracked {
                paths.insert(file.path)
                if let old = file.oldPath { paths.insert(old) }
            }
            guard paths.count <= RecoveryBudget.files else { throw RecoveryBudget.exceeded }
            var captures: [RecoveryFileCapture] = []
            if mode == .hard {
                // Explicitly leave submodule working trees alone, regardless of
                // the user's submodule.recurse setting. Their gitlinks remain in the index backup.
                let tree = try await recoveryEngine.run(
                    ["ls-tree", "-r", "-z", commit.id], in: location.root,
                    outputLimit: 32 * 1024 * 1024
                ).stdout
                let submodules = Set(
                    try tree.split(separator: 0).compactMap { row -> String? in
                        guard let tab = row.firstIndex(of: 9),
                            let text = String(data: row[..<tab], encoding: .utf8)
                        else { throw ModelFailure.changed }
                        if text.hasPrefix("160000 ") {
                            return String(data: row[row.index(after: tab)...], encoding: .utf8)
                        }
                        return nil
                    }
                ).union(entries.filter { $0.value == "160000" }.map(\.key))
                let filePaths = paths.subtracting(submodules)
                try await StashWorktreeGuard.validate(
                    paths: filePaths, tracked: Set(entries.keys), location: location)
                captures = try await captureRecoveryFiles(filePaths.sorted())
            }
            let refs = try await recoveryEngine.run(
                ["for-each-ref", "--contains=" + head, "--format=%(refname)", "refs/remotes"],
                in: location.root, outputLimit: 64 * 1024
            ).text.split(separator: "\n").map(String.init)
            try await verifyHead(head)
            let fresh = try await status()
            guard fresh.branch == state.branch, fresh.files == state.files, fresh.sequencer == .none,
                try SelectedIndexSnapshot.read(location: location) == index
            else { throw ModelFailure.changed }
            return ResetPlan(
                id: UUID(), mode: mode, target: commit, head: head, branch: state.branch,
                files: paths.sorted(), publishedTrackingRefs: refs, location: location,
                index: index, captures: captures, statusFiles: state.files)
        }
    }

    public func executeReset(_ plan: ResetPlan) async throws -> RecoveryRecord {
        try await withSharedOperation {
            guard plan.location == location else { throw ModelFailure.changed }
            try await validateReset(plan)
            let store = try RecoveryStore(location: location)
            try await trimRecovery(store)
            var record = try await store.persist(
                operation: "reset-" + plan.mode.rawValue, head: plan.head,
                branch: plan.branch, target: plan.target.id,
                index: plan.index, files: plan.captures)
            do {
                try await protectRecovery(record)
                try await validateReset(plan)
                _ = try await recoveryEngine.run(
                    ["reset", "--" + plan.mode.rawValue, "--no-recurse-submodules", plan.target.id],
                    in: location.root, timeout: 120)
                let observed = try await status()
                guard observed.head == plan.target.id, observed.branch == plan.branch,
                    observed.sequencer == .none
                else {
                    throw ModelFailure.changed
                }
                if plan.mode == .soft {
                    guard try SelectedIndexSnapshot.read(location: location) == plan.index else {
                        throw ModelFailure.changed
                    }
                } else {
                    let tree = try await recoveryEngine.run(["write-tree"], in: location.root).text
                        .removingLastNewline
                    let targetTree = try await singleCommitTree(plan.target.id, engine: recoveryEngine)
                    guard tree == targetTree else { throw ModelFailure.changed }
                    if plan.mode == .hard {
                        let diff = try await recoveryEngine.run(
                            ["diff", "--exit-code", "--no-ext-diff", "--ignore-submodules=all", "--"],
                            in: location.root, accepted: [0, 1], outputLimit: 64 * 1024)
                        guard diff.exitCode == 0 else { throw ModelFailure.changed }
                    }
                }
                record.state = .succeeded
                record.observedHead = observed.head
                try store.save(record)
                return record
            } catch {
                let details = Redaction.text((error as? GitFailure)?.details ?? error.localizedDescription)
                record.state = .needsVerification
                record.details = String(details.prefix(8192))
                let saved = record
                await Task.detached {
                    var value = saved
                    value.observedHead = try? await self.head()
                    try? store.save(value)
                }.value
                throw RecoveryOutcomeUnknown(recordID: record.id, details: details)
            }
        }
    }

    private func validateReset(_ plan: ResetPlan) async throws {
        try await verifyHead(plan.head)
        let state = try await status()
        guard state.branch == plan.branch, state.sequencer == .none, state.files == plan.statusFiles,
            try SelectedIndexSnapshot.read(location: location) == plan.index
        else { throw ModelFailure.changed }
        for capture in plan.captures {
            try await RecoveryFileIO.verify(capture, location: location)
        }
        try await verifyHead(plan.head)
    }

    @concurrent public func prepareRecoveryRestore(_ record: RecoveryRecord, layer: RecoveryLayer = .worktree)
        async throws -> RecoveryRestorePlan
    {
        try await queue.perform {
            let state = try await status()
            guard state.sequencer == .none, state.conflicts.isEmpty else {
                throw ModelFailure.unsupported(L10n.text("请先完成当前 Git 操作，再恢复备份。"))
            }
            let store = try RecoveryStore(location: location)
            let (source, index) = try await store.capture(record)
            let current = try await captureRecoveryFiles(layer == .index ? [] : record.files.map(\.path))
            let snapshot = try SelectedIndexSnapshot.read(location: location)
            try await verifyHead(state.head)
            return RecoveryRestorePlan(
                id: UUID(), record: record, layer: layer,
                currentHead: state.head, currentBranch: state.branch,
                location: location, index: snapshot, currentFiles: current,
                sourceFiles: source, sourceIndex: index)
        }
    }

    public func executeRecoveryRestore(_ plan: RecoveryRestorePlan) async throws -> RecoveryRecord {
        try await withSharedOperation {
            guard plan.location == location else { throw ModelFailure.changed }
            try await verifyHead(plan.currentHead)
            let state = try await status()
            guard state.branch == plan.currentBranch, state.sequencer == .none,
                try SelectedIndexSnapshot.read(location: location) == plan.index
            else { throw ModelFailure.changed }
            for capture in plan.currentFiles {
                try await RecoveryFileIO.verify(capture, location: location)
            }
            let store = try RecoveryStore(location: location)
            guard try store.record(plan.record.id) == plan.record else { throw ModelFailure.changed }
            try await trimRecovery(store, preserving: plan.record.id)
            var backup = try await store.persist(
                operation: "restore-backup", head: plan.currentHead, branch: plan.currentBranch,
                target: nil, index: plan.index, files: plan.currentFiles)
            do {
                try await protectRecovery(backup)
                let lease = try SelectedIndexLease(location: location, snapshot: plan.index)
                try await verifyHead(plan.currentHead)
                if plan.layer != .worktree, let bytes = plan.sourceIndex { try lease.write(bytes) }
                var created: [String: ConflictEditorDirectoryIdentity] = [:]
                if plan.layer != .index {
                    for (index, expected) in plan.currentFiles.enumerated() {
                        created = try await RecoveryFileIO.install(
                            source: plan.sourceFiles[index], expected: expected,
                            location: location, createdDirectories: created)
                    }
                }
                try await verifyHead(plan.currentHead)
                try lease.verify()
                if plan.layer != .worktree {
                    if plan.sourceIndex == nil { try lease.removeIndex() } else { try lease.install() }
                }
                if plan.layer == .worktree {
                    guard try SelectedIndexSnapshot.read(location: location) == plan.index else {
                        throw ModelFailure.changed
                    }
                } else {
                    guard try SelectedIndexSnapshot.read(location: location).bytes == plan.sourceIndex else {
                        throw ModelFailure.changed
                    }
                }
                if plan.layer != .index {
                    for file in plan.sourceFiles {
                        let observed = try await RecoveryFileIO.capture(
                            location: location, path: file.file.path, name: file.file.storageName)
                        guard observed.file.kind == file.file.kind, observed.file.sha256 == file.file.sha256,
                            observed.file.mode == file.file.mode
                        else { throw ModelFailure.changed }
                    }
                }
                backup.state = .succeeded
                backup.observedHead = plan.currentHead
                try store.save(backup)
                var original = plan.record
                original.state = .restored
                try store.save(original)
                withExtendedLifetime(lease) {}
                return backup
            } catch {
                backup.state = .needsVerification
                backup.details = Redaction.text(error.localizedDescription)
                let saved = backup
                await Task.detached { try? store.save(saved) }.value
                throw RecoveryOutcomeUnknown(recordID: backup.id, details: error.localizedDescription)
            }
        }
    }

    private func recoveryRef(_ record: RecoveryRecord) -> String {
        "refs/wegit/recovery/" + record.id.uuidString.lowercased()
    }

    private func protectRecovery(_ record: RecoveryRecord) async throws {
        guard let head = record.head else { return }
        try await verifyCommit(head)
        _ = try await recoveryEngine.run(
            [
                "update-ref", "--no-deref", recoveryRef(record), head,
                String(repeating: "0", count: head.count),
            ], in: location.root)
    }

    private func removeRecovery(_ record: RecoveryRecord, store: RecoveryStore) async throws {
        guard try store.record(record.id) == record else { throw ModelFailure.changed }
        if let head = record.head {
            let ref = recoveryRef(record)
            let symbolic = try await recoveryEngine.run(
                ["symbolic-ref", "-q", ref], in: location.root, accepted: [0, 1])
            guard symbolic.exitCode == 1 else { throw ModelFailure.changed }
            let value = try await recoveryEngine.run(
                ["rev-parse", "--verify", ref], in: location.root, accepted: [0, 128])
            if value.exitCode == 0 {
                guard value.text.removingLastNewline == head else { throw ModelFailure.changed }
                _ = try await recoveryEngine.run(
                    ["update-ref", "--no-deref", "-d", ref, head], in: location.root)
            }
        }
        try await SnapshotIO.run { _ in try store.remove(record) }
    }

    private func trimRecovery(_ store: RecoveryStore, preserving: UUID? = nil) async throws {
        let records = try await SnapshotIO.run { _ in try store.records() }
        for (index, record) in records.enumerated()
        where record.id != preserving && (record.state == .succeeded || record.state == .restored) {
            if index >= RecoveryBudget.records - 1
                || Date().timeIntervalSince(record.createdAt) > RecoveryBudget.days
            {
                try await removeRecovery(record, store: store)
            }
        }
    }

    func captureRecoveryFiles(_ paths: [String]) async throws -> [RecoveryFileCapture] {
        guard paths.count <= RecoveryBudget.files else { throw RecoveryBudget.exceeded }
        var files: [RecoveryFileCapture] = []
        var bytes = 0
        for (index, path) in paths.enumerated() {
            let file = try await RecoveryFileIO.capture(location: location, path: path, name: "blob-\(index)")
            bytes += file.file.bytes
            guard bytes <= RecoveryBudget.bytes else { throw RecoveryBudget.exceeded }
            files.append(file)
        }
        return files
    }

    func recoveryPaths(_ data: Data) throws -> [String] {
        guard data.isEmpty || data.last == 0 else { throw ModelFailure.changed }
        return try data.split(separator: 0).map {
            guard let path = String(data: $0, encoding: .utf8) else { throw ModelFailure.invalidPath }
            try RecoveryFileIO.validate(path)
            return path
        }
    }

    private func recoveryIndexEntries(_ data: Data, requireOrdinary: Bool) throws -> [String: String] {
        guard data.isEmpty || data.last == 0 else { throw ModelFailure.changed }
        var entries: [String: String] = [:]
        for row in data.split(separator: 0) {
            guard let tab = row.firstIndex(of: 9), let header = String(data: row[..<tab], encoding: .utf8),
                let path = String(data: row[row.index(after: tab)...], encoding: .utf8)
            else { throw ModelFailure.invalidPath }
            let fields = header.split(separator: " ")
            guard fields.count == 4, !requireOrdinary || fields[0] == "H" && fields[3] == "0" else {
                throw ModelFailure.unsupported(L10n.text("索引有特殊标记或冲突阶段；Soft Reset 可保留它们，其他模式需先处理。"))
            }
            try RecoveryFileIO.validate(path)
            entries[path] = String(fields[1])
        }
        return entries
    }
}
