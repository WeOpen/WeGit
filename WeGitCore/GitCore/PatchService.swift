import Darwin
import Foundation

extension RepositoryService {
    @concurrent public func exportPatch(layer: DiffLayer, paths: [String]? = nil) async throws -> Data {
        guard layer == .staged || layer == .unstaged || layer == .untracked else {
            throw ModelFailure.invalidPath
        }
        if let paths {
            guard !paths.isEmpty, paths.count <= PatchReadBudget.files else { throw RecoveryBudget.exceeded }
            for path in paths { try RecoveryFileIO.validate(path) }
        }
        if layer == .untracked {
            guard let paths else { throw ModelFailure.invalidPath }
            let files = try await RecoveryFileIO.captureAll(
                location: location, paths: paths, limit: PatchReadBudget.bytes)
            var patch = Data()
            for path in paths {
                let result = try await recoveryEngine.run(
                    [
                        "diff", "--no-index", "--binary", "--full-index", "--no-ext-diff", "--no-textconv",
                        "--no-color", "--", "/dev/null", path,
                    ], in: location.root, accepted: [0, 1],
                    outputLimit: PatchReadBudget.bytes)
                guard result.stdout.count <= PatchReadBudget.bytes - patch.count else {
                    throw RecoveryBudget.exceeded
                }
                patch.append(result.stdout)
            }
            try await RecoveryFileIO.verifyAll(files, location: location)
            return patch
        }
        let before = try SelectedIndexSnapshot.read(location: location)
        let head = try await self.head()
        var flags = ["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "--no-color"]
        if layer == .staged { flags.append("--cached") }
        let result = try await recoveryEngine.run(
            flags + ["--"] + (paths ?? []),
            in: location.root, outputLimit: PatchReadBudget.bytes)
        guard try SelectedIndexSnapshot.read(location: location) == before, try await self.head() == head
        else {
            throw ModelFailure.changed
        }
        return result.stdout
    }

    @concurrent public func exportPatch(comparison: CommitComparison, paths: [String]? = nil) async throws
        -> Data
    {
        guard comparison.location == location else { throw ModelFailure.changed }
        if let paths {
            guard !paths.isEmpty, paths.count <= PatchReadBudget.files,
                paths.allSatisfy({ path in comparison.files.contains { $0.path == path || $0.oldPath == path }
                })
            else { throw ModelFailure.invalidPath }
            for path in paths { try RecoveryFileIO.validate(path) }
        }
        let base = comparison.parent == nil ? ["diff-tree", "--root", "--no-commit-id", "-r"] : ["diff"]
        let revisions = [comparison.parent, comparison.commit.id].compactMap { $0 }
        let output = try await recoveryEngine.run(
            base + [
                "--binary", "--full-index", "--find-renames", "--no-ext-diff", "--no-textconv", "--no-color",
            ]
                + revisions + ["--"] + (paths ?? []), in: location.root, outputLimit: PatchReadBudget.bytes)
        try location.validateIdentity()
        return output.stdout
    }

    @concurrent public func preparePatch(_ patch: Data, layer: RecoveryLayer = .worktree) async throws
        -> PatchPlan
    {
        guard !patch.isEmpty, patch.count <= PatchReadBudget.bytes else { throw RecoveryBudget.exceeded }
        let statistics = try await recoveryEngine.run(
            ["apply", "--numstat", "-z", "--binary", "-"], in: location.root, input: patch,
            outputLimit: 1024 * 1024)
        let files = try parsePatchFiles(statistics.stdout, patch: patch)
        let paths = Array(Set(files.flatMap { [$0.path, $0.oldPath].compactMap { $0 } })).sorted()
        guard !paths.isEmpty, paths.count <= PatchReadBudget.files else { throw RecoveryBudget.exceeded }
        return try await queue.perform {
            let context = try await recoveryContext()
            let index = try SelectedIndexSnapshot.read(location: location)
            let shared = try await captureRecoverySharedIndex(index)
            let originals = try await RecoveryFileIO.captureAll(
                location: location, paths: paths, limit: PatchReadBudget.bytes)
            try await validatePatchFilters(paths)
            let global = try await ignoreGlobalFile(key: "core.attributesfile")
            var configuration: [String: String?] = [:]
            for key in ["core.autocrlf", "core.eol", "core.ignorecase"] {
                configuration.updateValue(try await ignoreConfiguration(key), forKey: key)
            }
            var attributePaths: Set<String> = [".gitattributes"]
            for path in paths {
                let parts = path.split(separator: "/")
                for count in 1..<parts.count {
                    attributePaths.insert(parts.prefix(count).joined(separator: "/") + "/.gitattributes")
                    guard attributePaths.count <= 4096 else { throw RecoveryBudget.exceeded }
                }
            }
            let auxPaths = attributePaths.subtracting(paths).sorted()
            let auxiliary = try await RecoveryFileIO.captureAll(
                location: location, paths: auxPaths, limit: 16 * 1024 * 1024)
            let storage = try await SnapshotIO.run { _ in try SnapshotDirectory() }
            defer { withExtendedLifetime(storage) {} }
            let work = storage.url.appending(path: "work")
            let format = try await recoveryEngine.run(
                ["rev-parse", "--show-object-format"], in: location.root
            ).text.removingLastNewline
            guard format == "sha1" || format == "sha256" else { throw ModelFailure.changed }
            var isolated = recoveryEngine
            isolated.environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            isolated.environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
            _ = try await isolated.run(
                ["init", "--template=", "--object-format=" + format, work.path], in: storage.url)
            let privateLocation = try await RepositoryService.discover(work, engine: isolated)
            let privateEmpty = try await RecoveryFileIO.captureAll(
                location: privateLocation, paths: paths, limit: PatchReadBudget.bytes)
            let privateAuxiliary = try await RecoveryFileIO.captureAll(
                location: privateLocation, paths: auxPaths, limit: 16 * 1024 * 1024)
            try await RecoveryFileIO.installAll(
                sources: originals + auxiliary,
                expected: privateEmpty + privateAuxiliary, location: privateLocation)
            let privateIndex = privateLocation.gitDirectory.appending(path: "index")
            if let bytes = index.bytes { try bytes.write(to: privateIndex) }
            if let shared {
                try shared.data.write(to: privateLocation.gitDirectory.appending(path: shared.file.name))
            }
            isolated.environment["GIT_INDEX_FILE"] = privateIndex.path
            isolated.environment["GIT_OBJECT_DIRECTORY"] =
                privateLocation.commonDirectory.appending(path: "objects").path
            isolated.environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = singleCommitAlternatePath(
                location.commonDirectory.appending(path: "objects").path)
            if index.bytes == nil { _ = try await isolated.run(["read-tree", "--empty"], in: work) }
            _ = try await isolated.run(["update-index", "--no-split-index"], in: work)
            let originalEntries = try await patchIndexEntries(recoveryEngine, in: location.root)
            for path in paths {
                let selected = originalEntries.filter { $0.key.path == Data(path.utf8) }
                guard
                    selected.allSatisfy({
                        $0.key.stage == "0" && $0.value.flag == "H"
                            && ["100644", "100755", "120000"].contains($0.value.mode)
                    })
                else {
                    throw ModelFailure.unsupported(L10n.text("补丁目标包含特殊索引标记或冲突阶段，请先处理。"))
                }
            }
            let globalFile = storage.url.appending(path: "attributes")
            try (global.bytes ?? Data()).write(to: globalFile)
            var settings = [
                (key: "core.attributesfile", value: globalFile.path),
                (key: "core.splitIndex", value: "false"),
            ]
            for (key, value) in configuration { if let value { settings.append((key: key, value: value)) } }
            var flags = ["apply", "--binary", "--whitespace=nowarn"]
            if layer == .index { flags.append("--cached") }
            if layer == .both { flags.append("--index") }
            if layer == .both {
                let refreshPaths = paths.filter { path in
                    originalEntries.keys.contains { $0.path == Data(path.utf8) && $0.stage == "0" }
                }
                if !refreshPaths.isEmpty {
                    _ = try await isolated.run(
                        ["update-index", "--refresh", "--"] + refreshPaths, in: work, accepted: [0, 1],
                        configuration: settings)
                }
            }
            _ = try await isolated.run(
                flags + ["--check", "-"], in: work, input: patch, configuration: settings)
            _ = try await isolated.run(flags + ["-"], in: work, input: patch, configuration: settings)
            let desired =
                layer == .index
                ? []
                : try await RecoveryFileIO.captureAll(
                    location: privateLocation, paths: paths, limit: PatchReadBudget.bytes)
            let candidate: Data?
            let pack: Data?
            var objects: [String] = []
            if layer != .worktree {
                let after = try await patchIndexEntries(isolated, in: work)
                let affected = Set(paths.map { Data($0.utf8) })
                guard
                    after.filter({ affected.contains($0.key.path) }).allSatisfy({
                        $0.key.stage == "0" && $0.value.flag == "H"
                            && ["100644", "100755", "120000"].contains($0.value.mode)
                    })
                else { throw ModelFailure.unsupported(L10n.text("此补丁包含无法安全安装的索引对象。")) }
                guard
                    originalEntries.filter({ !affected.contains($0.key.path) })
                        == after.filter({ !affected.contains($0.key.path) })
                else { throw ModelFailure.changed }
                candidate = try Data(contentsOf: privateIndex)
                guard candidate!.count <= 32 * 1024 * 1024 else { throw RecoveryBudget.exceeded }
                objects = Array(Set(after.filter { affected.contains($0.key.path) }.map { $0.value.object }))
                    .sorted()
                if objects.isEmpty {
                    pack = nil
                } else {
                    pack = try await isolated.run(
                        ["pack-objects", "--stdout", "--no-reuse-delta", "--no-reuse-object"],
                        in: work, input: Data((objects.joined(separator: "\n") + "\n").utf8),
                        outputLimit: PatchReadBudget.bytes
                    ).stdout
                }
            } else {
                candidate = nil
                pack = nil
            }
            let plan = PatchPlan(
                id: UUID(), layer: layer, files: files, patchBytes: patch.count, location: location,
                head: context.head, branch: context.branch, index: index, sharedIndex: shared,
                originals: originals, desired: desired, auxiliary: auxiliary, configuration: configuration,
                globalAttributes: global, candidateIndex: candidate, objectPack: pack, newObjects: objects)
            try await validatePatchPlan(plan)
            return plan
        }
    }

    public func executePatch(_ plan: PatchPlan) async throws -> RecoveryRecord {
        try await withSharedOperation {
            try await validatePatchPlan(plan)
            let store = try RecoveryStore(location: location)
            try await trimRecovery(store)
            var record = try await store.persist(
                operation: "apply-patch", head: plan.head, branch: plan.branch, target: nil,
                index: plan.index, files: plan.originals, sharedIndex: plan.sharedIndex)
            do {
                record.indexTree = try await recoveryIndexTree(
                    plan.index.bytes, shared: plan.sharedIndex, persist: true)
                try store.save(record)
                try await protectRecovery(record)
                let lease = try SelectedIndexLease(location: location, snapshot: plan.index)
                try await validatePatchPlan(plan)
                if let pack = plan.objectPack {
                    guard record.totalBytes + pack.count <= RecoveryBudget.bytes,
                        try store.records().reduce(
                            record.totalBytes + pack.count, { $0 + ($1.id == record.id ? 0 : $1.totalBytes) })
                            <= RecoveryBudget.retainedBytes
                    else { throw RecoveryBudget.exceeded }
                    _ = try await recoveryEngine.run(
                        ["index-pack", "--stdin"], in: location.root, input: pack,
                        configuration: [(key: "core.fsync", value: "pack,pack-metadata")])
                    record.pendingIndexTree = try await recoveryIndexTree(
                        plan.candidateIndex, shared: nil, persist: true)
                    record.pendingObjectBytes = pack.count
                    guard let tree = record.pendingIndexTree else { throw ModelFailure.changed }
                    try store.save(record)
                    _ = try await recoveryEngine.run(
                        ["update-ref", "--no-deref", "--stdin"], in: location.root,
                        input: Data(("create " + pendingRecoveryIndexRef(record) + " " + tree + "\n").utf8))
                    let checked = try await recoveryEngine.run(
                        ["cat-file", "--batch-check=%(objectname) %(objecttype)"], in: location.root,
                        input: Data((plan.newObjects.joined(separator: "\n") + "\n").utf8))
                    let lines = checked.text.split(separator: "\n").map(String.init)
                    guard lines == plan.newObjects.map({ $0 + " blob" }) else { throw ModelFailure.changed }
                }
                try await validatePatchPlan(plan)
                if let candidate = plan.candidateIndex { try lease.write(candidate) }
                if plan.layer != .index {
                    let selected = zip(plan.desired, plan.originals).filter {
                        $0.0.file.kind != $0.1.file.kind || $0.0.file.sha256 != $0.1.file.sha256
                            || $0.0.file.mode != $0.1.file.mode
                    }
                    try await RecoveryFileIO.installAll(
                        sources: selected.map { $0.0 }, expected: selected.map { $0.1 }, location: location)
                }
                let context = try await recoveryContext()
                guard context.head == plan.head, context.branch == plan.branch else {
                    throw ModelFailure.changed
                }
                try lease.verify()
                if plan.candidateIndex != nil { try lease.install() }
                if plan.layer != .index {
                    try await RecoveryFileIO.verifyContentsAll(plan.desired, location: location)
                }
                let observed = try SelectedIndexSnapshot.read(location: location)
                guard observed.bytes == (plan.candidateIndex ?? plan.index.bytes),
                    observed.mode == plan.index.mode
                else {
                    throw ModelFailure.changed
                }
                if let tree = record.pendingIndexTree {
                    _ = try await recoveryEngine.run(
                        ["update-ref", "--no-deref", "-d", pendingRecoveryIndexRef(record), tree],
                        in: location.root)
                    record.pendingIndexTree = nil
                    record.pendingObjectBytes = nil
                }
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

    private func validatePatchPlan(_ plan: PatchPlan) async throws {
        guard plan.location == location else { throw ModelFailure.changed }
        let context = try await recoveryContext()
        guard context.head == plan.head, context.branch == plan.branch,
            try SelectedIndexSnapshot.read(location: location) == plan.index,
            try await ignoreGlobalFile(key: "core.attributesfile") == plan.globalAttributes
        else { throw ModelFailure.changed }
        for (key, value) in plan.configuration {
            guard try await ignoreConfiguration(key) == value else { throw ModelFailure.changed }
        }
        try await verifyRecoverySharedIndex(plan.sharedIndex)
        try await RecoveryFileIO.verifyAll(plan.originals + plan.auxiliary, location: location)
        try await validatePatchFilters(plan.originals.map { $0.file.path })
    }

    private func validatePatchFilters(_ paths: [String]) async throws {
        var input = Data()
        for path in paths {
            input.append(Data(path.utf8))
            input.append(0)
        }
        let output = try await recoveryEngine.run(
            ["check-attr", "-z", "--stdin", "filter"], in: location.root, input: input,
            outputLimit: 1024 * 1024)
        let fields = output.stdout.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.last?.isEmpty == true, fields.count == paths.count * 3 + 1 else {
            throw ModelFailure.changed
        }
        for index in paths.indices {
            guard fields[index * 3] == Data(paths[index].utf8), fields[index * 3 + 1] == Data("filter".utf8),
                [Data("unspecified".utf8), Data("unset".utf8)].contains(Data(fields[index * 3 + 2]))
            else { throw ModelFailure.unsupported(L10n.text("补丁目标配置了内容过滤器，请使用明确的文件级外部流程。")) }
        }
    }

    private struct PatchIndexKey: Hashable {
        let path: Data
        let stage: String
    }
    private struct PatchIndexEntry: Equatable {
        let flag: String
        let mode: String
        let object: String
    }
    private func patchIndexEntries(_ engine: GitEngine, in directory: URL) async throws -> [PatchIndexKey:
        PatchIndexEntry]
    {
        let output = try await engine.run(
            ["ls-files", "--stage", "-v", "-z"], in: directory, outputLimit: 32 * 1024 * 1024)
        guard output.stdout.isEmpty || output.stdout.last == 0 else { throw ModelFailure.changed }
        var result: [PatchIndexKey: PatchIndexEntry] = [:]
        for row in output.stdout.split(separator: 0) {
            guard let tab = row.firstIndex(of: 9) else { throw ModelFailure.changed }
            let fields = String(decoding: row[..<tab], as: UTF8.self).split(separator: " ").map(String.init)
            guard fields.count == 4, GitObjectID.valid(fields[2]) else { throw ModelFailure.changed }
            let key = PatchIndexKey(path: Data(row[row.index(after: tab)...]), stage: fields[3])
            guard result[key] == nil else { throw ModelFailure.changed }
            result[key] = PatchIndexEntry(flag: fields[0], mode: fields[1], object: fields[2])
        }
        return result
    }

    private func parsePatchFiles(_ data: Data, patch: Data) throws -> [PatchFileChange] {
        guard !data.isEmpty, data.last == 0 else { throw ModelFailure.changed }
        let renameSources = try patchRenameSources(patch)
        let rows = data.split(separator: 0, omittingEmptySubsequences: false)
        var index = 0
        var result: [PatchFileChange] = []
        func path(_ value: Data.SubSequence) throws -> String {
            guard let string = String(data: value, encoding: .utf8) else { throw ModelFailure.invalidPath }
            try RecoveryFileIO.validate(string)
            return string
        }
        while index < rows.count - 1 {
            let fields = rows[index].split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw ModelFailure.changed }
            let binary = fields[0] == Data("-".utf8) && fields[1] == Data("-".utf8)
            let additions = Int(String(decoding: fields[0], as: UTF8.self))
            let deletions = Int(String(decoding: fields[1], as: UTF8.self))
            guard binary || additions != nil && deletions != nil && additions! >= 0 && deletions! >= 0 else {
                throw ModelFailure.changed
            }
            index += 1
            let old: String?
            let name: String
            if fields[2].isEmpty {
                guard index + 1 < rows.count - 1 else { throw ModelFailure.changed }
                old = try path(rows[index])
                name = try path(rows[index + 1])
                index += 2
            } else {
                old = nil
                name = try path(fields[2])
            }
            result.append(
                PatchFileChange(
                    path: name, oldPath: old ?? renameSources[name], additions: additions,
                    deletions: deletions, binary: binary))
            guard result.count <= PatchReadBudget.files else { throw RecoveryBudget.exceeded }
        }
        guard Set(result.map(\.path)).count == result.count else { throw ModelFailure.changed }
        guard Set(renameSources.keys).isSubset(of: Set(result.map(\.path))) else {
            throw ModelFailure.changed
        }
        return result
    }

    /// apply --numstat -z reports only the destination for a rename.
    private func patchRenameSources(_ patch: Data) throws -> [String: String] {
        var source: String?
        var target: String?
        var mapping: [String: String] = [:]
        func finish() throws {
            guard source != nil || target != nil else { return }
            guard let source, let target, mapping[target] == nil else { throw ModelFailure.changed }
            try RecoveryFileIO.validate(source)
            try RecoveryFileIO.validate(target)
            mapping[target] = source
        }
        for row in patch.split(separator: 10, omittingEmptySubsequences: false) {
            if row.starts(with: Data("diff --git ".utf8)) {
                try finish()
                source = nil
                target = nil
            } else if row.starts(with: Data("rename from ".utf8)) || row.starts(with: Data("copy from ".utf8))
            {
                let prefix = row.starts(with: Data("rename from ".utf8)) ? 12 : 10
                guard source == nil else { throw ModelFailure.changed }
                source = try BlameParser.unquotePath(Data(row.dropFirst(prefix)))
            } else if row.starts(with: Data("rename to ".utf8)) || row.starts(with: Data("copy to ".utf8)) {
                let prefix = row.starts(with: Data("rename to ".utf8)) ? 10 : 8
                guard target == nil else { throw ModelFailure.changed }
                target = try BlameParser.unquotePath(Data(row.dropFirst(prefix)))
            }
        }
        try finish()
        return mapping
    }
}
