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
        for revision in Set(revisions).sorted() where trees[revision] == nil {
            try Task.checkCancellation()
            let tree = try await readTree(revision, engine: engine)
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

    private func readTree(_ revision: String, engine: GitEngine) async throws
        -> (records: [String: (object: String, mode: String)], bytes: Int)
    {
        guard GitObjectID.valid(revision) else { throw ModelFailure.invalidPath }
        let raw = try await engine.run(
            ["ls-tree", "-r", "-z", "--full-tree", revision], in: root,
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
            guard fields.count == 3, fields[1] == "blob", GitObjectID.valid(String(fields[2])),
                ["100644", "100755", "120000"].contains(fields[0])
            else { throw ModelFailure.unsupported(L10n.text("此变基范围包含子模块或未支持的树记录，请在 Terminal 中处理。")) }
            try pathValid(path)
            guard records[path] == nil else { throw ModelFailure.changed }
            guard records.count < RebaseBudget.entries else { throw RebaseBudget.exceeded }
            let object = String(fields[2])
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
        var value = try await entries(previous, engine: engine)
        let raw = try await engine.run(
            [
                "diff-tree", "-r", "--no-commit-id", "--raw", "--no-abbrev", "-z", "--no-renames",
                "--no-ext-diff", "--no-textconv", previous, tree, "--",
            ], in: root,
            outputLimit: RebaseBudget.metadataBytes
        ).stdout
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
