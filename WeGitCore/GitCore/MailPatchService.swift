import Darwin
import Foundation

extension RepositoryService {
    @concurrent public func exportMailPatches(_ targets: [String]) async throws -> Data {
        guard !targets.isEmpty, targets.count <= 100, targets.allSatisfy(GitObjectID.valid) else {
            throw RecoveryBudget.exceeded
        }
        try location.validateIdentity()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        func remainingTime() throws -> Double {
            let duration = ContinuousClock.now.duration(to: deadline).components
            let remaining = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            guard remaining > 0 else {
                throw ModelFailure.unsupported(L10n.text("提交邮件导出超过时间上限，请缩小提交范围。"))
            }
            return remaining
        }
        var data = Data()
        for target in targets {
            try Task.checkCancellation()
            let parents = try await singleCommitEngine.run(
                ["rev-list", "--parents", "-n", "1", target], in: location.root,
                timeout: min(5, try remainingTime()), outputLimit: 4096
            ).text.split(whereSeparator: \.isWhitespace)
            guard parents.first.map(String.init) == target, parents.count <= 2 else {
                throw ModelFailure.unsupported(L10n.text("邮件补丁不能保留 Merge 的多个父提交，请选择普通提交。"))
            }
            let output = try await singleCommitEngine.run(
                [
                    "format-patch", "--stdout", "--binary", "--full-index", "--root", "--no-zero-commit",
                    "--no-ext-diff", "--no-textconv", "--no-color", "-1", target, "--",
                ], in: location.root, timeout: min(30, try remainingTime()),
                outputLimit: PatchReadBudget.bytes - data.count, literalPathspecs: false
            ).stdout
            guard !output.isEmpty, output.count <= PatchReadBudget.bytes - data.count else {
                throw RecoveryBudget.exceeded
            }
            data.append(output)
        }
        try location.validateIdentity()
        return data
    }

    @concurrent public func mailPatchRecord() async throws -> MailPatchRecord? {
        try await SnapshotIO.run { _ in try MailPatchStore.existingRecord(location: location) }
    }

    public func inspectMailPatches(_ expected: MailPatchRecord) async throws -> MailPatchRecord {
        try await withSharedOperation {
            let store = try MailPatchStore(location: location)
            guard try MailPatchStore.existingRecord(location: location) == expected else {
                throw ModelFailure.changed
            }
            guard expected.phase.pending else { return expected }
            let state = try await status()
            let native = try? await mailNativeState()
            var record = expected
            if state.branch == expected.branch, state.sequencer == .mailApply,
                let native, native.belongs(to: expected)
            {
                record.phase = .waiting
                record.next = native.next - 1
                record.nativeToken = native.token
                record.expectedIndexSHA256 = try SelectedIndexSnapshot.read(location: location).bytes.map(
                    RecoveryFileIO.hash)
                record.expectedConfigurationSHA256 = try await mailExecutionConfiguration()
            } else if state.branch == expected.branch, state.sequencer == .none,
                state.files.isEmpty, native == nil,
                (try? await completedMailMatches(record, head: state.head)) == true
            {
                record.phase = .completed
                record.next = record.entries.count
                record.nativeToken = nil
                record.expectedIndexSHA256 = nil
                record.details = nil
            } else {
                record.phase = .needsVerification
                record.nativeToken = nil
                record.expectedIndexSHA256 = nil
                record.details = L10n.text("提交补丁结果无法完整核对，请检查仓库后再操作。")
            }
            if record != expected { try store.save(record, expected: expected) }
            return record
        }
    }

    public func dismissMailPatches(_ expected: MailPatchRecord) async throws {
        try await withSharedOperation {
            let store = try MailPatchStore(location: location)
            let state = try await status()
            guard try MailPatchStore.existingRecord(location: location) == expected,
                expected.phase == .needsVerification, state.branch == expected.branch,
                state.sequencer == .none, try await mailNativeState() == nil
            else { throw ModelFailure.changed }
            var record = expected
            record.phase = .dismissed
            record.nativeToken = nil
            try store.save(record, expected: expected)
            try store.close(record)
        }
    }

    func mailConflictOperationSnapshot(_ state: RepositoryStatus) async throws
        -> ConflictEditorOperationSnapshot
    {
        guard let record = state.mailPatch, record.phase == .waiting,
            state.branch == record.branch, let native = try await mailNativeState(),
            native.belongs(to: record), native.token == record.nativeToken
        else { throw ModelFailure.changed }
        return .mailPatch(record.id, native.token)
    }

    public func closeMailPatches(_ expected: MailPatchRecord) async throws {
        try await withSharedOperation {
            guard try await mailNativeState() == nil else { throw ModelFailure.changed }
            let store = try MailPatchStore(location: location)
            try store.close(expected)
        }
    }

    @concurrent public func prepareMailPatches(_ sources: [MailPatchSource]) async throws -> MailPatchPlan {
        guard !sources.isEmpty, sources.count <= 100,
            sources.allSatisfy({ !$0.bytes.isEmpty && $0.bytes.count <= PatchReadBudget.bytes })
        else { throw RecoveryBudget.exceeded }
        let configuration = try await mailExecutionConfiguration()
        var total = 0
        for source in sources {
            guard source.bytes.count <= PatchReadBudget.bytes - total else { throw RecoveryBudget.exceeded }
            total += source.bytes.count
        }
        let storage = try await SnapshotIO.run { _ in try SnapshotDirectory() }
        let split = storage.url.appending(path: "mails")
        try await SnapshotIO.run { _ in
            try FileManager.default.createDirectory(
                at: split, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var inputs: [URL] = []
        for (index, source) in sources.enumerated() {
            let file = storage.url.appending(path: "input-\(index).mbox")
            try source.bytes.write(to: file)
            inputs.append(file)
        }
        let count = try await singleCommitEngine.run(
            ["mailsplit", "--mboxrd", "--keep-cr", "-d4", "-o" + split.path, "--"] + inputs.map(\.path),
            in: location.root, outputLimit: 4096, literalPathspecs: false
        ).text.removingLastNewline
        guard let number = Int(count), (1...100).contains(number) else { throw RecoveryBudget.exceeded }
        var entries: [MailPatchEntry] = []
        var mails: [URL] = []
        var paths: Set<String> = []
        for index in 1...number {
            try Task.checkCancellation()
            let file = split.appending(path: String(format: "%04d", index))
            let mail = try Data(contentsOf: file)
            let message = storage.url.appending(path: "message-\(index)")
            let patch = storage.url.appending(path: "patch-\(index)")
            let info = try await singleCommitEngine.run(
                ["mailinfo", "--encoding=UTF-8", message.path, patch.path], in: location.root,
                input: mail, outputLimit: 64 * 1024, literalPathspecs: false)
            var headers: [String: String] = [:]
            for row in info.text.split(separator: "\n") {
                guard let colon = row.firstIndex(of: ":") else { continue }
                headers[String(row[..<colon])] = row[row.index(after: colon)...].trimmingCharacters(
                    in: .whitespaces)
            }
            guard let author = headers["Author"], let email = headers["Email"],
                let subject = headers["Subject"],
                !author.isEmpty, !email.isEmpty, subject.utf8.count <= 4096,
                !subject.contains("\0"), !author.contains("\0"), !email.contains("\0")
            else { throw ModelFailure.invalidPath }
            let data = try Data(contentsOf: patch)
            guard !data.isEmpty, data.count <= PatchReadBudget.bytes else { throw RecoveryBudget.exceeded }
            let messageBytes = try Data(contentsOf: message)
            guard messageBytes.count <= 64 * 1024,
                let body = String(data: messageBytes, encoding: .utf8), !body.contains("\0"),
                author.utf8.count <= 4096, email.utf8.count <= 4096,
                (headers["Date"]?.utf8.count ?? 0) <= 4096
            else { throw RecoveryBudget.exceeded }
            let stat = try await singleCommitEngine.run(
                ["apply", "--numstat", "-z", "--binary", "-"],
                in: location.root, input: data, outputLimit: 1024 * 1024)
            let files = try parsePatchFiles(stat.stdout, patch: data)
            let names = Set(files.flatMap { [$0.path, $0.oldPath].compactMap { $0 } })
            paths.formUnion(names)
            guard paths.count <= PatchReadBudget.files else { throw RecoveryBudget.exceeded }
            entries.append(
                MailPatchEntry(
                    number: index, subject: subject, author: author, email: email,
                    body: body.isEmpty ? nil : body, authorDate: headers["Date"],
                    paths: names.sorted(), sha256: RecoveryFileIO.hash(mail)))
            mails.append(file)
        }
        let frozenEntries = entries
        guard try JSONEncoder().encode(entries).count <= 2 * 1024 * 1024 - 16 * 1024 else {
            throw RecoveryBudget.exceeded
        }
        let frozenPaths = paths.sorted()
        let frozenMails = mails
        return try await queue.perform {
            guard try await mailPatchRecord() == nil, try await commitQueue() == nil else {
                throw ModelFailure.changed
            }
            let index = try SelectedIndexSnapshot.read(location: location)
            let shared = try await captureRecoverySharedIndex(index)
            let tracked = try await stashIndexFiles()
            let metadata = try await RecoveryFileIO.metadataAll(location: location, paths: tracked.sorted())
            let state = try await status()
            guard state.sequencer == .none, state.files.isEmpty else {
                throw ModelFailure.unsupported(L10n.text("导入提交补丁前，请先提交或保存工作区改动。"))
            }
            try await StashWorktreeGuard.validate(
                paths: Set(frozenPaths), tracked: tracked, location: location)
            try await validatePatchFilters(frozenPaths)
            let captures = try await captureRecoveryFiles(
                frozenPaths,
                limit: RecoveryBudget.bytes - (index.bytes?.count ?? 0) - (shared?.data.count ?? 0))
            try await RecoveryFileIO.verifyMetadataAll(metadata, location: location)
            try await RecoveryFileIO.verifyAll(captures, location: location)
            guard try SelectedIndexSnapshot.read(location: location) == index,
                try await mailExecutionConfiguration() == configuration
            else {
                throw ModelFailure.changed
            }
            return MailPatchPlan(
                entries: frozenEntries, branch: state.branch, head: state.head, paths: frozenPaths,
                location: location, index: index, sharedIndex: shared, metadata: metadata,
                captures: captures, storage: storage, mails: frozenMails, configurationSHA256: configuration)
        }
    }

    public func executeMailPatches(_ plan: MailPatchPlan) async throws -> MailPatchRecord {
        try await withSharedOperation {
            guard plan.location == location, try await mailPatchRecord() == nil,
                try await commitQueue() == nil,
                try await mailExecutionConfiguration() == plan.configurationSHA256
            else {
                throw ModelFailure.changed
            }
            let context = try await recoveryContext()
            guard context.head == plan.head, context.branch == plan.branch,
                try SelectedIndexSnapshot.read(location: location) == plan.index
            else { throw ModelFailure.changed }
            try await RecoveryFileIO.verifyMetadataAll(plan.metadata, location: location)
            try await RecoveryFileIO.verifyAll(plan.captures, location: location)
            try await verifyRecoverySharedIndex(plan.sharedIndex)
            let recovery = try RecoveryStore(location: location)
            try await trimRecovery(recovery)
            var backup = try await recovery.persist(
                operation: "git-am", head: plan.head, branch: plan.branch,
                target: nil, index: plan.index, files: plan.captures, sharedIndex: plan.sharedIndex)
            backup.indexTree = try await recoveryIndexTree(
                plan.index.bytes, shared: plan.sharedIndex, persist: true)
            try recovery.save(backup)
            try await protectRecovery(backup)
            let store = try MailPatchStore(location: location)
            let id = UUID()
            let mails = try store.persistMails(plan, id: id)
            let record = MailPatchRecord(
                format: 1, id: id, workspaceID: location.persistenceID,
                originalHead: plan.head, branch: plan.branch, entries: plan.entries, recoveryID: backup.id,
                phase: .running, next: 0, skipped: nil, expectedIndexSHA256: nil,
                expectedConfigurationSHA256: plan.configurationSHA256, nativeToken: nil, details: nil)
            try store.save(record, expected: nil)
            let final = try await recoveryContext()
            guard final.head == plan.head, final.branch == plan.branch,
                try SelectedIndexSnapshot.read(location: location) == plan.index,
                try await mailExecutionConfiguration() == plan.configurationSHA256
            else {
                throw ModelFailure.changed
            }
            try await RecoveryFileIO.verifyMetadataAll(plan.metadata, location: location)
            try await RecoveryFileIO.verifyAll(plan.captures, location: location)
            try await verifyRecoverySharedIndex(plan.sharedIndex)
            try await validatePatchFilters(plan.paths)
            var failure: (any Error)?
            do {
                _ = try await singleCommitEngine.run(
                    ["am", "--3way", "--keep-cr", "--"] + mails.map(\.path),
                    in: location.root, timeout: 120, literalPathspecs: false)
            } catch { failure = error }
            let result = try await observeMailPatch(record, store: store, failure: failure)
            await updateMailBackup(result)
            return result
        }
    }

    public func recoverMailPatches(_ expected: MailPatchRecord, action: String) async throws
        -> MailPatchRecord
    {
        guard ["continue", "skip", "abort"].contains(action) else { throw ModelFailure.invalidPath }
        return try await withSharedOperation {
            let store = try MailPatchStore(location: location)
            guard try MailPatchStore.existingRecord(location: location) == expected,
                expected.phase == .waiting,
                let native = try await mailNativeState(), native.token == expected.nativeToken,
                native.belongs(to: expected), native.next == expected.next + 1
            else { throw ModelFailure.changed }
            let state = try await status()
            guard state.branch == expected.branch,
                action != "continue" || state.conflicts.isEmpty
            else { throw ModelFailure.changed }
            let index = try SelectedIndexSnapshot.read(location: location)
            if action == "continue" {
                guard expected.expectedIndexSHA256 == index.bytes.map(RecoveryFileIO.hash) else {
                    throw ModelFailure.changed
                }
            }
            if action != "abort" {
                guard expected.expectedConfigurationSHA256 == (try await mailExecutionConfiguration()) else {
                    throw ModelFailure.changed
                }
                try await validatePatchFilters(
                    Array(Set(expected.entries.dropFirst(expected.next).flatMap(\.paths))).sorted())
            }
            if action == "skip" || action == "abort" {
                try await preserveInterruptedChanges(
                    operation: "git-am-interruption-backup", state: state, preserving: expected.recoveryID)
            }
            guard try SelectedIndexSnapshot.read(location: location) == index,
                try await mailNativeState()?.token == expected.nativeToken,
                try await head() == state.head
            else { throw ModelFailure.changed }
            if action != "abort" {
                guard expected.expectedConfigurationSHA256 == (try await mailExecutionConfiguration()) else {
                    throw ModelFailure.changed
                }
            }
            var failure: (any Error)?
            do {
                _ = try await singleCommitEngine.run(
                    ["am", "--" + action], in: location.root, timeout: 120, literalPathspecs: false)
            } catch { failure = error }
            var result = try await observeMailPatch(
                expected, store: store, failure: failure, skipping: action == "skip" ? expected.next : nil)
            if action == "abort", failure == nil, try await mailNativeState() == nil {
                let previous = result
                result.phase = try await head() == expected.originalHead ? .aborted : .needsVerification
                result.next = expected.next
                try store.save(result, expected: previous)
            }
            await updateMailBackup(result)
            return result
        }
    }

    private func observeMailPatch(
        _ old: MailPatchRecord, store: MailPatchStore, failure: (any Error)?, skipping: Int? = nil
    )
        async throws -> MailPatchRecord
    {
        var record = old
        let observation = await Task.detached {
            () -> (RepositoryStatus?, MailPatchNativeState?, String?, SelectedIndexSnapshot?) in
            let status = try? await self.status()
            let native = try? await self.mailNativeState()
            let configuration = try? await self.mailExecutionConfiguration()
            let index = try? SelectedIndexSnapshot.read(location: self.location)
            return (status, native, configuration, index)
        }.value
        guard let state = observation.0, state.branch == record.branch else {
            record.phase = .needsVerification
            record.nativeToken = nil
            record.expectedIndexSHA256 = nil
            record.details = L10n.text("提交补丁结果无法完整核对，请检查仓库后再操作。")
            try? store.save(record, expected: old)
            return record
        }
        let configurationUnchanged =
            observation.2 != nil
            && (old.expectedConfigurationSHA256 == nil || old.expectedConfigurationSHA256 == observation.2)
        if let skipping,
            failure == nil
                || (observation.1?.belongs(to: old) == true && observation.1!.next > old.next + 1)
        {
            record.skipped = Array(Set((record.skipped ?? []) + [skipping])).sorted()
        }
        if let native = observation.1, native.belongs(to: record), state.sequencer == .mailApply,
            configurationUnchanged, let index = observation.3
        {
            record.phase = .waiting
            record.next = native.next - 1
            record.nativeToken = native.token
            record.expectedIndexSHA256 = index.bytes.map(RecoveryFileIO.hash)
            record.expectedConfigurationSHA256 = observation.2
        } else {
            let frozen = record
            let matches = await Task.detached {
                (try? await self.completedMailMatches(frozen, head: state.head)) == true
            }.value
            record.phase =
                failure == nil && state.sequencer == .none && state.files.isEmpty
                    && configurationUnchanged && matches ? .completed : .needsVerification
            if record.phase == .completed { record.next = record.entries.count }
            record.nativeToken = nil
            record.expectedIndexSHA256 = nil
        }
        record.details = failure.map {
            String(Redaction.text(($0 as? GitFailure)?.details ?? $0.localizedDescription).prefix(8192))
        }
        try store.save(record, expected: old)
        return record
    }

    private func updateMailBackup(_ record: MailPatchRecord) async {
        await Task.detached {
            guard let store = try? RecoveryStore(location: self.location),
                var backup = try? store.record(record.recoveryID)
            else { return }
            backup.state = record.phase == .needsVerification ? .needsVerification : .succeeded
            backup.details = record.details
            backup.observedHead = try? await self.head()
            try? store.save(backup)
        }.value
    }

    private func completedMailMatches(_ record: MailPatchRecord, head: String?) async throws -> Bool {
        let skipped = Set(record.skipped ?? [])
        let expected = record.entries.enumerated().filter { !skipped.contains($0.offset) }.map(\.element)
        if expected.isEmpty { return head == record.originalHead }
        guard let head, GitObjectID.valid(head) else { return false }
        var arguments = [
            "log", "-z", "--no-show-signature", "--no-decorate", "--no-notes", "--reverse",
            "--first-parent", "--max-count=101", "--format=%H%x00%an%x00%ae%x00%B", head,
        ]
        if let original = record.originalHead {
            let ancestor = try await singleCommitEngine.run(
                ["merge-base", "--is-ancestor", original, head], in: location.root, accepted: [0, 1])
            guard ancestor.exitCode == 0 else { return false }
            arguments += ["--not", original]
        }
        let data = try await singleCommitEngine.run(
            arguments, in: location.root, outputLimit: 2 * 1024 * 1024
        ).stdout
        guard data.last == 0 else { return false }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count == expected.count * 4 + 1 else { return false }
        for (index, entry) in expected.enumerated() {
            let offset = index * 4
            guard String(data: Data(fields[offset + 1]), encoding: .utf8) == entry.author,
                String(data: Data(fields[offset + 2]), encoding: .utf8) == entry.email,
                let message = String(data: Data(fields[offset + 3]), encoding: .utf8)
            else { return false }
            let wanted = entry.subject + (entry.body.map { "\n\n" + $0 } ?? "\n")
            guard message == wanted else { return false }
        }
        return try await self.head() == head
    }

    private func mailExecutionConfiguration() async throws -> String {
        let pattern =
            "^(user\\.(name|email|signingkey)|commit\\.(gpgsign|cleanup)|gpg\\..*|core\\.(hookspath|autocrlf|safecrlf|eol|filemode|attributesfile)|am\\..*|apply\\..*|mailinfo\\..*|i18n\\..*)$"
        let data = try await singleCommitEngine.run(
            ["config", "--null", "--show-origin", "--show-scope", "--get-regexp", pattern],
            in: location.root, accepted: [0, 1], outputLimit: 256 * 1024, literalPathspecs: false
        ).stdout
        return RecoveryFileIO.hash(data)
    }

    private func mailNativeState() async throws -> MailPatchNativeState? {
        try await SnapshotIO.run { cancellation in
            let root = try SelectedIndexSnapshot.openDirectory(location)
            defer { Darwin.close(root) }
            let directory = openat(root, "rebase-apply", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if directory < 0 {
                guard errno == ENOENT else { throw ModelFailure.changed }
                return nil
            }
            defer { Darwin.close(directory) }
            var applying = stat()
            guard fstatat(directory, "applying", &applying, AT_SYMLINK_NOFOLLOW) == 0,
                applying.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG)
            else { throw ModelFailure.changed }
            var rebasing = stat()
            guard fstatat(directory, "rebasing", &rebasing, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT else {
                throw ModelFailure.changed
            }
            func readAt(_ folder: Int32, _ name: String, limit: Int) throws -> Data {
                try cancellation.check()
                let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                if fd < 0 {
                    guard errno == ENOENT else { throw ModelFailure.changed }
                    return Data()
                }
                defer { Darwin.close(fd) }
                var before = stat()
                guard fstat(fd, &before) == 0, before.st_size >= 0, before.st_size <= limit,
                    before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG)
                else { throw ModelFailure.changed }
                let bytes =
                    try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1)
                    ?? Data()
                var after = stat()
                var named = stat()
                guard fstat(fd, &after) == 0, SnapshotFileStamp(before) == SnapshotFileStamp(after),
                    fstatat(folder, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                    SnapshotFileStamp(after) == SnapshotFileStamp(named),
                    bytes.count == before.st_size
                else { throw ModelFailure.changed }
                return bytes
            }
            func read(_ name: String, limit: Int) throws -> Data {
                try readAt(directory, name, limit: limit)
            }
            let nextData = try read("next", limit: 64)
            let lastData = try read("last", limit: 64)
            guard
                let next = Int(
                    String(decoding: nextData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                let total = Int(
                    String(decoding: lastData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                (1...100).contains(total), (1...total).contains(next)
            else { throw ModelFailure.changed }
            var info = stat()
            guard fstat(directory, &info) == 0 else { throw ModelFailure.changed }
            var token = Data(
                "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
                    .utf8)
            let original = try readAt(root, "ORIG_HEAD", limit: 128)
            let originalHead =
                original.isEmpty
                ? nil
                : String(data: original, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard original.isEmpty || (originalHead.map(GitObjectID.valid) ?? false) else {
                throw ModelFailure.changed
            }
            token.append(original)
            token.append(0)
            var mailHashes: [String] = []
            var totalBytes = 0
            for number in 1...total {
                let mail = try read(String(format: "%04d", number), limit: PatchReadBudget.bytes - totalBytes)
                guard !mail.isEmpty else { throw ModelFailure.changed }
                totalBytes += mail.count
                let digest = RecoveryFileIO.hash(mail)
                mailHashes.append(digest)
                token.append(Data(digest.utf8))
            }
            for name in [
                "next", "last", "abort-safety", "original-commit", "patch", "author-script", "final-commit",
            ] {
                token.append(Data(name.utf8))
                token.append(0)
                token.append(try read(name, limit: name == "patch" ? 32 * 1024 * 1024 : 1024 * 1024))
                token.append(0)
            }
            var namedDirectory = stat()
            guard try read("next", limit: 64) == nextData, try read("last", limit: 64) == lastData,
                fstatat(root, "rebase-apply", &namedDirectory, AT_SYMLINK_NOFOLLOW) == 0,
                namedDirectory.st_dev == info.st_dev, namedDirectory.st_ino == info.st_ino,
                namedDirectory.st_birthtimespec.tv_sec == info.st_birthtimespec.tv_sec,
                namedDirectory.st_birthtimespec.tv_nsec == info.st_birthtimespec.tv_nsec
            else { throw ModelFailure.changed }
            try location.validateIdentity()
            return MailPatchNativeState(
                next: next, total: total, token: RecoveryFileIO.hash(token),
                originalHead: originalHead, mailHashes: mailHashes)
        }
    }
}
