import Darwin
import Foundation

extension RepositoryService {
    @concurrent public func prepareLFSRule(pattern: String, action: LFSRuleAction) async throws -> LFSRulePlan
    {
        guard !pattern.isEmpty, pattern.utf8.count <= 8192, !pattern.contains("\0"),
            !pattern.contains("\n"), !pattern.contains("\r"), !pattern.hasPrefix("!"),
            !pattern.hasSuffix("/"), !pattern.hasPrefix("[attr]")
        else { throw ModelFailure.invalidPath }
        let installation = try await lfsInstallation()
        let initialIndex = try SelectedIndexSnapshot.read(location: location)
        let initialHead = try await head()
        let original = try await RecoveryFileIO.capture(
            location: location, path: ".gitattributes", name: "blob-0")
        let before = try await resourceCaptureBytes(original) ?? Data()
        let after = try ResourceRuleDocument.lfsRule(before, pattern: pattern, action: action)
        let global = try await ignoreGlobalFile(key: "core.attributesfile")
        let info = try lfsInfoAttributes()
        let ignoreCase = try await ignoreConfiguration("core.ignorecase")
        let listing = try await engine.run(
            ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            in: location.root, outputLimit: 8 * 1024 * 1024
        ).stdout
        guard listing.isEmpty || listing.last == 0 else { throw ModelFailure.changed }
        let paths = try Set(
            listing.split(separator: 0).map { row -> String in
                guard let path = String(data: row, encoding: .utf8) else { throw ModelFailure.invalidPath }
                try validate(path)
                return path
            }
        ).sorted()
        guard paths.count <= 100000 else { throw RecoveryBudget.exceeded }
        var sourcePaths: Set<String> = [".gitattributes"]
        for path in paths {
            let components = path.split(separator: "/")
            for index in 1..<components.count {
                sourcePaths.insert(components.prefix(index).joined(separator: "/") + "/.gitattributes")
                guard sourcePaths.count <= 4096 else { throw RecoveryBudget.exceeded }
            }
        }
        var captures = [original]
        var files: [(String, Data)] = [(".gitattributes", after)]
        var total = after.count + (global.bytes?.count ?? 0) + (info.bytes?.count ?? 0)
        for path in sourcePaths.sorted() where path != ".gitattributes" {
            let capture = try await RecoveryFileIO.capture(location: location, path: path, name: "blob-0")
            captures.append(capture)
            let workBytes = try await resourceCaptureBytes(capture)
            let bytes: Data?
            if let workBytes {
                bytes = workBytes
            } else {
                // Git falls back to the staged attributes when a worktree copy is
                // absent. Keep that source in preview rather than hiding it.
                let staged = try await recoveryEngine.run(
                    ["cat-file", "blob", ":" + path], in: location.root,
                    accepted: [0, 128], outputLimit: 4 * 1024 * 1024)
                bytes = staged.exitCode == 0 ? staged.stdout : nil
            }
            if let bytes {
                total += bytes.count
                guard total <= 16 * 1024 * 1024 else { throw RecoveryBudget.exceeded }
                files.append((path, bytes))
            }
        }
        let preview = try await lfsRulePreview(
            pattern: pattern, paths: paths, files: files,
            before: before, global: global.bytes ?? Data(), info: info.bytes ?? Data(), ignoreCase: ignoreCase
        )
        let desired = try await RecoveryFileIO.replacement(
            path: ".gitattributes", data: after,
            mode: original.file.kind == .absent ? 0o644 : original.file.mode)
        let modification = try await prepareFileModification(
            path: ".gitattributes", desired: desired,
            operation: "lfs-" + action.rawValue, layer: .worktree)
        guard modification.current.matches(original), modification.index == initialIndex,
            modification.head == initialHead
        else { throw ModelFailure.changed }
        let plan = LFSRulePlan(
            id: UUID(), pattern: pattern, action: action, installation: installation,
            before: String(decoding: before, as: UTF8.self), after: String(decoding: after, as: UTF8.self),
            rules: preview.rules, matchedPaths: preview.matches, location: location,
            modification: modification, captures: captures, global: global, info: info,
            ignoreCase: ignoreCase,
            knownPaths: paths, originalAttributes: preview.before, resultAttributes: preview.after)
        try await validateLFSRuleSources(plan)
        return plan
    }

    public func executeLFSRule(_ plan: LFSRulePlan) async throws -> LFSRuleOutcome {
        guard plan.location == location else { throw ModelFailure.changed }
        try await validateLFSRuleSources(plan)
        var record = try await executeFileModification(plan.modification)
        do {
            try await validateLFSRuleSources(plan, rootChanged: true)
            return LFSRuleOutcome(plan: plan, recovery: record)
        } catch {
            record.state = .needsVerification
            record.details = Redaction.text(error.localizedDescription)
            let failed = record
            await Task.detached { try? RecoveryStore(location: self.location).save(failed) }.value
            throw RecoveryOutcomeUnknown(recordID: record.id, details: error.localizedDescription)
        }
    }

    private func lfsInfoAttributes() throws -> LFSInfoAttributesSnapshot {
        try location.validateIdentity()
        let directory = location.commonDirectory.appending(path: "info")
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT else { throw ModelFailure.changed }
            return LFSInfoAttributesSnapshot(
                snapshot: SelectedIndexSnapshot(bytes: nil, mode: 0o644), directory: nil, file: nil)
        }
        defer { Darwin.close(descriptor) }
        let identity = try RepositoryNodeIdentity.read(directory, directory: true)
        let file = try RepositoryNodeIdentity.readIfPresent(directory.appending(path: "attributes"))
        let snapshot = try SelectedIndexSnapshot.read(parent: descriptor, name: "attributes")
        guard try RepositoryNodeIdentity.read(directory, directory: true) == identity,
            try RepositoryNodeIdentity.readIfPresent(directory.appending(path: "attributes")) == file
        else { throw ModelFailure.changed }
        return LFSInfoAttributesSnapshot(snapshot: snapshot, directory: identity, file: file)
    }

    private func validateLFSRuleSources(_ plan: LFSRulePlan, rootChanged: Bool = false) async throws {
        try location.validateIdentity()
        guard try await ignoreGlobalFile(key: "core.attributesfile") == plan.global,
            try lfsInfoAttributes() == plan.info,
            try await ignoreConfiguration("core.ignorecase") == plan.ignoreCase,
            try SelectedIndexSnapshot.read(location: location) == plan.modification.index,
            try await head() == plan.modification.head
        else { throw ModelFailure.changed }
        try await RecoveryFileIO.verifyAll(
            plan.captures.filter { !rootChanged || $0.file.path != ".gitattributes" }, location: location)
        let listing = try await engine.run(
            ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            in: location.root, outputLimit: 8 * 1024 * 1024
        ).stdout
        let paths = Set(listing.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }).subtracting([
            ".gitattributes"
        ])
        guard paths == Set(plan.knownPaths).subtracting([".gitattributes"]) else {
            throw ModelFailure.changed
        }
        var input = Data()
        for path in plan.knownPaths {
            input.append(Data(path.utf8))
            input.append(0)
        }
        let attributes =
            input.isEmpty
            ? Data()
            : try await recoveryEngine.run(
                ["check-attr", "-z", "--stdin", "filter", "diff", "merge", "text"], in: location.root,
                input: input, outputLimit: 32 * 1024 * 1024
            ).stdout
        guard attributes == (rootChanged ? plan.resultAttributes : plan.originalAttributes) else {
            throw ModelFailure.changed
        }
        if rootChanged {
            try await RecoveryFileIO.verifyContentsAll([plan.modification.desired], location: location)
        }
    }

    private func lfsRulePreview(
        pattern: String, paths: [String], files: [(String, Data)], before: Data, global: Data, info: Data,
        ignoreCase: String?
    ) async throws -> (rules: [LFSAttributeRule], matches: [LFSRuleMatch], before: Data, after: Data) {
        let storage = try SnapshotDirectory()
        let work = storage.url.appending(path: "work")
        let git = storage.url.appending(path: "git")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        _ = try await recoveryEngine.run(["init", "--bare", "--template=", git.path], in: storage.url)
        try FileManager.default.createDirectory(
            at: git.appending(path: "info"), withIntermediateDirectories: true)
        var rules: [LFSAttributeRule] = []
        var origins: [String: String] = [:]
        let originAttribute = "wegit-lfs-origin-" + UUID().uuidString.lowercased()
        let candidateAttribute = "wegit-lfs-candidate-" + UUID().uuidString.lowercased()
        var macroFilter: Set<String> = []
        let sourceDocuments = [global] + files.map(\.1) + [info]
        var macroDefinitions: [String: [String]] = [:]
        for bytes in sourceDocuments {
            for line in try ResourceRuleDocument.lines(bytes) {
                let tokens = try ResourceRuleDocument.attributeTokens(line.body)
                guard let first = tokens.first else { continue }
                let name = try ResourceRuleDocument.unquote(String(line.body[first]))
                if name.hasPrefix("[attr]") {
                    macroDefinitions[String(name.dropFirst(6))] = tokens.dropFirst().map {
                        String(line.body[$0])
                    }
                }
            }
        }
        guard macroDefinitions.count <= 64 else { throw RecoveryBudget.exceeded }
        for _ in 0...macroDefinitions.count {
            let previous = macroFilter.count
            for (name, attributes) in macroDefinitions
            where attributes.contains(where: {
                $0 == "filter" || $0 == "-filter" || $0 == "!filter" || $0.hasPrefix("filter=")
                    || macroFilter.contains($0)
            }) { macroFilter.insert(name) }
            if macroFilter.count == previous { break }
        }
        func annotated(_ bytes: Data, source: String) throws -> Data {
            var lines = try ResourceRuleDocument.lines(bytes)
            for index in lines.indices {
                let tokens = try ResourceRuleDocument.attributeTokens(lines[index].body)
                guard let first = tokens.first else { continue }
                let pattern = try ResourceRuleDocument.unquote(String(lines[index].body[first]))
                let attributes = tokens.dropFirst().map { String(lines[index].body[$0]) }
                rules.append(
                    LFSAttributeRule(
                        source: source, line: index + 1, pattern: pattern,
                        attributes: attributes.joined(separator: " ")))
                if attributes.contains(where: {
                    $0 == "filter" || $0 == "-filter" || $0 == "!filter" || $0.hasPrefix("filter=")
                        || macroFilter.contains($0)
                }) {
                    let token = "r" + String(origins.count)
                    origins[token] = source + ":" + String(index + 1)
                    lines[index].body += " " + originAttribute + "=" + token
                }
            }
            return ResourceRuleDocument.bytes(lines)
        }
        let globalFile = storage.url.appending(path: "global-attributes")
        try annotated(global, source: "core.attributesfile").write(to: globalFile)
        for (path, bytes) in files {
            let destination = work.appending(path: path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try annotated(bytes, source: path).write(to: destination)
        }
        // A candidate-only attribute asks Git itself which known paths match the
        // entered pattern. It does not approximate Git wildmatch in application code.
        let root = work.appending(path: ".gitattributes")
        var rootBytes = try Data(contentsOf: root)
        if !rootBytes.isEmpty, rootBytes.last != 10 { rootBytes.append(10) }
        rootBytes.append(
            Data((ResourceRuleDocument.quote(pattern) + " " + candidateAttribute + "=set\n").utf8))
        try rootBytes.write(to: root)
        try annotated(info, source: ".git/info/attributes").write(to: git.appending(path: "info/attributes"))
        guard rules.count <= 16384 else { throw RecoveryBudget.exceeded }
        for path in paths {
            try FileManager.default.createDirectory(
                at: work.appending(path: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var privateEngine = recoveryEngine
        privateEngine.environment["GIT_DIR"] = git.path
        privateEngine.environment["GIT_WORK_TREE"] = work.path
        privateEngine.environment["GIT_INDEX_FILE"] = git.appending(path: "index").path
        let attributes = ["filter", "diff", "merge", "text", originAttribute, candidateAttribute]
        var input = Data()
        for path in paths {
            input.append(Data(path.utf8))
            input.append(0)
        }
        if input.isEmpty { return (rules, [], Data(), Data()) }
        let configuration = [
            (key: "core.attributesfile", value: globalFile.path),
            (key: "core.ignorecase", value: ignoreCase ?? "false"),
        ]
        // Compare the original stack with Git's actual effective attributes. An
        // unrepresented system source or macro expansion is an explicit refusal.
        try before.write(to: root)
        let originalAttributes = Array(attributes.prefix(4))
        let baseline = try await privateEngine.run(
            ["check-attr", "-z", "--stdin"] + originalAttributes,
            in: work, input: input, outputLimit: 32 * 1024 * 1024, configuration: configuration
        ).stdout
        let actualBaseline = try await recoveryEngine.run(
            ["check-attr", "-z", "--stdin"] + originalAttributes,
            in: location.root, input: input, outputLimit: 32 * 1024 * 1024
        ).stdout
        guard baseline == actualBaseline else {
            throw ModelFailure.unsupported(L10n.text("属性有效来源无法完整核对，请在对应来源处理后重新预览。"))
        }
        try rootBytes.write(to: root)
        let output = try await privateEngine.run(
            ["check-attr", "-z", "--stdin"] + attributes,
            in: work, input: input, outputLimit: 32 * 1024 * 1024,
            configuration: configuration
        ).stdout
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.last?.isEmpty == true, fields.count - 1 == paths.count * attributes.count * 3 else {
            throw ModelFailure.changed
        }
        var matches: [LFSRuleMatch] = []
        var resultAttributes = Data()
        for (index, path) in paths.enumerated() {
            var values: [String: String] = [:]
            for attributeIndex in attributes.indices {
                let offset = (index * attributes.count + attributeIndex) * 3
                guard String(decoding: fields[offset], as: UTF8.self) == path,
                    String(decoding: fields[offset + 1], as: UTF8.self) == attributes[attributeIndex]
                else { throw ModelFailure.changed }
                values[attributes[attributeIndex]] = String(decoding: fields[offset + 2], as: UTF8.self)
                if attributeIndex < 4 {
                    for part in 0..<3 {
                        resultAttributes.append(contentsOf: fields[offset + part])
                        resultAttributes.append(0)
                    }
                }
            }
            guard values[candidateAttribute] == "set" else { continue }
            guard matches.count < 1000 else { throw RecoveryBudget.exceeded }
            matches.append(
                LFSRuleMatch(
                    path: path, filter: values["filter"]!, diff: values["diff"]!,
                    merge: values["merge"]!, text: values["text"]!,
                    filterSource: origins[values[originAttribute] ?? ""]))
        }
        withExtendedLifetime(storage) {}
        return (rules, matches, actualBaseline, resultAttributes)
    }
}
