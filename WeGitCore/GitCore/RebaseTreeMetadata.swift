import Foundation

struct RebaseTreeEntry: Equatable, Sendable {
    let object: String
    let mode: String
    let bytes: Int
}

/// Owned by one preparation only. Original trees are decoded once; synthetic
/// results use bounded raw deltas. No cache survives a returned preview.
actor RebaseTreeMetadata {
    private let root: URL
    private var trees: [String: [String: RebaseTreeEntry]] = [:]
    private var sizes: [String: Int] = [:]
    private var metadataBytes = 0
    private var entriesStored = 0
    init(root: URL) { self.root = root }

    func entries(_ revision: String, engine: GitEngine) async throws -> [String: RebaseTreeEntry] {
        if let existing = trees[revision] { return existing }
        try await preload([revision], engine: engine)
        guard let value = trees[revision] else { throw ModelFailure.changed }
        return value
    }

    func preload(_ revisions: [String], engine: GitEngine) async throws {
        var pending: [(revision: String, records: [String: (object: String, mode: String)], bytes: Int)] = []
        var missing: Set<String> = []
        var pendingEntries = 0
        var pendingBytes = 0
        var seen: Set<String> = []
        for revision in revisions where seen.insert(revision).inserted && trees[revision] == nil {
            try Task.checkCancellation()
            let tree = try await readTree(revision, includeSizes: sizes.isEmpty, engine: engine)
            guard tree.records.count <= 1_000_000 - entriesStored - pendingEntries,
                tree.bytes <= 128 * 1024 * 1024 - metadataBytes - pendingBytes
            else { throw RebaseBudget.exceeded }
            pendingEntries += tree.records.count
            pendingBytes += tree.bytes
            for record in tree.records.values where sizes[record.object] == nil {
                missing.insert(record.object)
            }
            pending.append((revision, tree.records, tree.bytes))
        }
        let batchBytes = try await loadMissingSizes(missing, engine: engine)
        guard batchBytes <= 128 * 1024 * 1024 - metadataBytes - pendingBytes else {
            throw RebaseBudget.exceeded
        }
        metadataBytes += batchBytes
        while let tree = pending.popLast() {
            var value: [String: RebaseTreeEntry] = [:]
            for (path, record) in tree.records {
                try Task.checkCancellation()
                guard let size = sizes[record.object] else { throw ModelFailure.changed }
                value[path] = RebaseTreeEntry(object: record.object, mode: record.mode, bytes: size)
            }
            try store(value, for: tree.revision, bytes: tree.bytes)
        }
    }

    func preloadLinear(_ commits: [GitCommit], base: String?, target: String, engine: GitEngine)
        async throws -> Bool
    {
        guard let base, !commits.isEmpty else { return false }
        var previous = base
        for commit in commits {
            guard commit.parents == [previous] else { return false }
            previous = commit.id
        }
        let revisions = [base] + commits.map(\.id)
        guard revisions.allSatisfy(GitObjectID.valid), GitObjectID.valid(target),
            commits.count <= RebaseBudget.commits
        else { throw ModelFailure.invalidPath }
        try await preload([target, base], engine: engine)
        let treeRaw = try await engine.run(
            ["cat-file", "--batch-check=%(objectname) %(objecttype)", "--buffer"], in: root,
            input: Data((revisions.map { $0 + "^{tree}" }.joined(separator: "\n") + "\n").utf8),
            outputLimit: RebaseBudget.metadataBytes
        ).stdout
        guard treeRaw.last == 10, let text = String(data: treeRaw, encoding: .utf8) else {
            throw ModelFailure.changed
        }
        let rows = text.split(separator: "\n")
        guard rows.count == revisions.count else { throw ModelFailure.changed }
        let treeIDs = try rows.map { row -> String in
            let fields = row.split(separator: " ")
            guard fields.count == 2, fields[1] == "tree", GitObjectID.valid(String(fields[0])) else {
                throw ModelFailure.changed
            }
            return String(fields[0])
        }
        let comparisons = (0..<commits.count).map { treeIDs[$0] + " " + treeIDs[$0 + 1] + "\n" }
        let raw = try await engine.run(
            [
                "diff-tree", "--stdin", "-r", "--raw", "--no-abbrev", "--no-commit-id", "-z",
                "--no-renames", "--no-ext-diff", "--no-textconv",
            ], in: root, input: Data(comparisons.joined().utf8), outputLimit: RebaseBudget.metadataBytes
        ).stdout
        let deltas = try splitLinearDeltas(raw, comparisons: comparisons)
        var missing: Set<String> = []
        for delta in deltas {
            let fields = delta.split(separator: 0)
            guard fields.count % 2 == 0, fields.count / 2 <= RebaseBudget.entries else {
                throw RebaseBudget.exceeded
            }
            for index in stride(from: 0, to: fields.count, by: 2) {
                try Task.checkCancellation()
                guard let header = String(data: fields[index], encoding: .utf8), header.hasPrefix(":") else {
                    throw ModelFailure.changed
                }
                let values = header.dropFirst().split(separator: " ")
                guard values.count == 5, ["A", "D", "M", "T"].contains(values[4]) else {
                    throw ModelFailure.changed
                }
                if values[4] != "D" {
                    let object = String(values[3])
                    guard ["100644", "100755", "120000"].contains(values[1]), GitObjectID.valid(object) else {
                        throw ModelFailure.changed
                    }
                    if sizes[object] == nil { missing.insert(object) }
                }
            }
        }
        let batchBytes = try await loadMissingSizes(missing, engine: engine)
        let headerBytes = raw.count - deltas.reduce(0) { $0 + $1.count }
        let extra = treeRaw.count + headerBytes + batchBytes
        guard extra <= 128 * 1024 * 1024 - metadataBytes else { throw RebaseBudget.exceeded }
        metadataBytes += extra
        for (commit, delta) in zip(commits, deltas) {
            try await derive(commit.id, from: commit.parents[0], raw: delta, engine: engine)
        }
        return true
    }

    private func splitLinearDeltas(_ raw: Data, comparisons: [String]) throws -> [Data] {
        var cursor = raw.startIndex
        var values: [Data] = []
        for comparison in comparisons {
            try Task.checkCancellation()
            let prefix = Data(comparison.utf8)
            guard prefix.count <= raw.endIndex - cursor,
                raw[cursor..<cursor + prefix.count].elementsEqual(prefix)
            else { throw ModelFailure.changed }
            cursor += prefix.count
            let start = cursor
            while cursor < raw.endIndex, raw[cursor] == 58 {
                guard let headerEnd = raw[cursor...].firstIndex(of: 0) else { throw ModelFailure.changed }
                cursor = raw.index(after: headerEnd)
                guard cursor < raw.endIndex, let pathEnd = raw[cursor...].firstIndex(of: 0) else {
                    throw ModelFailure.changed
                }
                cursor = raw.index(after: pathEnd)
            }
            values.append(Data(raw[start..<cursor]))
        }
        guard cursor == raw.endIndex else { throw ModelFailure.changed }
        return values
    }

    private func readTree(_ revision: String, includeSizes: Bool, engine: GitEngine) async throws
        -> (records: [String: (object: String, mode: String)], bytes: Int)
    {
        guard GitObjectID.valid(revision) else { throw ModelFailure.invalidPath }
        let raw = try await engine.run(
            ["ls-tree", "-r", "-z", "--full-tree"] + (includeSizes ? ["-l"] : []) + [revision], in: root,
            outputLimit: RebaseBudget.metadataBytes
        ).stdout
        guard raw.isEmpty || raw.last == 0 else { throw ModelFailure.changed }
        var records: [String: (object: String, mode: String)] = [:]
        for row in raw.split(separator: 0) {
            try Task.checkCancellation()
            guard let tab = row.firstIndex(of: 9), let header = String(data: row[..<tab], encoding: .utf8),
                let path = String(data: row[row.index(after: tab)...], encoding: .utf8)
            else { throw ModelFailure.changed }
            let fields = header.split(separator: " ")
            guard fields.count == (includeSizes ? 4 : 3), fields[1] == "blob",
                GitObjectID.valid(String(fields[2])),
                ["100644", "100755", "120000"].contains(fields[0])
            else { throw ModelFailure.unsupported(L10n.text("此变基范围包含子模块或未支持的树记录，请在 Terminal 中处理。")) }
            try pathValid(path)
            guard records[path] == nil else { throw ModelFailure.changed }
            guard records.count < RebaseBudget.entries else { throw RebaseBudget.exceeded }
            let object = String(fields[2])
            if includeSizes {
                guard let size = Int(fields[3]), size >= 0 else { throw ModelFailure.changed }
                if let known = sizes[object], known != size { throw ModelFailure.changed }
                sizes[object] = size
            }
            records[path] = (object, String(fields[0]))
        }
        return (records, raw.count)
    }

    func paths(_ revision: String, engine: GitEngine) async throws -> Set<String> {
        Set(try await entries(revision, engine: engine).keys)
    }

    func alias(_ revision: String, tree: String) throws {
        guard GitObjectID.valid(revision), let value = trees[tree] else { throw ModelFailure.changed }
        trees[revision] = value
    }

    func derive(_ tree: String, from previous: String, engine: GitEngine) async throws {
        if trees[tree] != nil { return }
        guard GitObjectID.valid(tree), GitObjectID.valid(previous) else { throw ModelFailure.invalidPath }
        let raw = try await engine.run(
            [
                "diff-tree", "-r", "--no-commit-id", "--raw", "--no-abbrev", "-z", "--no-renames",
                "--no-ext-diff", "--no-textconv", previous, tree, "--",
            ], in: root,
            outputLimit: RebaseBudget.metadataBytes
        ).stdout
        try await derive(tree, from: previous, raw: raw, engine: engine)
    }

    private func derive(_ tree: String, from previous: String, raw: Data, engine: GitEngine) async throws {
        var value = try await entries(previous, engine: engine)
        guard raw.isEmpty || raw.last == 0 else { throw ModelFailure.changed }
        let rows = raw.split(separator: 0)
        guard rows.count % 2 == 0, rows.count / 2 <= RebaseBudget.entries else { throw RebaseBudget.exceeded }
        var updates: [(String, String, String)] = []
        var missing: Set<String> = []
        for index in stride(from: 0, to: rows.count, by: 2) {
            try Task.checkCancellation()
            guard let header = String(data: rows[index], encoding: .utf8), header.hasPrefix(":"),
                let path = String(data: rows[index + 1], encoding: .utf8)
            else { throw ModelFailure.changed }
            try pathValid(path)
            let fields = header.dropFirst().split(separator: " ")
            guard fields.count == 5, ["A", "D", "M", "T"].contains(fields[4]) else {
                throw ModelFailure.changed
            }
            let old = value[path]
            guard String(fields[0]) == (old?.mode ?? "000000"),
                String(fields[2]) == (old?.object ?? String(repeating: "0", count: fields[2].count))
            else { throw ModelFailure.changed }
            if fields[4] == "D" {
                value.removeValue(forKey: path)
            } else {
                let mode = String(fields[1])
                let object = String(fields[3])
                guard ["100644", "100755", "120000"].contains(mode), GitObjectID.valid(object) else {
                    throw ModelFailure.changed
                }
                updates.append((path, mode, object))
                if sizes[object] == nil { missing.insert(object) }
            }
        }
        let batchBytes = try await loadMissingSizes(missing, engine: engine)
        for (path, mode, object) in updates {
            guard let size = sizes[object] else { throw ModelFailure.changed }
            value[path] = RebaseTreeEntry(object: object, mode: mode, bytes: size)
        }
        try store(value, for: tree, bytes: raw.count + batchBytes)
    }

    /// A tree walk with `-l` inflates the same loose blobs for every revision.
    /// Read each immutable object's type and size once within this preparation.
    private func loadMissingSizes(_ missing: Set<String>, engine: GitEngine) async throws -> Int {
        guard !missing.isEmpty else { return 0 }
        guard sizes.count <= 1_000_000 - missing.count else {
            throw RebaseBudget.exceeded
        }
        let requested = missing.sorted()
        var bytes = 0
        for start in stride(from: 0, to: requested.count, by: RebaseBudget.entries) {
            try Task.checkCancellation()
            let batch = requested[start..<min(start + RebaseBudget.entries, requested.count)]
            let raw = try await engine.run(
                ["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)", "--buffer"], in: root,
                input: Data((batch.joined(separator: "\n") + "\n").utf8),
                outputLimit: RebaseBudget.metadataBytes
            ).stdout
            guard raw.count <= 128 * 1024 * 1024 - metadataBytes - bytes else {
                throw RebaseBudget.exceeded
            }
            bytes += raw.count
            guard raw.last == 10, let output = String(data: raw, encoding: .utf8) else {
                throw ModelFailure.changed
            }
            let lines = output.split(separator: "\n")
            guard lines.count == batch.count else { throw ModelFailure.changed }
            for (object, row) in zip(batch, lines) {
                try Task.checkCancellation()
                let fields = row.split(separator: " ")
                guard fields.count == 3, fields[0] == object, fields[1] == "blob", let size = Int(fields[2]),
                    size >= 0
                else { throw ModelFailure.changed }
                sizes[object] = size
            }
        }
        return bytes
    }

    private func store(_ value: [String: RebaseTreeEntry], for revision: String, bytes: Int) throws {
        guard value.count <= RebaseBudget.entries, bytes <= 128 * 1024 * 1024 - metadataBytes,
            value.count <= 1_000_000 - entriesStored
        else { throw RebaseBudget.exceeded }
        metadataBytes += bytes
        entriesStored += value.count
        trees[revision] = value
    }
    private func pathValid(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
            !path.split(separator: "/").contains("..")
        else {
            throw ModelFailure.invalidPath
        }
    }
}

extension RepositoryService {
    func rebaseInputPaths(
        base: String, head: String, other: String, metadata: RebaseTreeMetadata, engine: GitEngine
    ) async throws -> Set<String> {
        let ancestor = try await metadata.entries(base, engine: engine)
        let current = try await metadata.entries(head, engine: engine)
        let incoming = try await metadata.entries(other, engine: engine)
        let all = Set(ancestor.keys).union(current.keys).union(incoming.keys)
        var paths: Set<String> = []
        var seen: Set<String> = []
        var bytes = 0
        for path in all {
            try Task.checkCancellation()
            if ancestor[path] != incoming[path] { paths.insert(path) }
            guard ancestor[path] != current[path] || ancestor[path] != incoming[path] else { continue }
            for entry in [ancestor[path], current[path], incoming[path]].compactMap({ $0 })
            where seen.insert(entry.object).inserted {
                guard entry.bytes <= SingleCommitBudget.changedBlobBytes - bytes else {
                    throw RebaseBudget.exceeded
                }
                bytes += entry.bytes
            }
        }
        guard paths.count <= SingleCommitBudget.files else { throw RebaseBudget.exceeded }
        return paths
    }
}
