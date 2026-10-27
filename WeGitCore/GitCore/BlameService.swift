import Foundation

extension RepositoryService {
    private var blameEngine: GitEngine {
        var result = engine
        result.environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        result.environment["GIT_NO_LAZY_FETCH"] = "1"
        return result
    }

    @concurrent public func blameDocument(path: String, revision: String) async throws -> BlameDocument {
        try location.validateIdentity()
        try validate(path)
        guard GitObjectID.valid(revision) else { throw ModelFailure.invalidPath }
        let reader = blameEngine
        let type = try await reader.run(["cat-file", "-t", revision], in: location.root).text
            .removingLastNewline
        guard type == "commit" else { throw ModelFailure.invalidPath }
        let tree = try await reader.run(
            ["ls-tree", "-r", "-l", "-z", "--full-tree", revision, "--", path],
            in: location.root, outputLimit: 1024 * 1024
        ).stdout
        let rows = tree.split(separator: 0)
        guard tree.last == 0, rows.count == 1, let row = rows.first, let tab = row.firstIndex(of: 9),
            Data(row[row.index(after: tab)...]) == Data(path.utf8)
        else {
            throw ModelFailure.unsupported(L10n.text("该提交中没有这个文件，请从文件历史选择包含它的版本。"))
        }
        let fields = String(decoding: row[..<tab], as: UTF8.self).split(separator: " ")
        guard fields.count == 4, fields[1] == "blob", ["100644", "100755"].contains(fields[0]),
            GitObjectID.valid(String(fields[2]))
        else { throw BlameParser.binary() }
        guard let size = Int(fields[3]), size >= 0 else {
            throw ModelFailure.unsupported(L10n.text("该版本的 Git 对象不可用，请先手动获取所需对象再重试。"))
        }
        guard size <= BlameReadBudget.bytes else { throw BlameParser.limit() }
        let blob = String(fields[2])
        let data = try await reader.run(
            ["cat-file", "blob", blob], in: location.root, outputLimit: BlameReadBudget.bytes
        ).stdout
        guard data.count == size else { throw ModelFailure.changed }
        let lines = try BlameParser.contentLines(data)
        try location.validateIdentity()
        return BlameDocument(
            id: UUID(), revision: revision, path: path, blob: blob, byteCount: size,
            hasFinalNewline: data.last == 10,
            location: location, contents: lines)
    }

    @concurrent public func blamePage(
        _ document: BlameDocument, firstLine: Int = 1, count: Int = BlameReadBudget.pageLines
    ) async throws -> BlamePage {
        try location.validateIdentity()
        guard document.location == location, (1...BlameReadBudget.pageLines).contains(count),
            firstLine > 0, firstLine <= max(1, document.lineCount)
        else { throw ModelFailure.changed }
        if document.lineCount == 0 {
            return BlamePage(documentID: document.id, lines: [], previousLine: nil, nextLine: nil)
        }
        let last = min(document.lineCount, firstLine + count - 1)
        let reader = blameEngine
        let raw = try await reader.run(
            [
                "blame", "--line-porcelain", "--root", "--no-textconv", "--encoding=UTF-8",
                "--ignore-revs-file", "", "-L", "\(firstLine),\(last)", document.revision, "--",
                document.path,
            ], in: location.root, timeout: 60, outputLimit: BlameReadBudget.metadataBytes
        ).stdout
        let records = try BlameParser.parse(raw, firstLine: firstLine, count: last - firstLine + 1)
        let ids = Array(Set(records.map(\.oid))).sorted()
        let objects = try await reader.run(
            ["cat-file", "--batch"], in: location.root,
            input: Data((ids.joined(separator: "\n") + "\n").utf8), outputLimit: 8 * 1024 * 1024
        ).stdout
        let commits = Dictionary(
            uniqueKeysWithValues: try CommitParser.batch(objects, expected: ids).map { ($0.id, $0) })
        let lines = try records.map { record in
            try Task.checkCancellation()
            try validate(record.path)
            guard let commit = commits[record.oid],
                record.content.utf8.elementsEqual(document.contents[record.line - 1].utf8)
            else {
                throw ModelFailure.changed
            }
            return BlameLine(
                number: record.line, originalNumber: record.originalLine, originalPath: record.path,
                commit: commit, content: record.content)
        }
        try location.validateIdentity()
        return BlamePage(
            documentID: document.id, lines: lines,
            previousLine: firstLine > 1 ? max(1, firstLine - count) : nil,
            nextLine: last < document.lineCount ? last + 1 : nil)
    }
}
