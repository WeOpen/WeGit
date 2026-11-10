import Darwin
import Foundation

extension RepositoryService {
    @concurrent public func prepareSubmoduleChange(
        operation: SubmoduleChangeOperation, path: String, source: String? = nil,
        name requestedName: String? = nil, synchronizeChildRemote: Bool = false
    ) async throws -> SubmoduleChangePlan {
        try validate(path)
        guard path.utf8.count <= 8192 else { throw ModelFailure.invalidPath }
        if operation != .remove {
            guard let source, !source.isEmpty, source.utf8.count <= 16384,
                !source.contains("\0"), !source.contains("\n"), !source.contains("\r")
            else { throw ModelFailure.invalidPath }
        }
        let child = try await submoduleChild(path: path)
        return try await withSubmoduleOperation(child: child.location) {
            let context = try await recoveryContext()
            let index = try SelectedIndexSnapshot.read(location: location)
            let shared = try await captureRecoverySharedIndex(index)
            let modules = try await readSubmodulesDirect()
            let module = modules.first { $0.path == path }
            let properties = try await submoduleProperties()
            let names = properties.filter { $0.value["path"] == path }.map(\.key)
            let name: String
            if operation == .add {
                guard module == nil, names.isEmpty, child.directory == nil else { throw ModelFailure.changed }
                name =
                    requestedName
                    ?? (path.contains("\n") || path.contains("\r")
                        ? "wegit-" + String(RecoveryFileIO.hash(Data(path.utf8)).prefix(20)) : path)
                guard properties[name] == nil else { throw ModelFailure.changed }
                let indexed = try await engine.run(["ls-files", "-z", "--", path], in: location.root).stdout
                guard indexed.isEmpty else { throw ModelFailure.changed }
            } else {
                guard names.count == 1, let existing = names.first else { throw ModelFailure.changed }
                name = existing
            }
            guard !name.isEmpty, name.utf8.count <= 8192, !name.contains("\0"), !name.contains("\n"),
                !name.contains("\r")
            else { throw ModelFailure.invalidPath }
            let root = try await RecoveryFileIO.capture(
                location: location, path: ".gitmodules", name: "blob-0")
            let before = try await resourceCaptureBytes(root) ?? Data()
            let config = try submoduleConfigurationSnapshot()
            let effective = try await submoduleEffectiveConfiguration()
            let inherited = try await engine.run(
                [
                    "config", "--null", "--show-scope", "--show-origin", "--get-all",
                    "submodule." + name + ".url",
                ],
                in: location.root, accepted: [0, 1], outputLimit: 65536
            ).stdout
            // An include/global/worktree URL can override the file being edited.
            // Require the user to resolve that scope rather than changing it here.
            let records = inherited.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            for offset in stride(from: 0, to: records.count, by: 3) {
                guard offset + 2 < records.count,
                    records[offset] == "local",
                    records[offset + 1].hasPrefix("file:"),
                    URL(fileURLWithPath: String(records[offset + 1].dropFirst(5)), relativeTo: location.root)
                        .standardizedFileURL
                        == location.commonDirectory.appending(path: "config")
                else { throw ModelFailure.unsupported(L10n.text("子模块 URL 由其他配置来源覆盖，请先在对应作用域处理。")) }
            }
            let originalSource = properties[name]?["url"]
            let after: Data
            let configAfter: Data
            let target: String?
            switch operation {
            case .add:
                let address = source!
                let remote = try await engine.run(
                    ["ls-remote", "--exit-code", "--", address, "HEAD"], in: location.root,
                    timeout: 120, outputLimit: 65536
                ).text.split(separator: "\n")
                guard remote.count == 1, let row = remote.first else { throw ModelFailure.changed }
                let fields = row.split(separator: "\t")
                guard fields.count == 2, fields[1] == "HEAD", GitObjectID.valid(String(fields[0])) else {
                    throw ModelFailure.changed
                }
                target = String(fields[0])
                after = try ResourceRuleDocument.moduleKeys(
                    before, name: name,
                    updates: ["path": path, "url": address], append: true)
                configAfter = config.bytes ?? Data()
            case .remove:
                target = nil
                after = try ResourceRuleDocument.moduleKeys(
                    before, name: name, updates: ["path": nil, "url": nil])
                configAfter = try ResourceRuleDocument.moduleKeys(
                    config.bytes ?? Data(), name: name,
                    updates: ["url": nil, "active": nil])
            case .changeSource:
                target = module?.indexOID
                after = try ResourceRuleDocument.moduleKeys(before, name: name, updates: ["url": source])
                configAfter =
                    inherited.isEmpty
                    ? config.bytes ?? Data()
                    : try ResourceRuleDocument.moduleKeys(
                        config.bytes ?? Data(), name: name, updates: ["url": source])
            }
            try await submoduleValidateDocument(
                after, name: name,
                expected: operation == .remove ? ["path": nil, "url": nil] : ["path": path, "url": source])
            if operation == .remove {
                try await submoduleValidateDocument(
                    configAfter, name: name, expected: ["url": nil, "active": nil])
            } else if operation == .changeSource && !inherited.isEmpty {
                try await submoduleValidateDocument(configAfter, name: name, expected: ["url": source])
            }
            let desired = try await RecoveryFileIO.replacement(
                path: ".gitmodules", data: after,
                mode: root.file.kind == .absent ? 0o644 : root.file.mode)
            let childRemote: SubmoduleChildRemoteSnapshot?
            if synchronizeChildRemote {
                guard operation == .changeSource, let source else { throw ModelFailure.invalidPath }
                childRemote = try await prepareSubmoduleChildRemote(child, source: source)
            } else {
                childRemote = nil
            }
            let candidate: Data?
            if operation == .add {
                candidate = try await replacementIndex(
                    path: path, mode: "160000", object: target, index: index)
            } else if operation == .remove {
                candidate = try await replacementIndex(path: path, mode: nil, object: nil, index: index)
            } else {
                candidate = nil
            }
            let parents = try submoduleDestinationParents(path: path)
            let plan = SubmoduleChangePlan(
                id: UUID(), operation: operation, path: path, name: name,
                previousSource: originalSource, source: source, recordedOID: module?.recordedOID,
                indexOID: module?.indexOID, targetOID: target, retention: child.retention,
                gitmodulesPreview: String(decoding: after, as: UTF8.self),
                downloadsRepository: operation == .add,
                synchronizeChildRemote: synchronizeChildRemote, childRemoteSource: childRemote?.source,
                location: location, head: context.head, branch: context.branch, index: index,
                sharedIndex: shared, gitmodules: root, desiredGitmodules: desired,
                config: config, configAfter: configAfter, effectiveConfig: effective, child: child,
                destinationParents: parents, candidateIndex: candidate, childRemote: childRemote)
            try await validateSubmodulePlan(plan)
            return plan
        }
    }

    public func executeSubmoduleChange(_ plan: SubmoduleChangePlan) async throws -> SubmoduleChangeReceipt {
        guard plan.location == location else { throw ModelFailure.changed }
        return try await withSubmoduleOperation(child: plan.child.location) {
            try await validateSubmodulePlan(plan)
            guard plan.child.retention.locks.isEmpty else { throw ModelFailure.changed }
            let store = try RecoveryStore(location: location)
            var recovery = try await store.persist(
                operation: "submodule-" + plan.operation.rawValue,
                head: plan.head, branch: plan.branch, target: plan.targetOID, index: plan.index,
                files: [plan.gitmodules], sharedIndex: plan.sharedIndex)
            recovery.indexTree = try await recoveryIndexTree(
                plan.index.bytes, shared: plan.sharedIndex, persist: true)
            try store.save(recovery)
            try await protectRecovery(recovery)
            // RecoveryStore intentionally rejects unlisted/nested inputs on trim.
            // Keep download/config receipts in their own bounded, retained namespace.
            let receiptStore = try SubmoduleChangeStorage(location: location, id: plan.id)
            let directory = receiptStore.url
            try submoduleSaveBytes(
                plan.config.bytes ?? Data(), at: directory.appending(path: "module-config-before"),
                storage: receiptStore)
            let download = plan.operation == .add ? directory.appending(path: "download") : nil
            let childConfiguration = plan.childRemote.map { _ in
                directory.appending(path: "child-config-before")
            }
            if let childRemote = plan.childRemote, let childConfiguration {
                try submoduleSaveBytes(
                    childRemote.config.bytes ?? Data(), at: childConfiguration, storage: receiptStore)
            }
            var receipt = SubmoduleChangeReceipt(
                id: plan.id, format: 1, recoveryID: recovery.id, workspaceID: location.persistenceID,
                operation: plan.operation.rawValue, path: plan.path, originalHead: plan.head,
                originalChildHead: plan.child.head,
                targetOID: plan.targetOID,
                retainedFiles: plan.retention.files,
                retainedGitData: plan.operation == .add
                    ? download?.appending(path: ".git") : plan.retention.gitData,
                retainedDownload: download, receiptFile: directory.appending(path: "module-change.json"),
                originalConfigurationSHA256: RecoveryFileIO.hash(plan.config.bytes ?? Data()),
                childRemoteSyncRequested: plan.synchronizeChildRemote,
                retainedChildConfiguration: childConfiguration,
                originalChildConfigurationSHA256: plan.childRemote.map {
                    RecoveryFileIO.hash($0.config.bytes ?? Data())
                },
                phase: .prepared)
            try saveSubmoduleReceipt(receipt, storage: receiptStore)
            var downloadedLocation: RepositoryLocation?
            do {
                receipt.phase = .started
                try saveSubmoduleReceipt(receipt, storage: receiptStore)
                if let download {
                    try receiptStore.validate()
                    var downloader = recoveryEngine
                    downloader.environment["GIT_LFS_SKIP_SMUDGE"] = "1"
                    _ = try await downloader.run(
                        [
                            "clone", "--no-checkout", "--no-recurse-submodules", "--template=", "--",
                            plan.source!, download.path,
                        ],
                        in: location.root, timeout: 120, outputLimit: 4 * 1024 * 1024,
                        configuration: [("core.hooksPath", "/dev/null"), ("submodule.recurse", "false")])
                    let clone = try await Self.discover(download, engine: downloader)
                    _ = try await downloader.run(
                        ["cat-file", "-e", plan.targetOID! + "^{commit}"], in: clone.root)
                    _ = try await downloader.run(
                        ["checkout", "--detach", plan.targetOID!], in: clone.root,
                        timeout: 120,
                        configuration: [("core.hooksPath", "/dev/null"), ("submodule.recurse", "false")])
                    guard
                        try await downloader.run(["rev-parse", "HEAD"], in: clone.root).text
                            .removingLastNewline
                            == plan.targetOID
                    else { throw ModelFailure.changed }
                    receipt.downloaded = true
                    downloadedLocation = clone
                    try saveSubmoduleReceipt(receipt, storage: receiptStore)
                }
                try await validateSubmodulePlan(plan)
                let indexLease = try SelectedIndexLease(location: location, snapshot: plan.index)
                let configLease = try RepositoryConfigurationFile(location: location, scope: .local)
                guard configLease.snapshot == plan.config else { throw ModelFailure.changed }
                try await validateSubmodulePlan(plan)
                let childConfigLease = try plan.childRemote.map {
                    try RepositoryConfigurationFile(location: $0.location, scope: .local)
                }
                if let childRemote = plan.childRemote {
                    guard childConfigLease?.snapshot == childRemote.config else { throw ModelFailure.changed }
                }
                if let candidate = plan.candidateIndex { try indexLease.write(candidate) }
                if let download {
                    try receiptStore.validate()
                    guard let downloadedLocation else { throw ModelFailure.changed }
                    try submoduleInstallDownload(
                        download, plan: plan, storage: receiptStore, clone: downloadedLocation)
                    receipt.childInstalled = true
                    receipt.retainedDownload = nil
                    receipt.retainedGitData = plan.retention.files.appending(path: ".git")
                    try saveSubmoduleReceipt(receipt, storage: receiptStore)
                }
                try await RecoveryFileIO.installAll(
                    sources: [plan.desiredGitmodules], expected: [plan.gitmodules], location: location)
                receipt.gitmodulesWritten = true
                try saveSubmoduleReceipt(receipt, storage: receiptStore)
                if plan.configAfter != (plan.config.bytes ?? Data()) {
                    try await configLease.install(plan.configAfter)
                    receipt.configurationWritten = true
                    try saveSubmoduleReceipt(receipt, storage: receiptStore)
                    try await configLease.finish()
                }
                let context = try await recoveryContext()
                if let childRemote = plan.childRemote, let childConfigLease {
                    try await childConfigLease.install(childRemote.after)
                    receipt.childConfigurationWritten = true
                    try saveSubmoduleReceipt(receipt, storage: receiptStore)
                    try await childConfigLease.finish()
                }
                guard context.head == plan.head, context.branch == plan.branch else {
                    throw ModelFailure.changed
                }
                try indexLease.verify()
                if plan.candidateIndex != nil {
                    try indexLease.install()
                    receipt.indexWritten = true
                    try saveSubmoduleReceipt(receipt, storage: receiptStore)
                }
                try await RecoveryFileIO.verifyContentsAll([plan.desiredGitmodules], location: location)
                guard
                    try SelectedIndexSnapshot.read(location: location).bytes
                        == (plan.candidateIndex ?? plan.index.bytes),
                    try submoduleConfigurationSnapshot().bytes
                        == (plan.configAfter.isEmpty && plan.config.bytes == nil ? nil : plan.configAfter)
                else { throw ModelFailure.changed }
                let finalConfig = try await submoduleEffectiveConfiguration()
                if let childRemote = plan.childRemote {
                    let childEffective = try await submoduleEffectiveConfiguration(at: childRemote.location)
                    guard
                        try submoduleConfigurationSnapshot(at: childRemote.location).bytes
                            == childRemote.after,
                        try submoduleUnchangedChildConfiguration(childEffective, at: childRemote.location)
                            == submoduleUnchangedChildConfiguration(
                                childRemote.effectiveConfig, at: childRemote.location)
                    else { throw ModelFailure.changed }
                }
                guard
                    try submoduleUnchangedConfiguration(finalConfig, excluding: plan)
                        == submoduleUnchangedConfiguration(plan.effectiveConfig, excluding: plan)
                else { throw ModelFailure.changed }
                if plan.operation != .add {
                    try await verifySubmoduleChild(plan.child, path: plan.path)
                } else {
                    let actual = try await submoduleChild(path: plan.path)
                    guard actual.head == plan.targetOID,
                        actual.location?.root.path == plan.retention.files.path
                    else { throw ModelFailure.changed }
                }
                let verifiedContext = try await recoveryContext()
                guard verifiedContext.head == plan.head, verifiedContext.branch == plan.branch else {
                    throw ModelFailure.changed
                }
                recovery.state = .succeeded
                recovery.observedHead = plan.head
                try store.save(recovery)
                receipt.phase = .completed
                try receiptStore.validate()
                try saveSubmoduleReceipt(receipt, storage: receiptStore)
                withExtendedLifetime((indexLease, configLease, childConfigLease)) {}
                return receipt
            } catch {
                recovery.state = .needsVerification
                recovery.details = Redaction.text(error.localizedDescription)
                receipt.phase = .needsVerification
                receipt.detail = Redaction.text(error.localizedDescription)
                if let clone = downloadedLocation {
                    let placed = await Task.detached {
                        guard (try? self.location.validateIdentity()) != nil else { return false }
                        return (try? RepositoryNodeIdentity.readIfPresent(plan.retention.files))
                            == clone.rootIdentity
                    }.value
                    if placed {
                        receipt.childInstalled = true
                        receipt.retainedDownload = nil
                        receipt.retainedGitData = plan.retention.files.appending(path: ".git")
                    }
                }
                let failed = receipt
                let failedRecovery = recovery
                await Task.detached {
                    try? store.save(failedRecovery)
                    if (try? receiptStore.validate()) != nil {
                        try? self.saveSubmoduleReceipt(failed, storage: receiptStore)
                    }
                }.value
                throw SubmoduleChangeOutcomeUnknown(receipt: receipt)
            }
        }
    }

    /// Historical receipts remain read-only; reopening never repeats any stage.
    public func submoduleChangeReceipts() async throws -> [SubmoduleChangeReceipt] {
        try await queue.perform {
            try location.validateIdentity()
            let parentURL = location.gitDirectory.appending(path: "wegit-submodule-changes")
            let parent = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if parent < 0 {
                guard errno == ENOENT else { throw ModelFailure.changed }
                return []
            }
            defer { Darwin.close(parent) }
            let parentIdentity = try RepositoryNodeIdentity.read(parentURL, directory: true)
            var parentInfo = stat()
            guard fstat(parent, &parentInfo) == 0, parentInfo.st_dev == parentIdentity.device,
                parentInfo.st_ino == parentIdentity.inode, parentInfo.st_uid == getuid(),
                parentInfo.st_mode & 0o077 == 0
            else { throw ModelFailure.changed }
            let names = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
            guard names.count <= 20 else { throw RecoveryBudget.exceeded }
            var result: [SubmoduleChangeReceipt] = []
            for name in names.sorted() {
                guard let id = UUID(uuidString: name), id.uuidString == name else {
                    throw ModelFailure.changed
                }
                let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directory >= 0 else { throw ModelFailure.changed }
                defer { Darwin.close(directory) }
                let descriptor = openat(directory, "module-change.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw ModelFailure.changed }
                defer { Darwin.close(descriptor) }
                var before = stat()
                guard fstat(descriptor, &before) == 0, before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
                    before.st_uid == getuid(), before.st_size <= 65536
                else { throw ModelFailure.changed }
                let bytes =
                    try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 65537)
                    ?? Data()
                var after = stat()
                var named = stat()
                guard fstat(descriptor, &after) == 0, SnapshotFileStamp(before) == SnapshotFileStamp(after),
                    fstatat(directory, "module-change.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
                    SnapshotFileStamp(named) == SnapshotFileStamp(after),
                    bytes.count == before.st_size
                else { throw ModelFailure.changed }
                let receipt = try JSONDecoder().decode(SubmoduleChangeReceipt.self, from: bytes)
                guard receipt.format == 1, receipt.id == id, receipt.workspaceID == location.persistenceID,
                    receipt.receiptFile.path == parentURL.appending(path: name + "/module-change.json").path,
                    receipt.originalConfigurationSHA256.count == 64
                else { throw ModelFailure.changed }
                try validate(receipt.path)
                result.append(receipt)
            }
            try location.validateIdentity()
            guard try RepositoryNodeIdentity.read(parentURL, directory: true) == parentIdentity else {
                throw ModelFailure.changed
            }
            return result
        }
    }

    func resourceCaptureBytes(_ capture: RecoveryFileCapture) async throws -> Data? {
        if capture.file.kind == .absent { return nil }
        guard capture.file.kind == .file, capture.file.bytes <= 4 * 1024 * 1024,
            let snapshot = capture.snapshot
        else {
            throw ModelFailure.invalidPath
        }
        return try await SnapshotIO.run { _ in
            let descriptor = try snapshot.open()
            defer { Darwin.close(descriptor) }
            let bytes =
                try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(
                    upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            try snapshot.validate(descriptor)
            guard bytes.count == capture.file.bytes, RecoveryFileIO.hash(bytes) == capture.file.sha256 else {
                throw ModelFailure.changed
            }
            return bytes
        }
    }

    private func submoduleProperties() async throws -> [String: [String: String]] {
        let result = try await engine.run(
            ["config", "--file", ".gitmodules", "--null", "--get-regexp", "^submodule\\..*\\.(path|url)$"],
            in: location.root, accepted: [0, 1], outputLimit: 4 * 1024 * 1024
        ).stdout
        var values: [String: [String: String]] = [:]
        for row in result.split(separator: 0) {
            guard let text = String(data: row, encoding: .utf8), let split = text.firstIndex(of: "\n") else {
                throw ModelFailure.changed
            }
            let key = String(text[..<split])
            guard key.hasPrefix("submodule."), let last = key.lastIndex(of: ".") else {
                throw ModelFailure.changed
            }
            let name = String(key[key.index(key.startIndex, offsetBy: 10)..<last])
            let property = String(key[key.index(after: last)...])
            guard values[name]?[property] == nil else { throw ModelFailure.changed }
            values[name, default: [:]][property] = String(text[text.index(after: split)...])
        }
        return values
    }

    private func submoduleValidateDocument(
        _ bytes: Data, name: String, expected: [String: String?], section: String = "submodule"
    )
        async throws
    {
        let storage = try SnapshotDirectory()
        let file = storage.url.appending(path: "config")
        try bytes.write(to: file)
        for (key, value) in expected {
            let result = try await engine.run(
                ["config", "--file", file.path, "--null", "--get-all", section + "." + name + "." + key],
                in: location.root, accepted: [0, 1], outputLimit: 65536)
            if let value {
                guard result.stdout == Data((value + "\0").utf8) else { throw ModelFailure.changed }
            } else {
                guard result.stdout.isEmpty else { throw ModelFailure.changed }
            }
        }
        withExtendedLifetime(storage) {}
    }

    private func submoduleUnchangedConfiguration(_ bytes: Data, excluding plan: SubmoduleChangePlan) throws
        -> Data
    {
        let fields = bytes.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.last?.isEmpty == true, (fields.count - 1).isMultiple(of: 3) else {
            throw ModelFailure.changed
        }
        var result = Data()
        for index in stride(from: 0, to: fields.count - 1, by: 3) {
            let record = String(decoding: fields[index + 2], as: UTF8.self)
            let key = record.components(separatedBy: "\n").first ?? ""
            let changed =
                plan.operation == .add
                ? []
                : ["submodule." + plan.name + ".url"]
                    + (plan.operation == .remove ? ["submodule." + plan.name + ".active"] : [])
            if changed.contains(key) {
                // Only the explicitly captured local origin may change.
                let origin = String(decoding: fields[index + 1], as: UTF8.self)
                guard String(decoding: fields[index], as: UTF8.self) == "local", origin.hasPrefix("file:"),
                    URL(fileURLWithPath: String(origin.dropFirst(5)), relativeTo: location.root)
                        .standardizedFileURL
                        == location.commonDirectory.appending(path: "config")
                else { throw ModelFailure.changed }
                continue
            }
            for offset in 0..<3 {
                result.append(contentsOf: fields[index + offset])
                result.append(0)
            }
        }
        return result
    }

    private func submoduleConfigurationSnapshot(at target: RepositoryLocation? = nil) throws
        -> SelectedIndexSnapshot
    {
        let location = target ?? location
        try location.validateIdentity()
        let descriptor = Darwin.open(
            location.commonDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ModelFailure.changed }
        defer { Darwin.close(descriptor) }
        return try SelectedIndexSnapshot.read(parent: descriptor, name: "config")
    }

    private func submoduleEffectiveConfiguration(at target: RepositoryLocation? = nil) async throws -> Data {
        try await engine.run(
            ["config", "--null", "--show-scope", "--show-origin", "--list"],
            in: (target ?? location).root, outputLimit: 4 * 1024 * 1024
        ).stdout
    }

    private func validateSubmodulePlan(_ plan: SubmoduleChangePlan) async throws {
        try location.validateIdentity()
        let context = try await recoveryContext()
        guard plan.location == location, context.head == plan.head, context.branch == plan.branch,
            try SelectedIndexSnapshot.read(location: location) == plan.index,
            try submoduleConfigurationSnapshot() == plan.config,
            try await submoduleEffectiveConfiguration() == plan.effectiveConfig,
            try submoduleDestinationParents(path: plan.path) == plan.destinationParents
        else { throw ModelFailure.changed }
        try await verifyRecoverySharedIndex(plan.sharedIndex)
        try await RecoveryFileIO.verifyAll([plan.gitmodules], location: location)
        try await verifySubmoduleChild(plan.child, path: plan.path)
        if let remote = plan.childRemote {
            guard try submoduleConfigurationSnapshot(at: remote.location) == remote.config,
                try RepositoryNodeIdentity.read(remote.location.commonDirectory.appending(path: "config"))
                    == remote.configIdentity,
                try await submoduleEffectiveConfiguration(at: remote.location) == remote.effectiveConfig
            else { throw ModelFailure.changed }
        }
    }

    private func prepareSubmoduleChildRemote(_ child: SubmoduleChildSnapshot, source: String) async throws
        -> SubmoduleChildRemoteSnapshot
    {
        guard let target = child.location, !child.retention.invalid,
            target.commonIdentity != location.commonIdentity
        else { throw ModelFailure.changed }
        if let branch = child.branch, branch.hasPrefix("refs/heads/") {
            let remote = try await engine.run(
                ["config", "--get", "branch." + String(branch.dropFirst(11)) + ".remote"],
                in: target.root, accepted: [0, 1], outputLimit: 65536
            ).text.removingLastNewline
            guard remote.isEmpty || remote == "origin" else {
                throw ModelFailure.unsupported(L10n.text("子仓库当前分支使用其他远端，请先在子仓库明确更新来源。"))
            }
        }
        let result = try await engine.run(
            ["config", "--null", "--show-scope", "--show-origin", "--get-all", "remote.origin.url"],
            in: target.root, accepted: [0, 1], outputLimit: 65536
        ).stdout
        let records = result.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard records.count == 3, records[0] == "local", records[1].hasPrefix("file:"),
            URL(fileURLWithPath: String(records[1].dropFirst(5)), relativeTo: target.root).standardizedFileURL
                .path
                == target.commonDirectory.appending(path: "config").path
        else {
            throw ModelFailure.unsupported(L10n.text("子仓库 origin 必须是当前仓库配置中的单一 URL；继承或多地址来源需在子仓库处理。"))
        }
        let identity = try RepositoryNodeIdentity.read(target.commonDirectory.appending(path: "config"))
        let config = try submoduleConfigurationSnapshot(at: target)
        let effective = try await submoduleEffectiveConfiguration(at: target)
        let after = try ResourceRuleDocument.moduleKeys(
            config.bytes ?? Data(), name: "origin", updates: ["url": source], section: "remote")
        try await submoduleValidateDocument(
            after, name: "origin", expected: ["url": source], section: "remote")
        guard try RepositoryNodeIdentity.read(target.commonDirectory.appending(path: "config")) == identity
        else { throw ModelFailure.changed }
        return SubmoduleChildRemoteSnapshot(
            location: target, config: config, configIdentity: identity,
            effectiveConfig: effective, source: records[2], after: after)
    }

    private func submoduleUnchangedChildConfiguration(_ bytes: Data, at target: RepositoryLocation) throws
        -> Data
    {
        let fields = bytes.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.last?.isEmpty == true, (fields.count - 1).isMultiple(of: 3) else {
            throw ModelFailure.changed
        }
        var result = Data()
        for index in stride(from: 0, to: fields.count - 1, by: 3) {
            let key =
                String(decoding: fields[index + 2], as: UTF8.self).components(separatedBy: "\n").first ?? ""
            if key == "remote.origin.url" {
                let origin = String(decoding: fields[index + 1], as: UTF8.self)
                guard String(decoding: fields[index], as: UTF8.self) == "local", origin.hasPrefix("file:"),
                    URL(fileURLWithPath: String(origin.dropFirst(5)), relativeTo: target.root)
                        .standardizedFileURL.path
                        == target.commonDirectory.appending(path: "config").path
                else { throw ModelFailure.changed }
                continue
            }
            for offset in 0..<3 {
                result.append(contentsOf: fields[index + offset])
                result.append(0)
            }
        }
        return result
    }

    func submoduleChild(path: String) async throws -> SubmoduleChildSnapshot {
        let childURL = location.root.appending(path: path)
        let parents = try submoduleDestinationParents(path: path)
        _ = parents
        let directory = try RepositoryNodeIdentity.readIfPresent(childURL)
        guard directory == nil || directory?.kind == UInt16(S_IFDIR) else { throw ModelFailure.invalidPath }
        let marker = try RepositoryNodeIdentity.readIfPresent(childURL.appending(path: ".git"))
        guard marker?.kind != UInt16(S_IFLNK) else { throw ModelFailure.invalidPath }
        var childLocation: RepositoryLocation?
        var head: String?
        var branch: String?
        var index: SelectedIndexSnapshot?
        var status: Data?
        var nested: [String] = []
        var locks: [String] = []
        var independent: Int?
        var invalid = false
        if marker != nil {
            do {
                let discovered = try await Self.discover(childURL, engine: engine)
                guard discovered.root.path == childURL.path else { throw ModelFailure.changed }
                childLocation = discovered
                head = try await engine.run(
                    ["rev-parse", "--verify", "HEAD"], in: childURL, accepted: [0, 128]
                ).text.removingLastNewline
                if head?.isEmpty == true { head = nil }
                branch = try await engine.run(
                    ["symbolic-ref", "--quiet", "HEAD"], in: childURL, accepted: [0, 1]
                ).text.removingLastNewline
                index = try SelectedIndexSnapshot.read(location: discovered)
                status = try await engine.run(
                    ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=matching"],
                    in: childURL, outputLimit: 4 * 1024 * 1024
                ).stdout
                let entries = try await engine.run(
                    ["ls-files", "--stage", "-z"], in: childURL, outputLimit: 8 * 1024 * 1024
                ).stdout
                nested = entries.split(separator: 0).compactMap { row in
                    guard row.starts(with: Data("160000 ".utf8)), let tab = row.firstIndex(of: 9) else {
                        return nil
                    }
                    return String(data: row[row.index(after: tab)...], encoding: .utf8)
                }
                guard nested.count <= 512 else { throw RecoveryBudget.exceeded }
                for name in [
                    "index.lock", "HEAD.lock", "packed-refs.lock", "config.lock", "shallow.lock",
                    "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply",
                    "sequencer",
                ] {
                    for directory in Set([discovered.gitDirectory, discovered.commonDirectory]) {
                        if try RepositoryNodeIdentity.readIfPresent(directory.appending(path: name)) != nil {
                            locks.append(directory.appending(path: name).path)
                        }
                    }
                }
                if head != nil {
                    let commits = try await engine.run(
                        ["rev-list", "--max-count=1", "--all", "--not", "--remotes"], in: childURL,
                        outputLimit: 65536
                    ).text.removingLastNewline
                    independent = commits.isEmpty ? 0 : 1
                }
                try discovered.validateIdentity()
            } catch is CancellationError { throw CancellationError() } catch ProcessFailure.cancelled {
                throw ProcessFailure.cancelled
            } catch { invalid = true }
        }
        let records = status?.split(separator: 0) ?? []
        let retention = SubmoduleRetention(
            files: childURL, gitData: childLocation?.commonDirectory,
            initialized: marker != nil,
            dirty: records.contains { $0.first == 49 || $0.first == 50 || $0.first == 117 },
            untracked: records.contains { $0.first == 63 }, ignored: records.contains { $0.first == 33 },
            independentCommits: independent, nestedPaths: nested, locks: locks.sorted(), invalid: invalid)
        return SubmoduleChildSnapshot(
            location: childLocation, directory: directory, marker: marker, head: head,
            branch: branch, index: index, status: status, retention: retention)
    }

    private func verifySubmoduleChild(_ expected: SubmoduleChildSnapshot, path: String) async throws {
        let actual = try await submoduleChild(path: path)
        guard actual.directory == expected.directory, actual.marker == expected.marker,
            actual.location == expected.location, actual.head == expected.head,
            actual.branch == expected.branch,
            actual.index == expected.index, actual.status == expected.status,
            actual.retention.locks == expected.retention.locks,
            actual.retention.independentCommits == expected.retention.independentCommits,
            actual.retention.invalid == expected.retention.invalid
        else { throw ModelFailure.changed }
    }

    private func submoduleDestinationParents(path: String) throws -> [ConflictEditorDirectoryIdentity] {
        try location.validateIdentity()
        var descriptor = Darwin.open(location.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ModelFailure.changed }
        defer { Darwin.close(descriptor) }
        var result: [ConflictEditorDirectoryIdentity] = []
        for component in [""] + path.split(separator: "/").dropLast().map(String.init) {
            if !component.isEmpty {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ModelFailure.invalidPath }
                Darwin.close(descriptor)
                descriptor = next
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw ModelFailure.changed }
            result.append(
                ConflictEditorDirectoryIdentity(
                    device: UInt64(info.st_dev), inode: info.st_ino,
                    bornSeconds: Int64(info.st_birthtimespec.tv_sec),
                    bornNanoseconds: Int64(info.st_birthtimespec.tv_nsec)))
        }
        return result
    }

    private func submoduleInstallDownload(
        _ source: URL, plan: SubmoduleChangePlan, storage: SubmoduleChangeStorage, clone: RepositoryLocation
    ) throws {
        try location.validateIdentity()
        try clone.validateIdentity()
        try storage.validate()
        var descriptor = Darwin.open(location.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ModelFailure.changed }
        defer { Darwin.close(descriptor) }
        let components = [""] + plan.path.split(separator: "/").dropLast().map(String.init)
        guard components.count == plan.destinationParents.count else { throw ModelFailure.changed }
        for (index, component) in components.enumerated() {
            if !component.isEmpty {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ModelFailure.changed }
                Darwin.close(descriptor)
                descriptor = next
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                ConflictEditorDirectoryIdentity(
                    device: UInt64(info.st_dev), inode: info.st_ino,
                    bornSeconds: Int64(info.st_birthtimespec.tv_sec),
                    bornNanoseconds: Int64(info.st_birthtimespec.tv_nsec))
                    == plan.destinationParents[index]
            else { throw ModelFailure.changed }
        }
        let sourceParent = try storage.open()
        defer { Darwin.close(sourceParent) }
        var input = stat()
        var target = stat()
        let leaf = plan.retention.files.lastPathComponent
        guard fstatat(sourceParent, source.lastPathComponent, &input, AT_SYMLINK_NOFOLLOW) == 0,
            input.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR), input.st_dev == clone.rootIdentity.device,
            input.st_ino == clone.rootIdentity.inode,
            fstatat(descriptor, leaf, &target, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
            try submoduleDestinationParents(path: plan.path) == plan.destinationParents
        else { throw ModelFailure.changed }
        guard
            renameatx_np(
                sourceParent, source.lastPathComponent, descriptor, leaf, UInt32(RENAME_EXCL)
            ) == 0,
            fsync(descriptor) == 0, fsync(sourceParent) == 0
        else { throw ProcessFailure.outputWrite(errno) }
        guard fstatat(descriptor, leaf, &target, AT_SYMLINK_NOFOLLOW) == 0,
            target.st_dev == input.st_dev, target.st_ino == input.st_ino,
            try submoduleDestinationParents(path: plan.path) == plan.destinationParents
        else { throw ModelFailure.changed }
        try storage.validate()
    }

    private func submoduleSaveBytes(_ bytes: Data, at url: URL, storage: SubmoduleChangeStorage) throws {
        try storage.validate()
        let parent = try storage.open()
        defer { Darwin.close(parent) }
        let descriptor = openat(
            parent, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ProcessFailure.outputWrite(errno) }
        defer { Darwin.close(descriptor) }
        try RecoveryFileIO.write(bytes, descriptor: descriptor, cancellation: IOCancellation())
        guard fsync(descriptor) == 0, fsync(parent) == 0 else { throw ProcessFailure.outputWrite(errno) }
        try storage.validate()
    }

    private func saveSubmoduleReceipt(_ receipt: SubmoduleChangeReceipt, storage: SubmoduleChangeStorage)
        throws
    {
        let directory = receipt.receiptFile.deletingLastPathComponent()
        try storage.validate()
        let descriptor = try storage.open()
        defer { Darwin.close(descriptor) }
        let temporary = directory.appending(path: "module-receipt-" + UUID().uuidString)
        try submoduleSaveBytes(try JSONEncoder().encode(receipt), at: temporary, storage: storage)
        guard
            renameat(
                descriptor, temporary.lastPathComponent, descriptor, receipt.receiptFile.lastPathComponent)
                == 0,
            fsync(descriptor) == 0
        else { throw ProcessFailure.outputWrite(errno) }
        try storage.validate()
    }
}

private final class SubmoduleChangeStorage: @unchecked Sendable {
    let location: RepositoryLocation
    let url: URL
    let parentURL: URL
    let identity: RepositoryNodeIdentity
    let parentIdentity: RepositoryNodeIdentity
    init(location: RepositoryLocation, id: UUID) throws {
        self.location = location
        let git = try SelectedIndexSnapshot.openDirectory(location)
        defer { Darwin.close(git) }
        let name = "wegit-submodule-changes"
        if mkdirat(git, name, 0o700) != 0, errno != EEXIST { throw ProcessFailure.outputWrite(errno) }
        let parent = openat(git, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ModelFailure.changed }
        defer { Darwin.close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw ModelFailure.changed
        }
        parentURL = location.gitDirectory.appending(path: name)
        parentIdentity = try RepositoryNodeIdentity.read(parentURL, directory: true)
        guard try FileManager.default.contentsOfDirectory(atPath: parentURL.path).count < 20 else {
            throw ModelFailure.unsupported(L10n.text("子模块回执达到保存上限，请先在回执目录导出并核对；不会自动清理子仓库数据。"))
        }
        guard mkdirat(parent, id.uuidString, 0o700) == 0, fsync(parent) == 0, fsync(git) == 0 else {
            throw ProcessFailure.outputWrite(errno)
        }
        url = parentURL.appending(path: id.uuidString)
        identity = try RepositoryNodeIdentity.read(url, directory: true)
    }
    func open() throws -> Int32 {
        try validate()
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ModelFailure.changed }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_dev == identity.device, info.st_ino == identity.inode
        else {
            Darwin.close(descriptor)
            throw ModelFailure.changed
        }
        return descriptor
    }
    func validate() throws {
        try location.validateIdentity()
        guard try RepositoryNodeIdentity.read(parentURL, directory: true) == parentIdentity,
            try RepositoryNodeIdentity.read(url, directory: true) == identity
        else { throw ModelFailure.changed }
    }
}
