import Foundation

/// Reconstructs only selected change records from the original Git patch.
/// Line IDs come from DiffParser, never from a rendered or wrapped text cell.
public enum SelectedLinePatch {
    public static func make(diff: FileDiff, lineIDs: Set<Int>) throws -> Data {
        guard !lineIDs.isEmpty, !diff.options.ignoreWhitespace, !diff.binary, diff.preview == nil,
            diff.layer == .unstaged || diff.layer == .staged,
            !diff.header.contains("rename from"), !diff.header.contains("old mode")
        else { throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。")) }
        var sourceOffset = 0
        func consume(_ text: String) throws -> Data {
            let expected = Data(text.utf8)
            guard expected.count <= diff.raw.count - sourceOffset else { throw ModelFailure.changed }
            let actual = diff.raw.subdata(in: sourceOffset..<(sourceOffset + expected.count))
            guard actual == expected else { throw ModelFailure.changed }
            sourceOffset += expected.count
            return actual
        }
        let rawHeader = try consume(diff.header)
        let changeIDs = Set(diff.hunks.flatMap(\.lines).filter { $0.kind == "+" || $0.kind == "-" }.map(\.id))
        let modifiesNewOrDeletedFile =
            (diff.layer == .staged && diff.header.contains("new file mode"))
            || (diff.layer == .unstaged && diff.header.contains("deleted file mode"))
        var output =
            modifiesNewOrDeletedFile && lineIDs != changeIDs
            ? try modificationHeader(rawHeader) : rawHeader
        var found: Set<Int> = []
        var priorDelta = 0
        for hunk in diff.hunks {
            try Task.checkCancellation()
            let bytes = try consume(hunk.raw)
            let rows = bytes.split(separator: 10, omittingEmptySubsequences: false)
            guard rows.last?.isEmpty == true, rows.count == hunk.lines.count + 2,
                let header = rows.first, let headerText = String(data: header, encoding: .utf8)
            else { throw ModelFailure.changed }
            let starts = try starts(headerText)
            var records: [Record] = []
            var selectedInHunk = false
            for (row, line) in zip(rows.dropFirst().dropLast(), hunk.lines) {
                guard let kind = row.first, Data(row.dropFirst()) == Data(line.content.utf8),
                    String(UnicodeScalar(kind)) == String(line.kind)
                else { throw ModelFailure.changed }
                if kind == 92 {
                    guard !records.isEmpty, records[records.count - 1].marker == nil else {
                        throw ModelFailure.changed
                    }
                    records[records.count - 1].marker = Data(row)
                    continue
                }
                let selected = lineIDs.contains(line.id)
                if selected {
                    guard kind == 43 || kind == 45 else { throw ModelFailure.changed }
                    found.insert(line.id)
                    selectedInHunk = true
                }
                records.append(Record(kind: kind, raw: Data(row), selected: selected))
            }
            guard selectedInHunk else { continue }
            var body = Data()
            var oldCount = 0
            var newCount = 0
            func emit(_ record: Record, as kind: UInt8) {
                body.append(kind)
                body.append(record.raw.dropFirst())
                body.append(10)
                if let marker = record.marker {
                    body.append(marker)
                    body.append(10)
                }
                if kind != 43 { oldCount += 1 }
                if kind != 45 { newCount += 1 }
            }
            func emitChanges(_ chunk: [Record]) throws {
                let old = chunk.filter { $0.kind == 45 }
                let new = chunk.filter { $0.kind == 43 }
                guard old.count + new.count == chunk.count,
                    chunk.map(\.kind) == old.map(\.kind) + new.map(\.kind)
                else { throw ModelFailure.changed }
                if diff.layer == .unstaged {
                    let additions = new.filter(\.selected)
                    let lastRemoval = old.lastIndex(where: \.selected)
                    if lastRemoval == nil { for record in additions { emit(record, as: 43) } }
                    for (index, record) in old.enumerated() {
                        emit(record, as: record.selected ? 45 : 32)
                        if index == lastRemoval { for addition in additions { emit(addition, as: 43) } }
                    }
                } else {
                    let removals = old.filter(\.selected)
                    let firstAddition = new.firstIndex(where: \.selected)
                    if firstAddition == nil { for record in removals { emit(record, as: 45) } }
                    for (index, record) in new.enumerated() {
                        if index == firstAddition { for removal in removals { emit(removal, as: 45) } }
                        emit(record, as: record.selected ? 43 : 32)
                    }
                }
            }
            var chunk: [Record] = []
            for record in records {
                if record.kind == 32 {
                    try emitChanges(chunk)
                    chunk.removeAll(keepingCapacity: true)
                    emit(record, as: 32)
                } else {
                    chunk.append(record)
                }
            }
            try emitChanges(chunk)
            let oldStart: Int
            let newStart: Int
            if diff.layer == .unstaged {
                oldStart = starts.old
                newStart = oldStart + priorDelta + (oldCount == 0 ? 1 : 0) - (newCount == 0 ? 1 : 0)
                priorDelta += newCount - oldCount
            } else {
                newStart = starts.new
                oldStart = newStart + priorDelta + (newCount == 0 ? 1 : 0) - (oldCount == 0 ? 1 : 0)
                priorDelta += oldCount - newCount
            }
            guard oldStart >= 0, newStart >= 0 else { throw ModelFailure.changed }
            output.append(Data("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n".utf8))
            output.append(body)
        }
        guard sourceOffset == diff.raw.count, found == lineIDs else { throw ModelFailure.changed }
        return output
    }

    /// Compute the desired index bytes separately from Git's patch application.
    /// This checks every anchored source line and rejects impossible EOF combinations.
    public static func expectedIndex(diff: FileDiff, lineIDs: Set<Int>, current: Data) throws -> Data {
        guard current.count <= 8 * 1024 * 1024 else {
            throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。"))
        }
        // Enforce the same raw-byte, layer and selection preconditions first.
        _ = try make(diff: diff, lineIDs: lineIDs)
        var pieces = current.split(separator: 10, omittingEmptySubsequences: false)
        let endsWithNewline = current.last == 10
        if current.isEmpty { pieces = [] } else if endsWithNewline { pieces.removeLast() }
        let original: [IndexLine] = pieces.enumerated().map { index, bytes in
            IndexLine(bytes: Data(bytes), newline: index < pieces.count - 1 || endsWithNewline)
        }
        var result: [IndexLine] = []
        var cursor = 0
        func sourceLine(_ line: DiffLine) throws -> IndexLine {
            guard cursor < original.count else { throw ModelFailure.changed }
            let value = IndexLine(bytes: Data(line.content.utf8), newline: line.hasNewline)
            guard original[cursor] == value else { throw ModelFailure.changed }
            cursor += 1
            return value
        }
        func value(_ line: DiffLine) -> IndexLine {
            IndexLine(bytes: Data(line.content.utf8), newline: line.hasNewline)
        }
        func appendChanges(_ chunk: [DiffLine]) throws {
            let old = chunk.filter { $0.kind == "-" }
            let new = chunk.filter { $0.kind == "+" }
            guard old.count + new.count == chunk.count,
                chunk.map(\.kind) == old.map(\.kind) + new.map(\.kind)
            else { throw ModelFailure.changed }
            if diff.layer == .unstaged {
                let additions = new.filter { lineIDs.contains($0.id) }
                let lastRemoval = old.lastIndex { lineIDs.contains($0.id) }
                if lastRemoval == nil { result.append(contentsOf: additions.map(value)) }
                for (index, line) in old.enumerated() {
                    let source = try sourceLine(line)
                    if !lineIDs.contains(line.id) { result.append(source) }
                    if index == lastRemoval { result.append(contentsOf: additions.map(value)) }
                }
            } else {
                let removals = old.filter { lineIDs.contains($0.id) }
                let firstAddition = new.firstIndex { lineIDs.contains($0.id) }
                if firstAddition == nil { result.append(contentsOf: removals.map(value)) }
                for (index, line) in new.enumerated() {
                    if index == firstAddition { result.append(contentsOf: removals.map(value)) }
                    let source = try sourceLine(line)
                    if !lineIDs.contains(line.id) { result.append(source) }
                }
            }
        }
        for hunk in diff.hunks where hunk.lines.contains(where: { lineIDs.contains($0.id) }) {
            try Task.checkCancellation()
            let originalLines = hunk.lines.filter { $0.kind != "\\" }
            let count = originalLines.count { line in
                line.kind == " " || (diff.layer == .unstaged ? line.kind == "-" : line.kind == "+")
            }
            let position = try starts(hunk.header)
            let anchor = diff.layer == .unstaged ? position.old : position.new
            let target = count == 0 ? anchor : anchor - 1
            guard target >= cursor, target <= original.count else { throw ModelFailure.changed }
            result.append(contentsOf: original[cursor..<target])
            cursor = target
            var chunk: [DiffLine] = []
            for line in originalLines {
                if line.kind == " " {
                    try appendChanges(chunk)
                    chunk.removeAll(keepingCapacity: true)
                    result.append(try sourceLine(line))
                } else {
                    chunk.append(line)
                }
            }
            try appendChanges(chunk)
        }
        result.append(contentsOf: original[cursor...])
        guard result.dropLast().allSatisfy(\.newline) else {
            throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。"))
        }
        var bytes = Data()
        for line in result {
            bytes.append(line.bytes)
            if line.newline { bytes.append(10) }
            guard bytes.count <= 8 * 1024 * 1024 else {
                throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。"))
            }
        }
        return bytes
    }

    private struct IndexLine: Equatable {
        let bytes: Data
        let newline: Bool
    }

    /// Partial changes to a whole-file addition/deletion must be represented as a
    /// modification: the original mode header would create/remove the entire entry.
    private static func modificationHeader(_ header: Data) throws -> Data {
        let lines = header.split(separator: 10, omittingEmptySubsequences: false)
        guard let first = lines.first, first.starts(with: Data("diff --git ".utf8)),
            let old = lines.first(where: { $0.starts(with: Data("--- ".utf8)) }),
            let new = lines.first(where: { $0.starts(with: Data("+++ ".utf8)) })
        else { throw ModelFailure.changed }
        func partner(_ row: Data.SubSequence, from: UInt8, to: UInt8, prefix: String) throws -> Data {
            var path = Data(row.dropFirst(4))
            let position = path.first == 34 ? 1 : 0
            guard path.count > position + 1, path[position] == from, path[position + 1] == 47 else {
                throw ModelFailure.changed
            }
            path[position] = to
            return Data(prefix.utf8) + path
        }
        let oldRow: Data
        let newRow: Data
        if Data(old) == Data("--- /dev/null".utf8) {
            oldRow = try partner(new, from: 98, to: 97, prefix: "--- ")
            newRow = Data(new)
        } else if Data(new) == Data("+++ /dev/null".utf8) {
            oldRow = Data(old)
            newRow = try partner(old, from: 97, to: 98, prefix: "+++ ")
        } else {
            throw ModelFailure.changed
        }
        return Data(first) + Data([10]) + oldRow + Data([10]) + newRow + Data([10])
    }

    private struct Record {
        let kind: UInt8
        let raw: Data
        let selected: Bool
        var marker: Data?
    }

    private static func starts(_ header: String) throws -> (old: Int, new: Int) {
        let regex = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        guard let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
            let oldRange = Range(match.range(at: 1), in: header),
            let newRange = Range(match.range(at: 2), in: header),
            let old = Int(header[oldRange]), let new = Int(header[newRange])
        else { throw ModelFailure.changed }
        return (old, new)
    }
}
