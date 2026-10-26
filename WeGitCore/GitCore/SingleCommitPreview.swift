import Foundation

struct SingleCommitMergePreview: Sendable {
    let tree: String
    let conflicts: [String]
    let paths: Set<String>

    init(_ result: ProcessResult) throws {
        let fields = result.stdout.split(separator: 0, omittingEmptySubsequences: false)
        guard result.stdout.last == 0, let first = fields.first,
            let tree = String(data: first, encoding: .utf8), GitObjectID.valid(tree)
        else { throw ModelFailure.invalidOutput(L10n.text("合并预览记录不完整")) }
        self.tree = tree
        var index = 1
        var conflicts: [String] = []
        var paths: Set<String> = []
        func path(_ bytes: Data.SubSequence) throws -> String {
            guard let value = String(data: bytes, encoding: .utf8), !value.isEmpty,
                !value.hasPrefix("/"), !value.split(separator: "/").contains("..")
            else { throw ModelFailure.invalidPath }
            return value
        }
        while index < fields.count, !fields[index].isEmpty {
            let name = try path(fields[index])
            conflicts.append(name)
            paths.insert(name)
            index += 1
        }
        index += 1
        // Git's -z message section has a path count, the paths, conflict type,
        // and prose. Never split the paths or infer a target from the prose.
        let supportedConflicts: Set<String> = [
            "CONFLICT (contents)", "CONFLICT (add/add)", "CONFLICT (modify/delete)",
            "CONFLICT (binary)", "CONFLICT (directory rename suggested)",
        ]
        while index < fields.count - 1 {
            guard let count = Int(String(decoding: fields[index], as: UTF8.self)),
                (1...SingleCommitBudget.files).contains(count), index + count + 2 < fields.count - 1
            else { throw ModelFailure.invalidOutput(L10n.text("合并预览记录不完整")) }
            index += 1
            for _ in 0..<count {
                paths.insert(try path(fields[index]))
                index += 1
            }
            let kind = String(decoding: fields[index], as: UTF8.self)
            if kind.hasPrefix("CONFLICT"), !supportedConflicts.contains(kind) {
                // Structural conflicts can invent filenames whose suffix depends
                // on Git's command labels. Do not guess their overwrite scope.
                throw ModelFailure.unsupported(
                    L10n.text("此提交存在文件类型或复杂重命名冲突，请在 Terminal 中处理。"))
            }
            index += 2
        }
        guard conflicts.count <= SingleCommitBudget.files, paths.count <= SingleCommitBudget.files,
            (result.exitCode == 0) == conflicts.isEmpty
        else { throw SingleCommitBudget.exceeded }
        self.conflicts = conflicts.sorted()
        self.paths = paths
    }
}

private struct SingleCommitTreeEntry: Equatable {
    let object: String
    let size: Int
    let mode: String
}

extension RepositoryService {
    var singleCommitEngine: GitEngine {
        var value = engine
        value.environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        value.environment["GIT_NO_LAZY_FETCH"] = "1"
        return value
    }

    func singleCommitTree(_ revision: String, engine: GitEngine) async throws -> String {
        guard GitObjectID.valid(revision) else { throw ModelFailure.invalidPath }
        let tree = try await engine.run(
            ["rev-parse", "--verify", revision + "^{tree}"], in: location.root
        ).text.removingLastNewline
        guard GitObjectID.valid(tree) else { throw ModelFailure.changed }
        return tree
    }

    func singleCommitIndex() async throws -> (raw: Data, paths: Set<String>) {
        let raw = try await singleCommitEngine.run(
            ["ls-files", "--stage", "-v", "-z"], in: location.root,
            outputLimit: SingleCommitBudget.metadataBytes
        ).stdout
        guard raw.isEmpty || raw.last == 0 else { throw ModelFailure.changed }
        var paths: Set<String> = []
        for row in raw.split(separator: 0) {
            guard let tab = row.firstIndex(of: 9),
                let header = String(data: row[..<tab], encoding: .utf8),
                let path = String(data: row[row.index(after: tab)...], encoding: .utf8)
            else { throw ModelFailure.changed }
            let fields = header.split(separator: " ")
            guard fields.count == 4, fields[0] == "H", fields[3] == "0",
                ["100644", "100755", "120000"].contains(fields[1])
            else {
                throw ModelFailure.unsupported(
                    L10n.text("请先处理特殊索引标记、未合并条目或子模块，再执行此操作。"))
            }
            try validate(path)
            paths.insert(path)
        }
        guard paths.count <= SingleCommitBudget.entries else { throw SingleCommitBudget.exceeded }
        return (raw, paths)
    }

    /// Limit every blob that either side changed, including rename-detection inputs.
    /// Reading tree metadata does not decode content or materialize a working tree.
    func singleCommitInputPaths(base: String, head: String, other: String, engine: GitEngine) async throws
        -> Set<String>
    {
        func entries(_ revision: String) async throws -> [String: SingleCommitTreeEntry] {
            let raw = try await engine.run(
                ["ls-tree", "-r", "-l", "-z", "--full-tree", revision], in: location.root,
                outputLimit: SingleCommitBudget.metadataBytes
            ).stdout
            guard raw.isEmpty || raw.last == 0 else { throw ModelFailure.changed }
            var result: [String: SingleCommitTreeEntry] = [:]
            for row in raw.split(separator: 0) {
                guard let tab = row.firstIndex(of: 9),
                    let header = String(data: row[..<tab], encoding: .utf8),
                    let path = String(data: row[row.index(after: tab)...], encoding: .utf8)
                else { throw ModelFailure.changed }
                let fields = header.split(separator: " ")
                guard fields.count == 4, fields[1] == "blob", GitObjectID.valid(String(fields[2])),
                    let size = Int(fields[3]), size >= 0
                else {
                    throw ModelFailure.unsupported(L10n.text("当前操作暂不支持包含子模块的提交。"))
                }
                try validate(path)
                result[path] = SingleCommitTreeEntry(
                    object: String(fields[2]), size: size, mode: String(fields[0]))
            }
            guard result.count <= SingleCommitBudget.entries else { throw SingleCommitBudget.exceeded }
            return result
        }
        let ancestor = try await entries(base)
        let current = try await entries(head)
        let incoming = try await entries(other)
        let all = Set(ancestor.keys).union(current.keys).union(incoming.keys)
        var size = 0
        var seen: Set<String> = []
        var sourcePaths: Set<String> = []
        for path in all {
            try Task.checkCancellation()
            if ancestor[path] != incoming[path] { sourcePaths.insert(path) }
            guard ancestor[path] != current[path] || ancestor[path] != incoming[path] else { continue }
            for item in [ancestor[path], current[path], incoming[path]].compactMap({ $0 })
            where seen.insert(item.object).inserted {
                guard item.size <= SingleCommitBudget.changedBlobBytes - size else {
                    throw SingleCommitBudget.exceeded
                }
                size += item.size
            }
        }
        guard sourcePaths.count <= SingleCommitBudget.files else { throw SingleCommitBudget.exceeded }
        return sourcePaths
    }

    func singleCommitChanges(from: String, to: String, engine: GitEngine) async throws
        -> [SingleCommitFileChange]
    {
        let raw = try await engine.run(
            [
                "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-status", "-z", from, to,
                "--",
            ],
            in: location.root, outputLimit: SingleCommitBudget.metadataBytes
        ).stdout
        guard raw.isEmpty || raw.last == 0 else { throw ModelFailure.changed }
        let fields = raw.split(separator: 0)
        guard fields.count % 2 == 0, fields.count / 2 <= SingleCommitBudget.files else {
            throw SingleCommitBudget.exceeded
        }
        return try stride(from: 0, to: fields.count, by: 2).map { index in
            let code = String(decoding: fields[index], as: UTF8.self)
            guard code.count == 1, let status = code.first, "ADMT".contains(status),
                let path = String(data: fields[index + 1], encoding: .utf8)
            else { throw ModelFailure.changed }
            try validate(path)
            return SingleCommitFileChange(path: path, status: status)
        }
    }

    /// Git alternates use C-quoted paths; literal colons and newlines must survive.
    func singleCommitAlternatePath(_ path: String) -> String {
        "\""
            + path.utf8.map { byte -> String in
                switch byte {
                case 34: return "\\\""
                case 92: return "\\\\"
                case 0...31, 127...255: return String(format: "\\%03o", byte)
                default: return String(UnicodeScalar(byte))
                }
            }.joined() + "\""
    }
}
