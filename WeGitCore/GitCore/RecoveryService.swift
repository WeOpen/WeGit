import Darwin
import Foundation

extension RepositoryService {
    @concurrent public func prepareFileRestore(
        revision: String, sourcePath: String, destinationPath: String? = nil,
        layer: RecoveryLayer = .worktree
    ) async throws -> FileModificationPlan {
        try RecoveryFileIO.validate(sourcePath)
        let path = destinationPath ?? sourcePath
        try RecoveryFileIO.validate(path)
        guard !revision.isEmpty, !revision.hasPrefix("-"), !revision.contains("\0"),
            revision.utf8.count <= 8192
        else { throw ModelFailure.invalidPath }
        let commit = try await recoveryEngine.run(
            ["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], in: location.root
        ).text.removingLastNewline
        guard GitObjectID.valid(commit) else { throw ModelFailure.changed }
        let tree = try await recoveryEngine.run(
            ["ls-tree", "-z", commit, "--", sourcePath], in: location.root, outputLimit: 128 * 1024
        ).stdout
        let rows = tree.split(separator: 0)
        guard rows.count <= 1 else { throw ModelFailure.changed }
        var mode: String?
        var object: String?
        var desired: RecoveryFileCapture
        if let row = rows.first {
            guard let tab = row.firstIndex(of: 9),
                String(data: row[row.index(after: tab)...], encoding: .utf8) == sourcePath
            else { throw ModelFailure.changed }
            let fields = String(decoding: row[..<tab], as: UTF8.self).split(separator: " ").map(String.init)
            guard fields.count == 3, fields[1] == "blob", ["100644", "100755", "120000"].contains(fields[0]),
                GitObjectID.valid(fields[2])
            else {
                throw ModelFailure.unsupported(L10n.text("此历史对象不是普通文件或符号链接。"))
            }
            mode = fields[0]
            object = fields[2]
            let size = try await recoveryEngine.run(["cat-file", "-s", fields[2]], in: location.root).text
                .removingLastNewline
            guard let bytes = Int(size), (0...RecoveryBudget.bytes).contains(bytes) else {
                throw RecoveryBudget.exceeded
            }
            let storage = try await SnapshotIO.run { _ in try SnapshotDirectory() }
            let output = storage.url.appending(path: "blob-0")
            _ = try await recoveryEngine.run(
                ["cat-file", "blob", fields[2]], in: location.root, timeout: 120,
                outputLimit: RecoveryBudget.bytes, stdoutFile: output)
            let snapshot = try await SnapshotIO.run { cancellation in
                let source = try SnapshotFile(directory: storage, url: output)
                let input = try source.open()
                defer { Darwin.close(input) }
                let hash = try RecoveryFileIO.hashFile(
                    input, expectedBytes: bytes, cancellation: cancellation)
                return (try SnapshotFile(directory: storage, url: output, verifiedSHA256: hash), hash)
            }
            desired = RecoveryFileCapture(
                file: RecoveryFile(
                    path: path, kind: mode == "120000" ? .symbolicLink : .file,
                    mode: mode == "120000" ? 0o777 : mode == "100755" ? 0o755 : 0o644,
                    bytes: bytes, sha256: snapshot.1, storageName: "blob-0"), snapshot: snapshot.0,
                version: nil, parents: [], missingParent: nil)
        } else {
            desired = try await RecoveryFileIO.replacement(path: path, data: nil, mode: 0o644)
        }
        return try await prepareFileModification(
            path: path, desired: desired, operation: "file-restore", layer: layer,
            sourceRevision: commit, sourceMode: mode, sourceObject: object)
    }

    @concurrent func prepareFileModification(
        path: String, desired: RecoveryFileCapture, operation: String,
        layer: RecoveryLayer, sourceRevision: String? = nil, sourceMode: String? = nil,
        sourceObject: String? = nil,
        selectedLines: Int? = nil, filterPath: String? = nil
    ) async throws -> FileModificationPlan {
        try await queue.perform {
            try RecoveryFileIO.validate(path)
            let context = try await recoveryContext()
            let index = try SelectedIndexSnapshot.read(location: location)
            let shared = try await captureRecoverySharedIndex(index)
            let current = try await RecoveryFileIO.capture(location: location, path: path, name: "blob-0")
            let candidate =
                layer == .worktree
                ? nil
                : try await replacementIndex(path: path, mode: sourceMode, object: sourceObject, index: index)
            let preview = try await RecoveryFileIO.preview(desired)
            let final = try await recoveryContext()
            guard final.head == context.head, final.branch == context.branch, desired.file.path == path,
                try SelectedIndexSnapshot.read(location: location) == index
            else { throw ModelFailure.changed }
            try await RecoveryFileIO.verifyAll([current], location: location)
            return FileModificationPlan(
                id: UUID(), path: path, sourceRevision: sourceRevision, layer: layer,
                selectedLineCount: selectedLines, originalBytes: current.file.bytes,
                resultBytes: desired.file.bytes,
                deletesFile: desired.file.kind == .absent, resultPreview: preview,
                operation: operation, location: location,
                head: context.head,
                branch: context.branch, index: index, sharedIndex: shared, current: current, desired: desired,
                candidateIndex: candidate, filterPath: filterPath, sourceObject: sourceObject)
        }
    }

    public func executeFileModification(_ plan: FileModificationPlan) async throws -> RecoveryRecord {
        try await withSharedOperation {
            guard plan.location == location else { throw ModelFailure.changed }
            let context = try await recoveryContext()
            guard context.head == plan.head, context.branch == plan.branch,
                try SelectedIndexSnapshot.read(location: location) == plan.index
            else { throw ModelFailure.changed }
            try await RecoveryFileIO.verifyAll([plan.current], location: location)
            try await verifyRecoverySharedIndex(plan.sharedIndex)
            if let filterPath = plan.filterPath { try await selectedLinesValidateFilter(filterPath) }
            let store = try RecoveryStore(location: location)
            try await trimRecovery(store)
            var record = try await store.persist(
                operation: plan.operation, head: plan.head, branch: plan.branch,
                target: plan.sourceRevision, index: plan.index, files: [plan.current],
                sharedIndex: plan.sharedIndex)
            do {
                record.indexTree = try await recoveryIndexTree(
                    plan.index.bytes, shared: plan.sharedIndex, persist: true)
                try store.save(record)
                try await protectRecovery(record)
                let lease = try SelectedIndexLease(location: location, snapshot: plan.index)
                try await RecoveryFileIO.verifyAll([plan.current], location: location)
                if let filterPath = plan.filterPath { try await selectedLinesValidateFilter(filterPath) }
                let fresh = try await recoveryContext()
                guard fresh.head == plan.head, fresh.branch == plan.branch else { throw ModelFailure.changed }
                if plan.layer != .worktree, let object = plan.sourceObject,
                    let snapshot = plan.desired.snapshot
                {
                    let written = try await recoveryEngine.run(
                        ["hash-object", "-w", "--no-filters", "--", snapshot.url.path],
                        in: location.root, configuration: [(key: "core.fsync", value: "loose-object")]
                    ).text.removingLastNewline
                    guard written == object else { throw ModelFailure.changed }
                }
                if let candidate = plan.candidateIndex { try lease.write(candidate) }
                if plan.layer != .index {
                    try await RecoveryFileIO.installAll(
                        sources: [plan.desired], expected: [plan.current], location: location)
                }
                let final = try await recoveryContext()
                guard final.head == plan.head, final.branch == plan.branch else { throw ModelFailure.changed }
                try lease.verify()
                if plan.candidateIndex != nil { try lease.install() }
                if plan.layer != .index {
                    try await RecoveryFileIO.verifyContentsAll([plan.desired], location: location)
                }
                let observed = try SelectedIndexSnapshot.read(location: location)
                guard observed.bytes == (plan.candidateIndex ?? plan.index.bytes),
                    observed.mode == plan.index.mode
                else { throw ModelFailure.changed }
                record.state = .succeeded
                record.observedHead = plan.head
                try store.save(record)
                withExtendedLifetime(lease) {}
                return record
            } catch {
                record.state = .needsVerification
                record.details = Redaction.text(error.localizedDescription)
                let saved = record
                await Task.detached { try? store.save(saved) }.value
                throw RecoveryOutcomeUnknown(recordID: record.id, details: error.localizedDescription)
            }
        }
    }

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
            let (files, index, shared) = try await store.capture(record)
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
                if let shared { try write(shared.file.name, shared.data) }
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
            let index = try SelectedIndexSnapshot.read(location: location)
            let listing = try await recoveryEngine.run(
                ["ls-files", "--stage", "-v", "-z"], in: location.root,
                outputLimit: 32 * 1024 * 1024
            ).stdout
            let entries = try recoveryIndexEntries(listing, requireOrdinary: mode != .soft)
            let sharedIndex = try await captureRecoverySharedIndex(index)
            guard mode == .soft || sharedIndex == nil else {
                throw ModelFailure.unsupported(L10n.text("此索引使用拆分存储；请先使用 Soft Reset 保留暂存区。"))
            }
            // Read every indexed regular entry before status. This also fences
            // files that were clean in the preview and must never lose later edits.
            let indexedFiles =
                mode == .hard
                ? try await RecoveryFileIO.metadataAll(
                    location: location, paths: entries.filter { $0.value != "160000" }.keys.sorted()) : []
            guard let head = try await head() else {
                throw ModelFailure.unsupported(L10n.text("Reset 需要已有提交，并先完成当前 Git 操作。"))
            }
            let reader = RepositoryService(location: location, engine: recoveryEngine, queue: queue)
            let commit = try await reader.readCommit(target)
            try await verifyResetSource(sourceRef, target: commit.id)
            let changed = try await recoveryEngine.run(
                ["diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", head, commit.id, "--"],
                in: location.root, outputLimit: 32 * 1024 * 1024
            ).stdout
            var paths = Set(try recoveryPaths(changed))
            guard paths.count <= RecoveryBudget.files else { throw RecoveryBudget.exceeded }
            let currentSubmodules = Set(entries.filter { $0.value == "160000" }.map(\.key))
            var targetModes: [String: String] = [:]
            if mode == .hard {
                // Explicitly leave submodule working trees alone, regardless of
                // the user's submodule.recurse setting. Their gitlinks remain in the index backup.
                let tree = try await recoveryEngine.run(
                    ["ls-tree", "-r", "-z", commit.id], in: location.root,
                    outputLimit: 32 * 1024 * 1024
                ).stdout
                for row in tree.split(separator: 0) {
                    guard let tab = row.firstIndex(of: 9),
                        let text = String(data: row[..<tab], encoding: .utf8),
                        let path = String(data: row[row.index(after: tab)...], encoding: .utf8)
                    else { throw ModelFailure.changed }
                    targetModes[path] = String(text.prefix(6))
                }
            }
            let submodules = Set(targetModes.filter { $0.value == "160000" }.map(\.key)).union(
                currentSubmodules)
            let knownPaths = mode == .hard ? paths.subtracting(submodules).sorted() : []
            let byteLimit =
                RecoveryBudget.bytes - (index.bytes?.count ?? 0)
                - (sharedIndex?.data.count ?? 0)
            // All indexed versions were fixed before either read starts. Files
            // already affected by the fixed target can be captured while Git
            // scans status; any additional dirty paths share the remaining budget.
            async let readStatus = status()
            async let knownCaptures = RecoveryFileIO.captureAll(
                location: location, paths: knownPaths, limit: byteLimit)
            let state = try await readStatus
            guard state.head == head else { throw ModelFailure.changed }
            guard state.sequencer == .none, state.conflicts.isEmpty else {
                throw ModelFailure.unsupported(L10n.text("Reset 需要已有提交，并先完成当前 Git 操作。"))
            }
            for file in state.files where !file.untracked {
                paths.insert(file.path)
                if let old = file.oldPath { paths.insert(old) }
            }
            guard paths.count <= RecoveryBudget.files else { throw RecoveryBudget.exceeded }
            var captures = try await knownCaptures
            if mode == .hard {
                for path in paths {
                    if let current = entries[path], let target = targetModes[path],
                        (current == "160000") != (target == "160000")
                    {
                        throw ModelFailure.unsupported(
                            L10n.text("子模块与普通文件的替换需先单独处理；Soft 或 Mixed Reset 会保留工作文件。"))
                    }
                }
                let filePaths = paths.subtracting(submodules)
                try await StashWorktreeGuard.validate(
                    paths: paths, tracked: Set(entries.keys), location: location,
                    allowedDirectories: currentSubmodules)
                let remaining = byteLimit - captures.reduce(0) { $0 + $1.file.bytes }
                let additional = try await captureRecoveryFiles(
                    filePaths.subtracting(knownPaths).sorted(), limit: remaining,
                    storageOffset: captures.count)
                captures = (captures + additional).sorted { $0.file.path < $1.file.path }
            }
            let refs = try await recoveryEngine.run(
                ["for-each-ref", "--contains=" + head, "--format=%(refname)", "refs/remotes"],
                in: location.root, outputLimit: 64 * 1024
            ).text.split(separator: "\n").map(String.init)
            try await verifyHead(head)
            let fresh = try await recoveryContext()
            guard fresh.head == head, fresh.branch == state.branch,
                try SelectedIndexSnapshot.read(location: location) == index
            else { throw ModelFailure.changed }
            try await RecoveryFileIO.verifyMetadataAll(indexedFiles, location: location)
            try await RecoveryFileIO.verifyAll(captures, location: location)
            try await verifyRecoverySharedIndex(sharedIndex)
            return ResetPlan(
                id: UUID(), mode: mode, target: commit, head: head, branch: state.branch,
                files: paths.sorted(), publishedTrackingRefs: refs, location: location,
                index: index, captures: captures, indexedFiles: indexedFiles, sharedIndex: sharedIndex,
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
                index: plan.index, files: plan.captures, sharedIndex: plan.sharedIndex)
            do {
                record.indexTree = try await recoveryIndexTree(
                    plan.index.bytes, shared: plan.sharedIndex, persist: true)
                try store.save(record)
                try await protectRecovery(record)
                try await validateReset(plan)
                _ = try await recoveryEngine.run(
                    ["reset", "--" + plan.mode.rawValue, "--no-recurse-submodules", plan.target.id],
                    in: location.root, timeout: 120)
                let observed = try await verifyResetResult(plan)
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

    private func verifyResetResult(_ plan: ResetPlan) async throws -> (head: String?, branch: String) {
        let snapshot = try SelectedIndexSnapshot.read(location: location)
        if plan.mode == .soft {
            let observed = try await recoveryContext()
            guard snapshot == plan.index, observed.head == plan.target.id, observed.branch == plan.branch,
                try SelectedIndexSnapshot.read(location: location) == snapshot
            else { throw ModelFailure.changed }
            return observed
        }
        // Independent Git reads must agree on the same raw index version. A
        // concurrent staging edit could otherwise make both comparisons look clean.
        var configured = recoveryEngine
        configured.environment["GIT_OPTIONAL_LOCKS"] = "0"
        let readEngine = configured
        async let context = recoveryContext()
        async let compared = readEngine.run(
            [
                "diff-index", "--cached", "--quiet", "--no-ext-diff", "--no-renames",
                "--ignore-submodules=none", "--ita-visible-in-index", plan.target.id, "--",
            ],
            in: location.root, accepted: [0, 1], outputLimit: 64 * 1024)
        async let working =
            plan.mode == .hard
            ? verifyResetWorkingTree(snapshot, engine: readEngine) : nil
        let (observed, indexResult, workResult) = try await (context, compared, working)
        guard observed.head == plan.target.id, observed.branch == plan.branch, indexResult.exitCode == 0,
            workResult == nil || workResult == true,
            try SelectedIndexSnapshot.read(location: location) == snapshot
        else { throw ModelFailure.changed }
        let final = try await recoveryContext()
        guard final.head == observed.head, final.branch == observed.branch else { throw ModelFailure.changed }
        return final
    }

    private func verifyResetWorkingTree(_ index: SelectedIndexSnapshot, engine: GitEngine) async throws
        -> Bool
    {
        let listing = try await engine.run(
            ["ls-files", "--stage", "-v", "-z"], in: location.root, outputLimit: 32 * 1024 * 1024
        ).stdout
        let entries = try recoveryIndexEntries(listing, requireOrdinary: false)
        let paths = entries.filter { $0.value != "160000" }.map(\.key).sorted()
        guard paths.count <= RecoveryBudget.metadataFiles,
            try SelectedIndexSnapshot.read(location: location) == index
        else { throw ModelFailure.changed }
        // A successful earlier shard must still describe the same files when
        // all other shards finish. Index bytes fence every Git comparison too.
        let versions = try await RecoveryFileIO.metadataAll(location: location, paths: paths)
        let arguments = ["diff", "--exit-code", "--no-ext-diff", "--ignore-submodules=all", "--"]
        let clean: Bool
        if paths.count >= 128, paths.reduce(0, { $0 + $1.utf8.count + 1 }) <= 128 * 1024 {
            let width = (paths.count + 1) / 2
            clean = try await withThrowingTaskGroup(of: Bool.self) { group in
                for offset in stride(from: 0, to: paths.count, by: width) {
                    let selected = Array(paths[offset..<min(paths.count, offset + width)])
                    group.addTask {
                        try await engine.run(
                            arguments + selected, in: location.root, accepted: [0, 1],
                            outputLimit: 64 * 1024
                        ).exitCode == 0
                    }
                }
                var result = true
                for try await value in group { result = result && value }
                return result
            }
        } else {
            clean =
                try await engine.run(
                    arguments, in: location.root, accepted: [0, 1], outputLimit: 64 * 1024
                ).exitCode == 0
        }
        try await RecoveryFileIO.verifyMetadataAll(versions, location: location)
        guard try SelectedIndexSnapshot.read(location: location) == index else { throw ModelFailure.changed }
        return clean
    }

    private func validateReset(_ plan: ResetPlan) async throws {
        try await verifyHead(plan.head)
        try await verifyResetSource(plan.sourceRef, target: plan.target.id)
        let state = try await recoveryContext()
        guard state.head == plan.head, state.branch == plan.branch,
            try SelectedIndexSnapshot.read(location: location) == plan.index
        else { throw ModelFailure.changed }
        if plan.mode == .hard {
            try await StashWorktreeGuard.validate(
                paths: Set(plan.files), tracked: plan.trackedPaths,
                location: location, allowedDirectories: plan.submoduleDirectories)
        }
        try await RecoveryFileIO.verifyMetadataAll(plan.indexedFiles, location: location)
        try await RecoveryFileIO.verifyAll(plan.captures, location: location)
        try await verifyRecoverySharedIndex(plan.sharedIndex)
        try await verifyHead(plan.head)
    }

    @concurrent public func prepareRecoveryRestore(_ record: RecoveryRecord, layer: RecoveryLayer = .worktree)
        async throws -> RecoveryRestorePlan
    {
        try await queue.perform {
            let snapshot = try SelectedIndexSnapshot.read(location: location)
            let store = try RecoveryStore(location: location)
            // These reads do not write the repository. Their results become a
            // plan only after one final identity/index/file/context fence.
            async let context = recoveryContext()
            async let sharedIndex = captureRecoverySharedIndex(snapshot)
            async let unmerged = recoveryEngine.run(
                ["ls-files", "--unmerged", "-z"], in: location.root,
                outputLimit: 32 * 1024 * 1024)
            async let indexBackup: (Data?, RecoverySharedIndexSnapshot?) =
                layer == .worktree
                ? (nil, nil) : try await store.captureIndex(record)
            async let saved = store.capture(
                record, includeFiles: layer != .index, includeIndex: false)
            let currentSharedIndex = try await sharedIndex
            let unmergedResult = try await unmerged
            guard unmergedResult.stdout.isEmpty else {
                throw ModelFailure.unsupported(L10n.text("请先完成当前 Git 操作，再恢复备份。"))
            }
            async let captured = captureRecoveryFiles(
                layer == .index ? [] : record.files.map(\.path),
                limit: RecoveryBudget.bytes - (snapshot.bytes?.count ?? 0)
                    - (currentSharedIndex?.data.count ?? 0))
            let (index, sourceSharedIndex) = try await indexBackup
            async let indexTree =
                layer == .worktree
                ? nil
                : recoveryIndexTree(
                    index, shared: sourceSharedIndex, persist: false, formatFrom: record.indexTree)
            let (state, (source, _, _), current, tree) = try await (context, saved, captured, indexTree)
            if layer != .worktree {
                guard record.indexTree == nil || record.indexTree == tree else { throw ModelFailure.changed }
            }
            async let finalContext = recoveryContext()
            async let filesVerified: Void = RecoveryFileIO.verifyAll(current, location: location)
            async let sharedVerified: Void = verifyRecoverySharedIndex(currentSharedIndex)
            let (final, _, _) = try await (finalContext, filesVerified, sharedVerified)
            guard final.head == state.head, final.branch == state.branch,
                try SelectedIndexSnapshot.read(location: location) == snapshot
            else { throw ModelFailure.changed }
            return RecoveryRestorePlan(
                id: UUID(), record: record, layer: layer,
                currentHead: state.head, currentBranch: state.branch,
                location: location, index: snapshot, currentFiles: current,
                sourceFiles: source, sourceIndex: index, sourceSharedIndex: sourceSharedIndex,
                currentSharedIndex: currentSharedIndex)
        }
    }

    public func executeRecoveryRestore(_ plan: RecoveryRestorePlan) async throws -> RecoveryRecord {
        try await withSharedOperation {
            guard plan.location == location else { throw ModelFailure.changed }
            try await verifyHead(plan.currentHead)
            let state = try await recoveryContext()
            guard state.head == plan.currentHead, state.branch == plan.currentBranch,
                try SelectedIndexSnapshot.read(location: location) == plan.index
            else { throw ModelFailure.changed }
            try await RecoveryFileIO.verifyAll(plan.currentFiles, location: location)
            try await verifyRecoverySharedIndex(plan.currentSharedIndex)
            let store = try RecoveryStore(location: location)
            guard try store.record(plan.record.id) == plan.record else { throw ModelFailure.changed }
            try await trimRecovery(store, preserving: plan.record.id)
            var backup = try await store.persist(
                operation: "restore-backup", head: plan.currentHead, branch: plan.currentBranch,
                target: nil, index: plan.index, files: plan.currentFiles, sharedIndex: plan.currentSharedIndex
            )
            do {
                backup.indexTree = try await recoveryIndexTree(
                    plan.index.bytes, shared: plan.currentSharedIndex, persist: true)
                try store.save(backup)
                try await protectRecovery(backup)
                let lease = try SelectedIndexLease(location: location, snapshot: plan.index)
                try await verifyHead(plan.currentHead)
                if plan.layer != .worktree {
                    if let shared = plan.sourceSharedIndex { try lease.installShared(shared) }
                    if let bytes = plan.sourceIndex {
                        try lease.write(bytes, mode: mode_t(plan.record.indexMode))
                    }
                }
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
                    let restoredIndex = try SelectedIndexSnapshot.read(location: location)
                    guard restoredIndex.bytes == plan.sourceIndex,
                        plan.sourceIndex == nil || restoredIndex.mode == mode_t(plan.record.indexMode)
                    else {
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

    /// These checks need repository identity and Git state, not a repeat content
    /// scan. Raw index and all affected/indexed entry versions are fenced separately.
    func recoveryContext() async throws -> (head: String?, branch: String) {
        async let head = head()
        async let symbolic = recoveryEngine.run(
            ["symbolic-ref", "--quiet", "HEAD"], in: location.root, accepted: [0, 1])
        let (current, reference) = try await (head, symbolic)
        let name = reference.text.removingLastNewline
        guard reference.exitCode == 1 || name.hasPrefix("refs/heads/") else { throw ModelFailure.changed }
        try await SnapshotIO.run { cancellation in
            for path in [
                "rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer",
            ] {
                try cancellation.check()
                guard
                    try RepositoryNodeIdentity.readIfPresent(location.gitDirectory.appending(path: path))
                        == nil
                else {
                    throw ModelFailure.unsupported(L10n.text("请先完成当前 Git 操作，再恢复备份。"))
                }
            }
            try location.validateIdentity()
        }
        return (current, reference.exitCode == 1 ? "(detached)" : String(name.dropFirst("refs/heads/".count)))
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

    private func recoveryIndexRef(_ record: RecoveryRecord) -> String {
        "refs/wegit/recovery-index/" + record.id.uuidString.lowercased()
    }

    func pendingRecoveryIndexRef(_ record: RecoveryRecord) -> String {
        "refs/wegit/recovery-target/" + record.id.uuidString.lowercased()
    }

    func protectRecovery(_ record: RecoveryRecord) async throws {
        var commands = ["start"]
        if let head = record.head {
            try await verifyCommit(head)
            commands.append("create " + recoveryRef(record) + " " + head)
        }
        if let tree = record.indexTree {
            commands.append("create " + recoveryIndexRef(record) + " " + tree)
        }
        if let tree = record.pendingIndexTree {
            commands.append("create " + pendingRecoveryIndexRef(record) + " " + tree)
        }
        if commands.count > 1 {
            commands += ["prepare", "commit"]
            _ = try await recoveryEngine.run(
                ["update-ref", "--no-deref", "--stdin"], in: location.root,
                input: Data((commands.joined(separator: "\n") + "\n").utf8))
        }
    }

    private func removeRecovery(_ record: RecoveryRecord, store: RecoveryStore) async throws {
        guard try store.record(record.id) == record else { throw ModelFailure.changed }
        try await SnapshotIO.run { _ in try store.validateRemoval(record) }
        var commands = ["start"]
        for (ref, object) in [
            (recoveryRef(record), record.head), (recoveryIndexRef(record), record.indexTree),
            (pendingRecoveryIndexRef(record), record.pendingIndexTree),
        ] {
            guard let object else { continue }
            let symbolic = try await recoveryEngine.run(
                ["symbolic-ref", "-q", ref], in: location.root, accepted: [0, 1])
            guard symbolic.exitCode == 1 else { throw ModelFailure.changed }
            let value = try await recoveryEngine.run(
                ["rev-parse", "--verify", ref], in: location.root, accepted: [0, 128])
            if value.exitCode == 0 {
                guard value.text.removingLastNewline == object else { throw ModelFailure.changed }
                commands.append("delete " + ref + " " + object)
            }
        }
        if commands.count > 1 {
            commands += ["prepare", "commit"]
            _ = try await recoveryEngine.run(
                ["update-ref", "--no-deref", "--stdin"], in: location.root,
                input: Data((commands.joined(separator: "\n") + "\n").utf8))
        }
        try await SnapshotIO.run { _ in try store.remove(record) }
    }

    func trimRecovery(_ store: RecoveryStore, preserving: UUID? = nil) async throws {
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

    func captureRecoveryFiles(
        _ paths: [String], limit: Int = RecoveryBudget.bytes, storageOffset: Int = 0
    ) async throws
        -> [RecoveryFileCapture]
    {
        try await RecoveryFileIO.captureAll(
            location: location, paths: paths, limit: limit, storageOffset: storageOffset)
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
