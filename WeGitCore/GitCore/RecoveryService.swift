import Darwin
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

    @concurrent public func reflogVersion(ref: String = "HEAD") async throws -> ReflogVersion {
        guard ref == "HEAD" || ref.hasPrefix("refs/heads/") else { throw ModelFailure.invalidPath }
        if ref != "HEAD" { _ = try await recoveryEngine.run(["check-ref-format", ref], in: location.root) }
        return try await SnapshotIO.run { _ in
            try location.validateIdentity()
            let base = ref == "HEAD" ? location.gitDirectory : location.commonDirectory
            let node = try RepositoryNodeIdentity.readIfPresent(base.appending(path: "logs/" + ref))
            if let node, node.kind != UInt16(S_IFREG) { throw ModelFailure.changed }
            let fingerprint = node.map {
                RecoveryFileIO.hash(
                    Data(
                        "\($0.device):\($0.inode):\($0.markerSize ?? 0):\($0.markerModifiedSeconds ?? 0):\($0.markerModifiedNanoseconds ?? 0):\($0.markerChangedSeconds ?? 0):\($0.markerChangedNanoseconds ?? 0)"
                            .utf8))
            }
            return ReflogVersion(workspaceID: location.persistenceID, ref: ref, fingerprint: fingerprint)
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

    @concurrent public func exportRecoveryRecord(_ record: RecoveryRecord, to parent: URL) async throws -> URL
    {
        try await queue.perform {
            let store = try RecoveryStore(location: location)
            let (files, index) = try await store.capture(record)
            return try await SnapshotIO.run { cancellation in
                let destination = parent.resolvingSymlinksInPath()
                let identity = try RepositoryNodeIdentity.read(destination, directory: true)
                let root = Darwin.open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard root >= 0 else { throw ModelFailure.invalidPath }
                defer { Darwin.close(root) }
                var rootInfo = stat()
                guard fstat(root, &rootInfo) == 0, rootInfo.st_dev == identity.device,
                    rootInfo.st_ino == identity.inode,
                    rootInfo.st_birthtimespec.tv_sec == identity.bornSeconds,
                    rootInfo.st_birthtimespec.tv_nsec == identity.bornNanoseconds
                else { throw ModelFailure.changed }
                let name = "WeGit-Recovery-" + record.id.uuidString + ".wegitbackup"
                guard mkdirat(root, name, 0o700) == 0 else { throw ProcessFailure.outputWrite(errno) }
                let directory = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directory >= 0 else { throw ProcessFailure.outputWrite(errno) }
                defer { Darwin.close(directory) }
                func write(_ name: String, _ data: Data) throws {
                    let fd = openat(
                        directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard fd >= 0 else { throw ProcessFailure.outputWrite(errno) }
                    defer { Darwin.close(fd) }
                    try RecoveryFileIO.write(data, descriptor: fd, cancellation: cancellation)
                    guard fsync(fd) == 0 else { throw ProcessFailure.outputWrite(errno) }
                }
                if let index { try write("index", index) }
                for file in files {
                    guard let snapshot = file.snapshot else { continue }
                    guard
                        try RecoveryFileIO.copy(
                            snapshot, directory: directory, name: file.file.storageName,
                            cancellation: cancellation) == file.file.sha256
                    else { throw ModelFailure.changed }
                }
                try write("record.json", JSONEncoder().encode(record))
                guard fsync(directory) == 0, fsync(root) == 0,
                    try RepositoryNodeIdentity.read(destination, directory: true) == identity,
                    try store.record(record.id) == record
                else { throw ModelFailure.changed }
                return destination.appending(path: name, directoryHint: .isDirectory)
            }
        }
    }

    @concurrent public func prepareReset(target: String, mode: ResetMode = .soft, sourceRef: String? = nil)
        async throws -> ResetPlan
    {
        try await queue.perform {
            let state = try await status()
            guard let head = state.head, state.sequencer == .none, state.conflicts.isEmpty else {
                throw ModelFailure.unsupported(L10n.text("Reset 需要已有提交，并先完成当前 Git 操作。"))
            }
            let reader = RepositoryService(location: location, engine: recoveryEngine, queue: queue)
            let commit = try await reader.readCommit(target)
            try await verifyResetSource(sourceRef, target: commit.id)
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
            let currentSubmodules = Set(entries.filter { $0.value == "160000" }.map(\.key))
            if mode == .hard {
                // Explicitly leave submodule working trees alone, regardless of
                // the user's submodule.recurse setting. Their gitlinks remain in the index backup.
                let tree = try await recoveryEngine.run(
                    ["ls-tree", "-r", "-z", commit.id], in: location.root,
                    outputLimit: 32 * 1024 * 1024
                ).stdout
                var targetModes: [String: String] = [:]
                for row in tree.split(separator: 0) {
                    guard let tab = row.firstIndex(of: 9),
                        let text = String(data: row[..<tab], encoding: .utf8),
                        let path = String(data: row[row.index(after: tab)...], encoding: .utf8)
                    else { throw ModelFailure.changed }
                    targetModes[path] = String(text.prefix(6))
                }
                for path in paths {
                    if let current = entries[path], let target = targetModes[path],
                        (current == "160000") != (target == "160000")
                    {
                        throw ModelFailure.unsupported(
                            L10n.text("子模块与普通文件的替换需先单独处理；Soft 或 Mixed Reset 会保留工作文件。"))
                    }
                }
                let submodules = Set(targetModes.filter { $0.value == "160000" }.map(\.key)).union(
                    currentSubmodules)
                let filePaths = paths.subtracting(submodules)
                try await StashWorktreeGuard.validate(
                    paths: paths, tracked: Set(entries.keys), location: location,
                    allowedDirectories: currentSubmodules)
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
                index: index, captures: captures, statusFiles: state.files,
                sourceRef: sourceRef, trackedPaths: Set(entries.keys), submoduleDirectories: currentSubmodules
            )
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
                    // Compare index object IDs/modes directly. Reconstructing a
                    // tree merely to verify it needlessly writes Git objects.
                    let compared = try await recoveryEngine.run(
                        [
                            "diff-index", "--cached", "--quiet", "--no-ext-diff", "--no-renames",
                            "--ignore-submodules=none", "--ita-visible-in-index", plan.target.id, "--",
                        ],
                        in: location.root, accepted: [0, 1], outputLimit: 64 * 1024)
                    guard compared.exitCode == 0 else { throw ModelFailure.changed }
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
        try await verifyResetSource(plan.sourceRef, target: plan.target.id)
        let state = try await status()
        guard state.branch == plan.branch, state.sequencer == .none, state.files == plan.statusFiles,
            try SelectedIndexSnapshot.read(location: location) == plan.index
        else { throw ModelFailure.changed }
        if plan.mode == .hard {
            try await StashWorktreeGuard.validate(
                paths: Set(plan.files), tracked: plan.trackedPaths,
                location: location, allowedDirectories: plan.submoduleDirectories)
        }
        try await RecoveryFileIO.verifyAll(plan.captures, location: location)
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
            try await RecoveryFileIO.verifyAll(plan.currentFiles, location: location)
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
                if plan.layer != .index {
                    try await RecoveryFileIO.installAll(
                        sources: plan.sourceFiles, expected: plan.currentFiles, location: location)
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
                    try await RecoveryFileIO.verifyContentsAll(plan.sourceFiles, location: location)
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

    private func verifyResetSource(_ ref: String?, target: String) async throws {
        guard let ref else { return }
        guard ref.hasPrefix("refs/heads/") || ref.hasPrefix("refs/remotes/") || ref.hasPrefix("refs/tags/")
        else { throw ModelFailure.invalidPath }
        _ = try await recoveryEngine.run(["check-ref-format", ref], in: location.root)
        let value = try await recoveryEngine.run(
            ["rev-parse", "--verify", ref + "^{commit}"], in: location.root
        ).text.removingLastNewline
        guard value == target else { throw ModelFailure.changed }
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
        try await RecoveryFileIO.captureAll(location: location, paths: paths)
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
