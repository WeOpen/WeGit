import Darwin
import Foundation

extension RepositoryService {
    @concurrent public func prepareIgnoreRule(
        path: String, kind: IgnoreRuleKind = .file, scope: IgnoreRuleScope = .repository
    ) async throws -> IgnoreRulePlan {
        try RecoveryFileIO.validate(path)
        guard !path.contains("\n"), !path.contains("\r"), path.utf8.count <= 8192 else {
            throw ModelFailure.unsupported(L10n.text("此路径无法安全写成单行忽略规则。"))
        }
        let status = try await self.status()
        guard status.files.contains(where: { $0.path == path && $0.untracked }) else {
            throw ModelFailure.changed
        }
        let pattern = try ignorePattern(path: path, kind: kind)
        let index = try SelectedIndexSnapshot.read(location: location)
        let local = try await CommonExcludesFile.read(location)
        let global = try await ignoreGlobalFile()
        let ignoreCase = try await ignoreConfiguration("core.ignorecase")
        let root = try await RecoveryFileIO.capture(location: location, path: ".gitignore", name: "blob-0")
        let rootData = try await ignoreCaptureData(root)
        let before = scope == .repository ? rootData : local.bytes
        let after = try appendIgnoreRule(pattern, to: before)
        let (matches, captures) = try await previewIgnoreRule(
            pattern: pattern, scope: scope, root: root, rootData: rootData,
            localData: local.bytes, candidate: after, global: global, ignoreCase: ignoreCase)
        let sources = IgnoreRuleSources(
            head: status.head, index: index, captures: captures, local: local, global: global,
            ignoreCase: ignoreCase)
        try await validateIgnoreSources(sources)
        let filePlan: FileModificationPlan?
        if scope == .repository {
            let desired = try await RecoveryFileIO.replacement(
                path: ".gitignore", data: after, mode: root.file.kind == .absent ? 0o644 : root.file.mode)
            filePlan = try await prepareFileModification(
                path: ".gitignore", desired: desired, operation: "ignore-rule", layer: .worktree)
            guard filePlan?.index == index, filePlan?.head == status.head else { throw ModelFailure.changed }
            try await RecoveryFileIO.verifyAll([root], location: location)
        } else {
            filePlan = nil
        }
        return IgnoreRulePlan(
            id: UUID(), path: path, pattern: pattern, kind: kind, scope: scope, matchedPaths: matches,
            location: location, sources: sources, filePlan: filePlan, before: before, after: after)
    }

    public func executeIgnoreRule(_ plan: IgnoreRulePlan) async throws -> IgnoreRuleOutcome {
        guard plan.location == location else { throw ModelFailure.changed }
        if let filePlan = plan.filePlan {
            try await validateIgnoreSources(plan.sources)
            var record = try await executeFileModification(filePlan)
            do {
                try await validateIgnoreSources(plan.sources, changed: .repository)
                return IgnoreRuleOutcome(plan: plan, recovery: record, localAfter: nil)
            } catch {
                record.state = .needsVerification
                record.details = Redaction.text(error.localizedDescription)
                try? RecoveryStore(location: location).save(record)
                throw RecoveryOutcomeUnknown(recordID: record.id, details: error.localizedDescription)
            }
        }
        return try await withSharedOperation {
            try await validateIgnoreSources(plan.sources)
            let after = try await CommonExcludesFile.replace(
                plan.after, expected: plan.sources.local, location: location)
            do { try await validateIgnoreSources(plan.sources, changed: .local) } catch {
                throw IgnoreWriteOutcomeUnknown(retainedInput: nil)
            }
            return IgnoreRuleOutcome(plan: plan, recovery: nil, localAfter: after)
        }
    }

    public func undoIgnoreRule(_ outcome: IgnoreRuleOutcome) async throws {
        guard outcome.plan.location == location else { throw ModelFailure.changed }
        if let record = outcome.recovery {
            let restore = try await prepareRecoveryRestore(record, layer: .worktree)
            guard restore.currentFiles.count == 1,
                restore.currentFiles[0].file.path == ".gitignore",
                restore.currentFiles[0].file.sha256 == RecoveryFileIO.hash(outcome.plan.after)
            else { throw ModelFailure.changed }
            _ = try await executeRecoveryRestore(restore)
        } else if let after = outcome.localAfter {
            try await withSharedOperation {
                _ = try await CommonExcludesFile.replace(
                    outcome.plan.before, expected: after, location: location)
            }
        }
    }

    private func ignorePattern(path: String, kind: IgnoreRuleKind) throws -> String {
        func escaped(_ value: String) -> String {
            var output = ""
            for char in value {
                if "\\*?[]#! ".contains(char) { output.append("\\") }
                output.append(char)
            }
            return output
        }
        switch kind {
        case .file: return "/" + escaped(path)
        case .directory:
            let parent = path.split(separator: "/").dropLast().joined(separator: "/")
            guard !parent.isEmpty else {
                throw ModelFailure.unsupported(L10n.text("根目录文件没有可忽略的父目录。"))
            }
            return "/" + escaped(parent) + "/"
        case .fileExtension:
            let suffix = (path as NSString).pathExtension
            guard !suffix.isEmpty else { throw ModelFailure.unsupported(L10n.text("此文件没有扩展名。")) }
            return "*." + escaped(suffix)
        }
    }

    private func appendIgnoreRule(_ pattern: String, to before: Data?) throws -> Data {
        let original = before ?? Data()
        guard !original.contains(0) else { throw ModelFailure.unsupported(L10n.text("忽略文件包含无法可靠处理的空字节。")) }
        let firstNewline = original.firstIndex(of: 10)
        let crlf = firstNewline.map { $0 > 0 && original[$0 - 1] == 13 } ?? false
        let ending = crlf ? Data([13, 10]) : Data([10])
        var result = original
        if !result.isEmpty, result.last != 10 { result.append(ending) }
        result.append(Data(pattern.utf8))
        result.append(ending)
        guard result.count <= CommonExcludesFile.limit else { throw RecoveryBudget.exceeded }
        return result
    }

    private func ignoreCaptureData(_ capture: RecoveryFileCapture) async throws -> Data? {
        if capture.file.kind == .absent { return nil }
        guard capture.file.kind == .file, capture.file.bytes <= CommonExcludesFile.limit,
            let snapshot = capture.snapshot
        else { throw ModelFailure.unsupported(L10n.text("忽略文件不是普通文件或超过读取上限。")) }
        return try await SnapshotIO.run { cancellation in
            let fd = try snapshot.open()
            defer { Darwin.close(fd) }
            try cancellation.check()
            let data =
                try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(
                    upToCount: CommonExcludesFile.limit + 1) ?? Data()
            try snapshot.validate(fd)
            guard data.count == capture.file.bytes, RecoveryFileIO.hash(data) == capture.file.sha256 else {
                throw ModelFailure.changed
            }
            return data
        }
    }

    func ignoreConfiguration(_ key: String) async throws -> String? {
        let result = try await recoveryEngine.run(
            ["config", "--path", "--null", "--get", key], in: location.root, accepted: [0, 1],
            outputLimit: 16384)
        guard result.exitCode == 0 else { return nil }
        guard result.stdout.last == 0,
            let value = String(data: result.stdout.dropLast(), encoding: .utf8), !value.contains("\0")
        else { throw ModelFailure.changed }
        return value
    }

    func ignoreGlobalFile(key: String = "core.excludesfile") async throws -> IgnoreGlobalFile {
        guard key == "core.excludesfile" || key == "core.attributesfile" else {
            throw ModelFailure.invalidPath
        }
        let setting = try await ignoreConfiguration(key)
        let path: URL
        if let setting {
            path =
                setting.hasPrefix("/")
                ? URL(fileURLWithPath: setting) : location.root.appending(path: setting)
        } else {
            let directory =
                engine.environment["XDG_CONFIG_HOME"]
                ?? ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            path =
                (directory.map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config"))
                .appending(path: key == "core.excludesfile" ? "git/ignore" : "git/attributes")
        }
        return try await SnapshotIO.run { cancellation in
            let resolved = path.resolvingSymlinksInPath()
            if resolved.path == "/dev/null" {
                return IgnoreGlobalFile(
                    setting: setting, path: path, resolved: resolved, identity: nil, stamp: nil, bytes: nil)
            }
            let identity = try RepositoryNodeIdentity.readIfPresent(resolved)
            if identity == nil {
                return IgnoreGlobalFile(
                    setting: setting, path: path, resolved: resolved, identity: identity, stamp: nil,
                    bytes: nil)
            }
            let fd = Darwin.open(resolved.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ModelFailure.changed }
            defer { Darwin.close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                before.st_size >= 0, before.st_size <= CommonExcludesFile.limit
            else { throw ModelFailure.changed }
            try cancellation.check()
            let data =
                try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(
                    upToCount: CommonExcludesFile.limit + 1) ?? Data()
            var after = stat()
            guard fstat(fd, &after) == 0, SnapshotFileStamp(before) == SnapshotFileStamp(after),
                data.count == before.st_size, path.resolvingSymlinksInPath() == resolved,
                try RepositoryNodeIdentity.readIfPresent(resolved) == identity
            else { throw ModelFailure.changed }
            return IgnoreGlobalFile(
                setting: setting, path: path, resolved: resolved, identity: identity,
                stamp: SnapshotFileStamp(after), bytes: data)
        }
    }

    private func validateIgnoreSources(_ sources: IgnoreRuleSources, changed: IgnoreRuleScope? = nil)
        async throws
    {
        guard try await head() == sources.head,
            try SelectedIndexSnapshot.read(location: location) == sources.index,
            try await ignoreGlobalFile() == sources.global,
            try await ignoreConfiguration("core.ignorecase") == sources.ignoreCase
        else { throw ModelFailure.changed }
        try await RecoveryFileIO.verifyAll(
            sources.captures.filter { changed != .repository || $0.file.path != ".gitignore" },
            location: location)
        if changed != .local {
            guard try await CommonExcludesFile.read(location) == sources.local else {
                throw ModelFailure.changed
            }
        }
    }

    private func previewIgnoreRule(
        pattern: String, scope: IgnoreRuleScope, root: RecoveryFileCapture, rootData: Data?,
        localData: Data?, candidate: Data, global: IgnoreGlobalFile, ignoreCase: String?
    ) async throws -> ([String], [RecoveryFileCapture]) {
        func paths(_ data: Data) throws -> [String] {
            guard data.isEmpty || data.last == 0 else { throw ModelFailure.changed }
            return try data.split(separator: 0).map {
                guard let path = String(data: $0, encoding: .utf8) else { throw ModelFailure.invalidPath }
                try RecoveryFileIO.validate(path)
                return path
            }
        }
        let all = try paths(
            await recoveryEngine.run(
                ["ls-files", "--others", "--exclude-standard", "-z"], in: location.root,
                outputLimit: 32 * 1024 * 1024
            ).stdout)
        let remaining = Set(
            try paths(
                await recoveryEngine.run(
                    ["ls-files", "--others", "--exclude-standard", "--exclude=" + pattern, "-z"],
                    in: location.root, outputLimit: 32 * 1024 * 1024
                ).stdout))
        let candidates = all.filter { !remaining.contains($0) }
        guard all.count <= 100000, candidates.count <= 1000, Set(all).count == all.count else {
            throw RecoveryBudget.exceeded
        }
        let candidateSet = Set(candidates)
        var ignorePaths: Set<String> = [".gitignore"]
        for path in candidates {
            let parts = path.split(separator: "/")
            for index in 1..<parts.count {
                ignorePaths.insert(parts.prefix(index).joined(separator: "/") + "/.gitignore")
                guard ignorePaths.count <= 4096 else { throw RecoveryBudget.exceeded }
            }
        }
        var captures = [root]
        var files: [(String, Data)] = []
        var total = 0
        for path in ignorePaths.sorted() where path != ".gitignore" {
            let captured = try await RecoveryFileIO.capture(location: location, path: path, name: "blob-0")
            captures.append(captured)
            if let data = try await ignoreCaptureData(captured) {
                total += data.count
                guard total <= 16 * 1024 * 1024 else { throw RecoveryBudget.exceeded }
                files.append((path, data))
            }
        }
        let storage = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: location.root, create: true)
        let storageIdentity = try RepositoryNodeIdentity.read(storage, directory: true)
        defer {
            if (try? RepositoryNodeIdentity.read(storage, directory: true)) == storageIdentity {
                try? FileManager.default.removeItem(at: storage)
            }
        }
        let work = storage.appending(path: "work")
        let git = storage.appending(path: "git")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        _ = try await recoveryEngine.run(["init", "--bare", "--template=", git.path], in: storage)
        try FileManager.default.createDirectory(
            at: git.appending(path: "info"), withIntermediateDirectories: false)
        try (scope == .repository ? candidate : rootData ?? Data()).write(
            to: work.appending(path: ".gitignore"))
        try (scope == .local ? candidate : localData ?? Data()).write(to: git.appending(path: "info/exclude"))
        for path in candidates {
            try FileManager.default.createDirectory(
                at: work.appending(path: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        for (path, data) in files { try data.write(to: work.appending(path: path)) }
        var privateEngine = recoveryEngine
        privateEngine.environment["GIT_DIR"] = git.path
        privateEngine.environment["GIT_WORK_TREE"] = work.path
        privateEngine.environment["GIT_INDEX_FILE"] = git.appending(path: "index").path
        let globalPath = storage.appending(path: "global-ignore")
        try (global.bytes ?? Data()).write(to: globalPath)
        var input = Data()
        for path in candidates {
            // check-ignore rejects pathspec magic, including the global literal
            // option. A ./ prefix protects names that themselves start with :.
            input.append(Data(("./" + path).utf8))
            input.append(0)
        }
        if input.isEmpty {
            try await RecoveryFileIO.verifyAll(captures, location: location)
            return ([], captures)
        }
        let output = try await privateEngine.run(
            ["check-ignore", "--no-index", "-z", "-v", "--stdin"], in: work, input: input, accepted: [0, 1],
            configuration: [
                (key: "core.excludesfile", value: globalPath.path),
                (key: "core.ignorecase", value: ignoreCase ?? "false"),
            ], literalPathspecs: false)
        let records = output.stdout.split(separator: 0, omittingEmptySubsequences: false)
        guard records.last?.isEmpty == true, (records.count - 1).isMultiple(of: 4) else {
            throw ModelFailure.changed
        }
        var matches: [String] = []
        for index in stride(from: 0, to: records.count - 1, by: 4) {
            let rule = records[index + 2]
            guard let transported = String(data: records[index + 3], encoding: .utf8),
                transported.hasPrefix("./")
            else {
                throw ModelFailure.changed
            }
            let path = String(transported.dropFirst(2))
            guard candidateSet.contains(path) else { throw ModelFailure.changed }
            if rule.first != 33 { matches.append(path) }
        }
        try await RecoveryFileIO.verifyAll(captures, location: location)
        return (matches.sorted(), captures)
    }
}
