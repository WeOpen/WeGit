import Darwin
import Foundation

private struct ConflictIndexEntry: Equatable {
    let mode: String
    let object: String
    let stage: Int
    let path: String
}

extension RepositoryService {
    public func readConflictEditor(path: String, expectedHead: String? = nil) async throws
        -> ConflictEditorDocument
    {
        try await queue.perform {
            try await self.readConflictEditorDirect(path: path, expectedHead: expectedHead)
        }
    }

    public func saveConflictResult(_ document: ConflictEditorDocument, text: String)
        async throws -> ConflictEditorDocument
    {
        try await queue.perform {
            guard !text.utf8.contains(0), let bytes = text.data(using: .utf8),
                bytes.count <= ConflictEditorBudget.bytes
            else { throw ModelFailure.unsupported(L10n.text("结果必须是有限大小的 UTF-8 文本。")) }
            try await self.verifyHead(document.head)
            try await self.verifyConflictDocument(document)
            let state = try await self.status()
            guard state.conflicts.contains(where: { $0.path == document.path }) else {
                throw ModelFailure.changed
            }
            let currentIndex = try await self.conflictIndexListing()
            guard currentIndex == document.indexListing else { throw ModelFailure.changed }
            let currentEntry = try await self.conflictEntryListing(path: document.path)
            guard currentEntry == document.entryListing else { throw ModelFailure.changed }
            let currentResult = try await self.readConflictResult(path: document.path)
            guard currentResult.bytes == document.result.bytes,
                currentResult.identity == document.resultIdentity
            else { throw ModelFailure.changed }
            try ConflictEditorAtomicWriter.write(
                bytes: bytes, location: self.location, path: document.path,
                expected: currentResult.identity)
            var updated = document
            updated.result = try ConflictEditorBuffer(
                side: .result, source: document.result.source, bytes: bytes)
            let refreshed = try await self.readConflictResult(path: document.path)
            updated = ConflictEditorDocument(
                path: document.path, head: document.head, sequencer: document.sequencer,
                repositoryIdentity: document.repositoryIdentity,
                operationSnapshot: document.operationSnapshot,
                attributesListing: document.attributesListing,
                indexSnapshot: document.indexSnapshot,
                indexListing: document.indexListing, entryListing: document.entryListing,
                blockResolutions: document.blockResolutions,
                base: document.base, ours: document.ours, theirs: document.theirs,
                result: updated.result, resultIdentity: refreshed.identity)
            return updated
        }
    }

    /// Staging a conflict is deliberately separate from saving the working file.
    /// The same HEAD, index entries, and file identity captured by the editor must
    /// still match, and the saved result must contain no unresolved markers.
    public func markConflictResolved(_ document: ConflictEditorDocument) async throws {
        try await queue.perform {
            guard ConflictMarkerParser.analyze(document.result.text).resolved else {
                throw ModelFailure.unsupported(L10n.text("仍有未处理或损坏的冲突标记，请先保存完整结果。"))
            }
            try await self.verifyHead(document.head)
            try await self.verifyConflictDocument(document)
            let lease = try SelectedIndexLease(location: self.location, snapshot: document.indexSnapshot)
            try lease.verify()
            let state = try await self.status()
            guard state.conflicts.contains(where: { $0.path == document.path }) else {
                throw ModelFailure.changed
            }
            guard try await self.conflictIndexListing() == document.indexListing,
                try await self.conflictEntryListing(path: document.path) == document.entryListing
            else { throw ModelFailure.changed }
            let current = try await self.readConflictResult(path: document.path)
            guard current.identity == document.resultIdentity, current.bytes == document.result.bytes else {
                throw ModelFailure.changed
            }
            let expectedObject = try await self.engine.run(
                ["hash-object", "-w", "--path", document.path, "--stdin"], in: self.location.root,
                input: document.result.bytes
            ).text.removingLastNewline
            guard GitObjectID.valid(expectedObject) else { throw ModelFailure.changed }
            let directory = try self.privateConflictDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let candidate = directory.appending(path: "index")
            guard let original = document.indexSnapshot.bytes else { throw ModelFailure.changed }
            try self.writePrivateConflictInput(original, to: candidate)
            var candidateEngine = self.engine
            candidateEngine.environment["GIT_INDEX_FILE"] = candidate.path
            let mode = current.identity.mode & 0o111 == 0 ? "100644" : "100755"
            let remove = "0 " + String(repeating: "0", count: expectedObject.count)
            let update =
                remove + "\t" + document.path + "\0" + mode + " " + expectedObject
                + "\t" + document.path + "\0"
            _ = try await candidateEngine.run(
                ["update-index", "-z", "--index-info"], in: self.location.root, input: Data(update.utf8))
            let entries = try await self.conflictIndexListing(using: candidateEngine)
            try self.verifyResolvedEntries(document, expectedObject: expectedObject, listing: entries)
            let candidateBytes = try Data(contentsOf: candidate)
            try await self.verifyHead(document.head)
            try await self.verifyConflictDocument(document)
            let fresh = try await self.readConflictResult(path: document.path)
            guard fresh.identity == document.resultIdentity, fresh.bytes == document.result.bytes else {
                throw ModelFailure.changed
            }
            try lease.write(candidateBytes)
            try await self.verifyHead(document.head)
            try await self.verifyConflictDocument(document)
            try lease.install()
            do {
                try await self.verifyResolvedIndex(document, expectedObject: expectedObject)
            } catch {
                throw ModelFailure.unsupported(
                    L10n.text("结果可能已标记解决，请刷新冲突状态后再操作。"))
            }
        }
    }

    private func verifyConflictDocument(_ document: ConflictEditorDocument) async throws {
        guard location.persistenceID == document.repositoryIdentity else {
            throw ModelFailure.repositoryReplaced
        }
        guard try SelectedIndexSnapshot.read(location: location) == document.indexSnapshot else {
            throw ModelFailure.changed
        }
        let state = try await status()
        guard state.sequencer == document.sequencer,
            try await conflictOperationSnapshot(state: state) == document.operationSnapshot,
            try await conflictAttributes(path: document.path) == document.attributesListing,
            try await conflictIndexListing() == document.indexListing,
            try await conflictEntryListing(path: document.path) == document.entryListing
        else { throw ModelFailure.changed }
    }

    private func verifyResolvedIndex(_ document: ConflictEditorDocument, expectedObject: String) async throws
    {
        let state = try await status()
        guard !state.conflicts.contains(where: { $0.path == document.path }) else {
            throw ModelFailure.changed
        }
        let afterListing = try await conflictIndexListing()
        try verifyResolvedEntries(document, expectedObject: expectedObject, listing: afterListing)
    }

    private func verifyResolvedEntries(
        _ document: ConflictEditorDocument, expectedObject: String, listing: Data
    ) throws {
        let before = try conflictIndexRows(document.indexListing)
        let after = try conflictIndexRows(listing)
        let beforeOther = before.filter { $0.path != document.path }
        let afterOther = after.filter { $0.path != document.path }
        let targetRows = after.filter { $0.path == document.path }
        guard beforeOther == afterOther, targetRows.count == 1,
            targetRows[0].mode == "100644" || targetRows[0].mode == "100755",
            targetRows[0].object == expectedObject, targetRows[0].stage == 0
        else { throw ModelFailure.changed }
    }

    private func conflictIndexRows(_ data: Data) throws -> [ConflictIndexEntry] {
        guard data.isEmpty || data.last == 0 else { throw ModelFailure.changed }
        return try data.split(separator: 0, omittingEmptySubsequences: true).map { row in
            guard let tab = row.firstIndex(of: 9),
                let header = String(data: row[..<tab], encoding: .utf8)
            else { throw ModelFailure.changed }
            let fields = header.split(separator: " ")
            guard fields.count == 3, let mode = fields.first, let object = fields.dropFirst().first,
                GitObjectID.valid(String(object)), let stage = Int(fields[2]), (0...3).contains(stage)
            else { throw ModelFailure.changed }
            return ConflictIndexEntry(
                mode: String(mode), object: String(object), stage: stage,
                path: String(decoding: row[row.index(after: tab)...], as: UTF8.self))
        }
    }

    private func readConflictEditorDirect(path: String, expectedHead: String?) async throws
        -> ConflictEditorDocument
    {
        try validate(path)
        try await verifyHead(expectedHead)
        let capturedHead = try await head()
        let indexSnapshot = try SelectedIndexSnapshot.read(location: location)
        let state = try await status()
        guard state.conflicts.contains(where: { $0.path == path }) else {
            throw ModelFailure.changed
        }
        guard [.merge, .rebase, .cherryPick, .revert].contains(state.sequencer) else {
            throw ModelFailure.unsupported(L10n.text("此冲突来源暂不支持内置编辑，请使用外部工具。"))
        }
        let attributes = try await conflictAttributes(path: path)
        try verifyConflictAttributes(attributes)
        let operationSnapshot = try await conflictOperationSnapshot(state: state)
        let sharedIndex = try await engine.run(["rev-parse", "--shared-index-path"], in: location.root).stdout
        guard sharedIndex.isEmpty || sharedIndex == Data([10]) else {
            throw ModelFailure.unsupported(L10n.text("此冲突使用不支持的索引格式，请使用外部工具。"))
        }
        let index = try await conflictIndexListing()
        let entry = try await conflictEntryListing(path: path)
        let entries = try parseEntries(entry, expectedPath: path)
        guard entries.count == 3, Set(entries.map(\.stage)) == Set([1, 2, 3]) else {
            throw ModelFailure.unsupported(L10n.text("此冲突不是三方文本内容冲突，请使用外部工具。"))
        }
        let byStage = Dictionary(uniqueKeysWithValues: entries.map { ($0.stage, $0) })
        let source = try await conflictSources(
            state: state, path: path, base: byStage[1]!.object, ours: byStage[2]!.object,
            theirs: byStage[3]!.object)
        let base = try await conflictBuffer(
            side: .base, source: source.base, object: byStage[1]!.object)
        let ours = try await conflictBuffer(
            side: .ours, source: source.ours, object: byStage[2]!.object)
        let theirs = try await conflictBuffer(
            side: .theirs, source: source.theirs, object: byStage[3]!.object)
        let result = try await readConflictResult(path: path)
        let resultBuffer = try ConflictEditorBuffer(
            side: .result, source: ConflictEditorSource(title: L10n.text("工作区结果")), bytes: result.bytes)
        let blockResolutions = try await conflictBlockResolutions(
            ours: ours.bytes, base: base.bytes, theirs: theirs.bytes, result: resultBuffer.text)
        let document = ConflictEditorDocument(
            path: path, head: capturedHead, sequencer: state.sequencer,
            repositoryIdentity: location.persistenceID, operationSnapshot: operationSnapshot,
            attributesListing: attributes,
            indexSnapshot: indexSnapshot, indexListing: index, entryListing: entry,
            blockResolutions: blockResolutions,
            base: base, ours: ours, theirs: theirs,
            result: resultBuffer, resultIdentity: result.identity)
        try await verifyHead(capturedHead)
        try await verifyConflictDocument(document)
        let fresh = try await readConflictResult(path: path)
        guard fresh.identity == result.identity, fresh.bytes == result.bytes else {
            throw ModelFailure.changed
        }
        return document
    }

    private func conflictBlockResolutions(
        ours: Data, base: Data, theirs: Data, result: String
    ) async throws -> [ConflictEditorBlockResolution]? {
        let existing = ConflictMarkerParser.analyze(result)
        guard !existing.malformed, !existing.blocks.isEmpty else { return nil }
        let directory = try privateConflictDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oursURL = directory.appending(path: "ours")
        let baseURL = directory.appending(path: "base")
        let theirsURL = directory.appending(path: "theirs")
        try writePrivateConflictInput(ours, to: oursURL)
        try writePrivateConflictInput(base, to: baseURL)
        try writePrivateConflictInput(theirs, to: theirsURL)
        let merged = try await engine.run(
            [
                "merge-file", "--diff3", "-p", "-L", "OURS", "-L", "BASE", "-L", "THEIRS",
                oursURL.path, baseURL.path, theirsURL.path,
            ],
            in: location.root, accepted: [0, 1], outputLimit: ConflictEditorBudget.bytes)
        guard let mergedText = String(data: merged.stdout, encoding: .utf8) else { return nil }
        let generated = ConflictMarkerParser.analyze(mergedText)
        guard !generated.malformed, generated.blocks.count == existing.blocks.count else { return nil }
        var resolutions: [ConflictEditorBlockResolution] = []
        for (index, pair) in zip(existing.blocks, generated.blocks).enumerated() {
            let (current, candidate) = pair
            guard current.oursBytes == candidate.oursBytes,
                current.theirsBytes == candidate.theirsBytes,
                let baseBytes = candidate.baseBytes
            else { return nil }
            resolutions.append(
                ConflictEditorBlockResolution(
                    id: index, oursBytes: current.oursBytes,
                    baseBytes: baseBytes, theirsBytes: current.theirsBytes))
        }
        return resolutions
    }

    private func privateConflictDirectory() throws -> URL {
        var template = Array(
            (FileManager.default.temporaryDirectory.appending(path: "wegit-conflict-XXXXXX").path + "\0").utf8
        ).map { CChar($0) }
        guard let path = mkdtemp(&template) else { throw ProcessFailure.outputWrite(errno) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private func writePrivateConflictInput(_ bytes: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ProcessFailure.outputWrite(errno) }
        defer { Darwin.close(descriptor) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ProcessFailure.outputWrite(count < 0 ? errno : EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ProcessFailure.outputWrite(errno) }
    }

    private func conflictAttributes(path: String) async throws -> Data {
        let result = try await engine.run(
            ["check-attr", "-z", "--all", "--", path], in: location.root, outputLimit: 16 * 1024)
        guard result.stdout.isEmpty || result.stdout.last == 0 else { throw ModelFailure.changed }
        return result.stdout
    }

    private func verifyConflictAttributes(_ data: Data) throws {
        if data.isEmpty { return }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count % 3 == 1, fields.last?.isEmpty == true else { throw ModelFailure.changed }
        for index in stride(from: 0, to: fields.count - 1, by: 3) {
            let attribute = String(decoding: fields[index + 1], as: UTF8.self)
            let value = String(decoding: fields[index + 2], as: UTF8.self)
            if attribute == "merge", !["set", "text"].contains(value) {
                throw ModelFailure.unsupported(L10n.text("此文件使用不支持的合并驱动，请使用外部工具。"))
            }
            if attribute == "filter", value != "unset" {
                throw ModelFailure.unsupported(L10n.text("此文件使用内容过滤器，请使用外部工具。"))
            }
        }
    }

    private func conflictOperationSnapshot(state: RepositoryStatus) async throws
        -> ConflictEditorOperationSnapshot
    {
        switch state.sequencer {
        case .merge:
            return .merge(try operationMarkerData(["MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "AUTO_MERGE"]))
        case .rebase:
            guard let recovery = state.rebaseRecovery else { throw ModelFailure.changed }
            return .rebase(recovery)
        case .cherryPick:
            guard let recovery = state.singleCommitRecovery else { throw ModelFailure.changed }
            return .cherryPick(recovery, try operationMarkerData(["CHERRY_PICK_HEAD"]))
        case .revert:
            guard let recovery = state.singleCommitRecovery else { throw ModelFailure.changed }
            return .revert(recovery, try operationMarkerData(["REVERT_HEAD"]))
        default:
            throw ModelFailure.changed
        }
    }

    private func operationMarkerData(_ names: [String]) throws -> Data {
        var result = Data()
        for name in names {
            let url = location.gitDirectory.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                result.append(contentsOf: Data((name + "\0<missing>\0").utf8))
                continue
            }
            let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard bytes.count <= RebaseBudget.stateFileBytes else { throw ModelFailure.changed }
            result.append(contentsOf: Data((name + "\0").utf8))
            result.append(bytes)
            result.append(0)
        }
        return result
    }

    private func conflictSources(
        state: RepositoryStatus, path: String, base: String, ours: String, theirs: String
    ) async throws -> (base: ConflictEditorSource, ours: ConflictEditorSource, theirs: ConflictEditorSource) {
        let currentHead = try await head()
        guard let currentHead else { throw ModelFailure.unsupported(L10n.text("当前仓库没有可核对的 HEAD。")) }
        let sources:
            (
                base: String, ours: String, theirs: String, baseTitle: String, oursTitle: String,
                theirsTitle: String
            )
        switch state.sequencer {
        case .merge:
            guard let other = try await stateRevision("MERGE_HEAD") else { throw ModelFailure.changed }
            let mergeBase = try await uniqueMergeBase(currentHead, other)
            sources = (
                mergeBase, currentHead, other, L10n.text("共同起点"),
                L10n.text("当前分支 (branch)"), L10n.text("合并来源")
            )
        case .rebase:
            guard let recovery = state.rebaseRecovery,
                let replay = recovery.stoppedCommit ?? recovery.rescheduledCommit
            else { throw ModelFailure.unsupported(L10n.text("此变基冲突的来源无法完整核对，请使用外部工具。")) }
            let parent = try await uniqueParent(replay)
            sources = (
                parent, currentHead, replay, L10n.text("重放提交的父提交"),
                L10n.text("当前重放基础"), L10n.text("重放提交")
            )
        case .cherryPick:
            guard let target = try await stateRevision("CHERRY_PICK_HEAD") else { throw ModelFailure.changed }
            let parent = try await uniqueParent(target)
            sources = (
                parent, currentHead, target, L10n.text("原提交的父提交"),
                L10n.text("当前分支 (branch)"), L10n.text("Cherry-pick 提交")
            )
        case .revert:
            guard let target = try await stateRevision("REVERT_HEAD") else { throw ModelFailure.changed }
            let parent = try await uniqueParent(target)
            sources = (
                target, currentHead, parent, L10n.text("被撤销提交"),
                L10n.text("当前分支 (branch)"), L10n.text("撤销后的父提交")
            )
        default:
            throw ModelFailure.unsupported(L10n.text("此冲突来源暂不支持内置编辑，请使用外部工具。"))
        }
        try await verifyBlob(sources.base, path: path, expected: base)
        try await verifyBlob(sources.ours, path: path, expected: ours)
        try await verifyBlob(sources.theirs, path: path, expected: theirs)
        return (
            ConflictEditorSource(title: sources.baseTitle, revision: sources.base),
            ConflictEditorSource(title: sources.oursTitle, revision: sources.ours),
            ConflictEditorSource(title: sources.theirsTitle, revision: sources.theirs)
        )
    }

    private func uniqueMergeBase(_ left: String, _ right: String) async throws -> String {
        let result = try await engine.run(["merge-base", "--all", left, right], in: location.root)
        let values = result.text.split(whereSeparator: \.isNewline).map(String.init)
        guard values.count == 1, let value = values.first, GitObjectID.valid(value) else {
            throw ModelFailure.unsupported(L10n.text("冲突来源存在多个或不存在共同起点，请使用外部工具。"))
        }
        return value
    }

    private func uniqueParent(_ revision: String) async throws -> String {
        let result = try await engine.run(
            ["rev-list", "--parents", "-n", "1", revision], in: location.root, outputLimit: 4096)
        let values = result.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard values.count == 2, values[0] == revision, GitObjectID.valid(values[1]) else {
            throw ModelFailure.unsupported(L10n.text("冲突提交没有唯一父提交，请使用外部工具。"))
        }
        return values[1]
    }

    private func verifyBlob(_ revision: String, path: String, expected: String) async throws {
        let result = try await engine.run(
            ["rev-parse", "--verify", revision + ":" + path], in: location.root, accepted: [0, 128])
        guard result.exitCode == 0, result.text.removingLastNewline == expected else {
            throw ModelFailure.unsupported(L10n.text("Git 无法把冲突阶段映射到稳定来源，请使用外部工具。"))
        }
    }

    private func stateRevision(_ name: String) async throws -> String? {
        let result = try await engine.run(
            ["rev-parse", "--verify", name], in: location.root, accepted: [0, 128])
        guard result.exitCode == 0 else { return nil }
        let value = result.text.removingLastNewline
        return GitObjectID.valid(value) ? value : nil
    }

    private func conflictBuffer(side: ConflictEditorSide, source: ConflictEditorSource, object: String)
        async throws -> ConflictEditorBuffer
    {
        let result = try await engine.run(
            ["cat-file", "blob", object], in: location.root, outputLimit: ConflictEditorBudget.bytes)
        return try ConflictEditorBuffer(side: side, source: source, bytes: result.stdout)
    }

    private func conflictIndexListing(using reader: GitEngine? = nil) async throws -> Data {
        let result = try await (reader ?? engine).run(
            ["ls-files", "--stage", "-z"], in: location.root, outputLimit: ConflictEditorBudget.indexBytes)
        guard result.stdout.isEmpty || result.stdout.last == 0 else { throw ModelFailure.changed }
        return result.stdout
    }

    private func conflictEntryListing(path: String) async throws -> Data {
        let index = try await conflictIndexListing()
        var result = Data()
        for row in index.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = row.firstIndex(of: 9),
                let entryPath = String(data: row[row.index(after: tab)...], encoding: .utf8)
            else { throw ModelFailure.invalidOutput("conflict index path") }
            if entryPath == path {
                result.append(contentsOf: row)
                result.append(0)
            }
        }
        return result
    }

    private func parseEntries(_ data: Data, expectedPath: String) throws -> [ConflictIndexEntry] {
        try data.split(separator: 0, omittingEmptySubsequences: true).map { row in
            guard let tab = row.firstIndex(of: 9),
                let header = String(data: row[..<tab], encoding: .utf8),
                let path = String(data: row[row.index(after: tab)...], encoding: .utf8), path == expectedPath
            else { throw ModelFailure.changed }
            let fields = header.split(separator: " ")
            guard fields.count == 3, ["100644", "100755"].contains(fields[0]),
                GitObjectID.valid(String(fields[1])), let stage = Int(fields[2]), (1...3).contains(stage)
            else { throw ModelFailure.unsupported(L10n.text("此冲突包含不支持的索引条目。")) }
            return ConflictIndexEntry(
                mode: String(fields[0]), object: String(fields[1]), stage: stage, path: path)
        }
    }

    private func readConflictResult(path: String) async throws -> (
        bytes: Data, identity: ConflictEditorFileIdentity
    ) {
        try await SnapshotIO.run { cancellation in
            let reader = try RepositoryFileReader(
                location: self.location, path: path, cancellation: cancellation)
            guard !reader.symbolicLink, reader.size <= ConflictEditorBudget.bytes else {
                throw ModelFailure.unsupported(L10n.text("此冲突不是可编辑的普通文本文件。"))
            }
            var bytes = Data()
            try reader.read(limit: ConflictEditorBudget.bytes) { bytes.append($0) }
            return (
                bytes,
                ConflictEditorFileIdentity(
                    reader.version, mode: reader.mode,
                    parentDirectories: reader.directoryIdentities)
            )
        }
    }
}

private enum ConflictEditorAtomicWriter {
    static func write(
        bytes: Data, location: RepositoryLocation, path: String,
        expected: ConflictEditorFileIdentity
    ) throws {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last, !parts.contains(".."), !name.isEmpty else {
            throw ModelFailure.invalidPath
        }
        let root = Darwin.open(location.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ModelFailure.repositoryReplaced }
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0,
            rootInfo.st_dev == location.rootIdentity.device,
            rootInfo.st_ino == location.rootIdentity.inode,
            rootInfo.st_birthtimespec.tv_sec == location.rootIdentity.bornSeconds,
            rootInfo.st_birthtimespec.tv_nsec == location.rootIdentity.bornNanoseconds
        else {
            Darwin.close(root)
            throw ModelFailure.repositoryReplaced
        }
        var parent = root
        var parentDirectories: [ConflictEditorDirectoryIdentity] = []
        var temp: String?
        defer {
            if let temp { unlinkat(parent, temp, 0) }
            if parent != root { Darwin.close(parent) }
            Darwin.close(root)
        }
        for component in parts.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ModelFailure.changed }
            var directory = stat()
            guard fstat(next, &directory) == 0 else {
                Darwin.close(next)
                throw ModelFailure.changed
            }
            parentDirectories.append(
                ConflictEditorDirectoryIdentity(
                    device: UInt64(directory.st_dev), inode: UInt64(directory.st_ino),
                    bornSeconds: Int64(directory.st_birthtimespec.tv_sec),
                    bornNanoseconds: Int64(directory.st_birthtimespec.tv_nsec)))
            if parent != root { Darwin.close(parent) }
            parent = next
        }
        var current = stat()
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            ConflictEditorFileIdentity(current, parentDirectories: parentDirectories) == expected
        else { throw ModelFailure.changed }
        guard current.st_uid == geteuid() else {
            throw ModelFailure.unsupported(L10n.text("此文件不属于当前用户，无法安全保留所有者身份。"))
        }
        let mode = mode_t(expected.mode)
        let candidate = ".wegit-conflict-" + UUID().uuidString
        let fd = openat(parent, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw ProcessFailure.outputWrite(errno) }
        defer { Darwin.close(fd) }
        temp = candidate
        guard fchmod(fd, mode) == 0 else { throw ProcessFailure.outputWrite(errno) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ProcessFailure.outputWrite(count < 0 ? errno : EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ProcessFailure.outputWrite(errno) }
        var fresh = stat()
        guard fstatat(parent, name, &fresh, AT_SYMLINK_NOFOLLOW) == 0,
            ConflictEditorFileIdentity(fresh, parentDirectories: parentDirectories) == expected
        else { throw ModelFailure.changed }
        guard renameat(parent, candidate, parent, name) == 0 else {
            throw ProcessFailure.outputWrite(errno)
        }
        temp = nil
        guard fsync(parent) == 0 else { throw ProcessFailure.outputWrite(errno) }
    }

}

extension ConflictEditorFileIdentity {
    fileprivate init(_ info: stat, parentDirectories: [ConflictEditorDirectoryIdentity]) {
        self.init(
            device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec),
            mode: UInt16(info.st_mode & UInt16(0o777)), parentDirectories: parentDirectories)
    }
}
