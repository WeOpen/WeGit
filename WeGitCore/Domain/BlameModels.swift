import Foundation

public enum BlameReadBudget {
    public static let bytes = 8 * 1024 * 1024
    public static let lines = 100_000
    public static let lineBytes = 8192
    public static let pageLines = 200
    static let metadataBytes = 16 * 1024 * 1024
}

public struct BlameDocument: Sendable, Identifiable {
    public let id: UUID
    public let revision: String
    public let path: String
    public let blob: String
    public let byteCount: Int
    public let hasFinalNewline: Bool
    public var lineCount: Int { contents.count }
    let location: RepositoryLocation
    let contents: [String]
}

public struct BlameLine: Identifiable, Sendable {
    public let number: Int
    public let originalNumber: Int
    public let originalPath: String
    public let commit: GitCommit
    public let content: String
    public var id: Int { number }
}

public struct BlamePage: Sendable {
    public let documentID: UUID
    public let lines: [BlameLine]
    public let previousLine: Int?
    public let nextLine: Int?
}

enum BlameParser {
    struct Record {
        let oid: String
        let originalLine: Int
        let line: Int
        let path: String
        let content: String
    }

    static func contentLines(_ data: Data) throws -> [String] {
        guard data.count <= BlameReadBudget.bytes else { throw limit() }
        if data.isEmpty { return [] }
        var lineBytes = 0
        var count = 0
        for (offset, byte) in data.enumerated() {
            if offset & 4095 == 0 { try Task.checkCancellation() }
            if byte == 0 { throw binary() }
            if byte == 10 {
                count += 1
                lineBytes = 0
            } else {
                lineBytes += 1
            }
            guard count <= BlameReadBudget.lines, lineBytes <= BlameReadBudget.lineBytes else {
                throw limit()
            }
        }
        if data.last != 10 { count += 1 }
        guard count <= BlameReadBudget.lines else { throw limit() }
        var rows = data.split(separator: 10, omittingEmptySubsequences: false)
        if data.last == 10 { rows.removeLast() }
        return try rows.map { row in
            // Split bytes, not Swift Characters: CRLF is one grapheme cluster.
            guard let value = String(data: row, encoding: .utf8) else { throw binary() }
            return value
        }
    }

    static func parse(_ data: Data, firstLine: Int, count: Int) throws -> [Record] {
        guard data.last == 10 else { throw malformed() }
        let rows = data.split(separator: 10, omittingEmptySubsequences: false)
        var index = 0
        var records: [Record] = []
        while index < rows.count - 1 {
            try Task.checkCancellation()
            let header = String(decoding: rows[index], as: UTF8.self).split(separator: " ")
            guard (3...4).contains(header.count), GitObjectID.valid(String(header[0])),
                header[0].contains(where: { $0 != "0" }),
                let original = Int(header[1]), original > 0,
                let line = Int(header[2]), line == firstLine + records.count,
                header.count != 4 || Int(header[3]).map({ $0 > 0 }) == true
            else { throw malformed() }
            index += 1
            var path: String?
            while index < rows.count - 1, rows[index].first != 9 {
                guard rows[index].count <= 16 * 1024 else { throw limit() }
                if rows[index].starts(with: Data("filename ".utf8)) {
                    guard path == nil else { throw malformed() }
                    path = try unquotePath(Data(rows[index].dropFirst(9)))
                }
                index += 1
            }
            guard let path, index < rows.count - 1, rows[index].first == 9,
                let content = String(data: rows[index].dropFirst(), encoding: .utf8),
                records.count < count
            else { throw malformed() }
            records.append(
                Record(
                    oid: String(header[0]), originalLine: original, line: line, path: path, content: content))
            index += 1
        }
        guard records.count == count else { throw malformed() }
        return records
    }

    private static func unquotePath(_ data: Data) throws -> String {
        var bytes: [UInt8] = []
        if data.first == 34 {
            guard data.count >= 2, data.last == 34 else { throw malformed() }
            let source = Array(data.dropFirst().dropLast())
            var index = 0
            let escapes: [UInt8: UInt8] = [
                97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13, 34: 34, 92: 92,
            ]
            while index < source.count {
                let value = source[index]
                index += 1
                if value != 92 {
                    bytes.append(value)
                    continue
                }
                guard index < source.count else { throw malformed() }
                let escaped = source[index]
                index += 1
                if let value = escapes[escaped] {
                    bytes.append(value)
                } else {
                    guard (48...51).contains(escaped), index + 1 < source.count,
                        (48...55).contains(source[index]), (48...55).contains(source[index + 1])
                    else { throw malformed() }
                    bytes.append((escaped - 48) * 64 + (source[index] - 48) * 8 + (source[index + 1] - 48))
                    index += 2
                }
            }
        } else {
            bytes = Array(data)
        }
        guard let path = String(bytes: bytes, encoding: .utf8), !path.isEmpty, !path.contains("\0"),
            !path.hasPrefix("/"), !path.split(separator: "/").contains("..")
        else { throw malformed() }
        return path
    }

    static func limit() -> ModelFailure {
        .unsupported(L10n.text("文件或归属信息超过读取上限：8 MiB、100000 行、单行 8192 字节。"))
    }
    static func binary() -> ModelFailure {
        .unsupported(L10n.text("逐行归属仅支持 UTF-8 文本文件。"))
    }
    private static func malformed() -> ModelFailure {
        .invalidOutput(L10n.text("逐行归属记录无法与文件内容对应"))
    }
}
