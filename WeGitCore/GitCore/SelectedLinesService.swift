import Foundation

extension RepositoryService {
    private var selectedLinesEngine: GitEngine {
        var reader = engine
        reader.environment["GIT_NO_LAZY_FETCH"] = "1"
        reader.environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        return reader
    }

    /// The private candidate index and object store keep preview read-only for the repository.
    @concurrent public func prepareSelectedLines(diff: FileDiff, lineIDs: Set<Int>) async throws
        -> SelectedLinesPlan
    {
        try await queue.perform {
            try location.validateIdentity()
            try validate(diff.path)
            try await selectedLinesValidateFilter(diff.path)
            let head = try await self.head()
            guard head == diff.head else { throw ModelFailure.changed }
            let branch = try await selectedLinesBranch()
            let split = try await engine.run(["rev-parse", "--shared-index-path"], in: location.root).stdout
            guard split.isEmpty || split == Data([10]) else {
                throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。"))
            }
            let index = try SelectedIndexSnapshot.read(location: location)
            let workFile = try await selectedLinesWorkFile(diff.path)
            let reader = RepositoryService(location: location, engine: selectedLinesEngine, queue: queue)
            let fresh = try await reader.diff(path: diff.path, layer: diff.layer, options: diff.options)
            guard fresh.raw == diff.raw, fresh.head == head else { throw ModelFailure.changed }
            let original = try await selectedLinesEntries(engine: selectedLinesEngine)
            let path = Data(diff.path.utf8)
            let before = original[path]
            if let before {
                guard ["100644", "100755"].contains(before.mode), before.flag == "H", before.stage == "0"
                else { throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。")) }
            } else {
                guard
                    (diff.layer == .staged && diff.header.contains("deleted file mode"))
                        || diff.layer == .untracked
                else {
                    throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。"))
                }
            }
            let blob =
                try await before == nil
                ? Data() : selectedLinesBlob(engine: selectedLinesEngine, path: diff.path)
            let effective =
                diff.layer == .untracked
                ? try await selectedUntrackedDiff(
                    path: diff.path, options: diff.options, head: head, index: index)
                : fresh
            if diff.layer == .untracked {
                var represented = Data()
                for line in effective.hunks.flatMap(\.lines) where line.kind == "+" {
                    represented.append(Data(line.content.utf8))
                    if line.hasNewline { represented.append(10) }
                }
                guard represented == fresh.raw else {
                    throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。"))
                }
            }
            let expected = try SelectedLinePatch.expectedIndex(
                diff: effective, lineIDs: lineIDs, current: blob)
            let patch = try SelectedLinePatch.make(diff: effective, lineIDs: lineIDs)
            let directory = try await SnapshotIO.run { _ in try SnapshotDirectory() }
            defer { withExtendedLifetime(directory) {} }
            let candidate = directory.url.appending(path: "index")
            let objects = directory.url.appending(path: "objects")
            try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: false)
            var privateEngine = selectedLinesEngine
            privateEngine.environment["GIT_INDEX_FILE"] = candidate.path
            privateEngine.environment["GIT_OBJECT_DIRECTORY"] = objects.path
            privateEngine.environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = singleCommitAlternatePath(
                location.commonDirectory.appending(path: "objects").path)
            privateEngine.environment["GIT_NO_LAZY_FETCH"] = "1"
            if let rawIndex = index.bytes {
                try rawIndex.write(to: candidate)
            } else {
                _ = try await privateEngine.run(["read-tree", "--empty"], in: location.root)
            }
            var arguments = ["apply", "--cached", "--unidiff-zero"]
            if diff.layer == .staged { arguments.append("--reverse") }
            _ = try await privateEngine.run(arguments + ["--check", "-"], in: location.root, input: patch)
            _ = try await privateEngine.run(arguments + ["-"], in: location.root, input: patch)
            let afterEntries = try await selectedLinesEntries(engine: privateEngine)
            let after = afterEntries[path]
            if let after {
                guard ["100644", "100755"].contains(after.mode), after.flag == "H", after.stage == "0",
                    before == nil || after.mode == before?.mode
                else { throw ModelFailure.changed }
            }
            guard after?.oid != before?.oid else { throw ModelFailure.changed }
            var beforeOthers = original
            var afterOthers = afterEntries
            beforeOthers.removeValue(forKey: path)
            afterOthers.removeValue(forKey: path)
            guard beforeOthers == afterOthers else { throw ModelFailure.changed }
            if after == nil {
                guard expected.isEmpty else { throw ModelFailure.changed }
            } else {
                guard try await selectedLinesBlob(engine: privateEngine, path: diff.path) == expected else {
                    throw ModelFailure.changed
                }
            }
            let candidateIndex = try Data(contentsOf: candidate)
            guard candidateIndex.count <= 32 * 1024 * 1024,
                try SelectedIndexSnapshot.read(location: location) == index,
                try await selectedLinesWorkFile(diff.path) == workFile,
                try await self.head() == head, try await selectedLinesBranch() == branch
            else { throw ModelFailure.changed }
            return SelectedLinesPlan(
                id: UUID(), path: diff.path, layer: diff.layer, patch: patch,
                selectedLineCount: lineIDs.count, beforeBlob: before?.oid, afterBlob: after?.oid,
                location: location, head: head, branch: branch, diff: fresh, index: index,
                workFile: workFile, candidateIndex: candidateIndex, candidateBlob: expected)
        }
    }

    /// The only write before installing the index is the content-addressed blob.
    public func executeSelectedLines(_ plan: SelectedLinesPlan) async throws {
        try await queue.perform {
            guard plan.location == location else { throw ModelFailure.changed }
            let lease = try SelectedIndexLease(location: location, snapshot: plan.index)
            try await selectedLinesValidate(plan, lease: lease)
            if let afterBlob = plan.afterBlob {
                let blob = try await engine.run(
                    ["hash-object", "-w", "--stdin"], in: location.root, input: plan.candidateBlob
                ).text.removingLastNewline
                guard blob == afterBlob else { throw ModelFailure.changed }
            }
            try await selectedLinesValidate(plan, lease: lease)
            try lease.write(plan.candidateIndex)
            try await selectedLinesValidate(plan, lease: lease)
            try lease.install()
            do {
                try location.validateIdentity()
                guard try SelectedIndexSnapshot.read(location: location).bytes == plan.candidateIndex else {
                    throw ModelFailure.changed
                }
                let entries = try await selectedLinesEntries(engine: selectedLinesEngine)
                guard entries[Data(plan.path.utf8)]?.oid == plan.afterBlob else { throw ModelFailure.changed }
                if plan.afterBlob != nil {
                    guard
                        try await selectedLinesBlob(engine: selectedLinesEngine, path: plan.path)
                            == plan.candidateBlob
                    else { throw ModelFailure.changed }
                }
            } catch { throw SelectedLinesOutcomeUnknown(path: plan.path) }
        }
    }

    private func selectedLinesValidate(_ plan: SelectedLinesPlan, lease: SelectedIndexLease) async throws {
        try location.validateIdentity()
        try lease.verify()
        try await selectedLinesValidateFilter(plan.path)
        guard try await head() == plan.head, try await selectedLinesBranch() == plan.branch,
            try await selectedLinesWorkFile(plan.path) == plan.workFile
        else { throw ModelFailure.changed }
        let reader = RepositoryService(location: location, engine: selectedLinesEngine, queue: queue)
        let fresh = try await reader.diff(path: plan.path, layer: plan.layer, options: plan.diff.options)
        guard fresh.raw == plan.diff.raw, fresh.head == plan.head else { throw ModelFailure.changed }
        try lease.verify()
        try location.validateIdentity()
    }

    private func selectedLinesBranch() async throws -> String {
        let result = try await engine.run(
            ["symbolic-ref", "-q", "HEAD"], in: location.root, accepted: [0, 1])
        return result.exitCode == 0 ? result.text.removingLastNewline : ""
    }

    private func selectedLinesWorkFile(_ path: String) async throws -> Data? {
        try await SelectedWorkFile.read(location: location, path: path)
    }

    private func selectedUntrackedDiff(
        path: String, options: DiffReadOptions, head: String?, index: SelectedIndexSnapshot
    ) async throws -> FileDiff {
        guard !options.ignoreWhitespace else {
            throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。"))
        }
        try await selectedLinesValidateFilter(path)
        let directory = try await SnapshotIO.run { _ in try SnapshotDirectory() }
        defer { withExtendedLifetime(directory) {} }
        let candidate = directory.url.appending(path: "index")
        let objects = directory.url.appending(path: "objects")
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: false)
        var privateEngine = selectedLinesEngine
        privateEngine.environment["GIT_INDEX_FILE"] = candidate.path
        privateEngine.environment["GIT_OBJECT_DIRECTORY"] = objects.path
        privateEngine.environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = singleCommitAlternatePath(
            location.commonDirectory.appending(path: "objects").path)
        if let bytes = index.bytes {
            try bytes.write(to: candidate)
        } else {
            _ = try await privateEngine.run(["read-tree", "--empty"], in: location.root)
        }
        _ = try await privateEngine.run(["add", "--intent-to-add", "--", path], in: location.root)
        let raw = try await privateEngine.run(
            diffArguments(path: path, layer: .unstaged, options: options), in: location.root,
            outputLimit: DiffReadBudget.patchBytes
        ).stdout
        let parsed = try DiffParser.parse(raw, path: path, layer: .unstaged, head: head, options: options)
        guard parsed.header.contains("new file mode") else { throw ModelFailure.changed }
        return parsed
    }

    /// Do not invoke a user-configured clean filter while repeatedly revalidating
    /// a preview; filters may be stateful and can run arbitrary commands.
    private func selectedLinesValidateFilter(_ path: String) async throws {
        let attributes = try await selectedLinesEngine.run(
            ["check-attr", "-z", "filter", "--", path], in: location.root, outputLimit: 16 * 1024
        ).stdout.split(separator: 0, omittingEmptySubsequences: false)
        guard attributes.count == 4, Data(attributes[0]) == Data(path.utf8),
            attributes[1] == Data("filter".utf8),
            [Data("unspecified".utf8), Data("unset".utf8)].contains(Data(attributes[2])),
            attributes[3].isEmpty
        else { throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。")) }
    }

    private struct SelectedIndexEntry: Equatable {
        let flag: String
        let mode: String
        let oid: String
        let stage: String
    }

    private func selectedLinesEntries(engine: GitEngine) async throws -> [Data: SelectedIndexEntry] {
        let raw = try await engine.run(
            ["ls-files", "--stage", "-v", "-z"], in: location.root, outputLimit: 32 * 1024 * 1024
        ).stdout
        guard raw.isEmpty || raw.last == 0 else { throw ModelFailure.changed }
        var entries: [Data: SelectedIndexEntry] = [:]
        for row in raw.split(separator: 0) {
            guard let tab = row.firstIndex(of: 9), let text = String(data: row[..<tab], encoding: .utf8)
            else { throw ModelFailure.changed }
            let fields = text.split(separator: " ")
            let path = Data(row[row.index(after: tab)...])
            guard fields.count == 4, fields[0].count == 1, fields[3] == "0",
                fields[1].count == 6, fields[1].allSatisfy({ ("0"..."7").contains($0) }),
                GitObjectID.valid(String(fields[2])), entries[path] == nil
            else { throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。")) }
            entries[path] = SelectedIndexEntry(
                flag: String(fields[0]), mode: String(fields[1]), oid: String(fields[2]),
                stage: String(fields[3]))
        }
        return entries
    }

    private func selectedLinesBlob(engine: GitEngine, path: String) async throws -> Data {
        try await engine.run(["show", ":" + path], in: location.root, outputLimit: 8 * 1024 * 1024).stdout
    }
}
