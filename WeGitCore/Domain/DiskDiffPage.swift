import Darwin
import Foundation

public struct DiskDiffCursor: Sendable, Equatable {
    let snapshot: UUID
    let split: Bool
    var region = 0
    var row = 0
    var rawOffset = 0
    var rawLine = 1
    var displayed = 0
}

public enum DiskDiffRow: Identifiable, Sendable {
    case hunk(DiskDiffHunk)
    case line(DiffLine)
    case split(SplitDiffRow)
    public var id: DiffDisplayRow.ID {
        switch self {
        case .hunk(let hunk): .hunk(hunk.id)
        case .line(let line): .line(line.id)
        case .split(let row): .line(row.id)
        }
    }
}

public struct DiskDiffPage: Sendable {
    public let rows: [DiskDiffRow]
    public let highlighting: DiffHighlighting
    public let start: DiskDiffCursor
    public let next: DiskDiffCursor?
    public let firstLine: Int
    public let lastLine: Int
    public let completedHunks: Set<Int>
    public let bytesRead: Int
    public let firstHunkContinues: Bool
}

extension DiskDiffSnapshot {
    /// Jump through the sparse hunk index. Earlier pages are neither read nor highlighted.
    public func page(atHunk id: Int, split: Bool = false, count: Int = DiffReadBudget.pageRows) async throws
        -> DiskDiffPage
    {
        guard
            let index = regions.firstIndex(where: { region in
                if case .header(let hunk) = region.content { return hunk == id }
                return false
            })
        else { throw ModelFailure.changed }
        var cursor = DiskDiffCursor(snapshot: self.id, split: split)
        cursor.region = index
        cursor.displayed = regions[..<index].reduce(0) { $0 + (split ? $1.splitCount : $1.unifiedCount) }
        return try await page(from: cursor, split: split, count: count)
    }

    public func page(
        from cursor: DiskDiffCursor? = nil, split: Bool = false, count: Int = DiffReadBudget.pageRows
    )
        async throws -> DiskDiffPage
    {
        let start = cursor ?? DiskDiffCursor(snapshot: id, split: split)
        guard start.snapshot == id, start.split == split, (2...2_000).contains(count),
            start.region >= 0, start.region <= regions.count, start.row >= 0
        else { throw ModelFailure.changed }
        let draft = try await SnapshotIO.run { cancellation in
            var next = start
            var rows: [DiskDiffRow] = []
            var lines: [DiffLine] = []
            var pairs: [SplitDiffRow] = []
            var completed: Set<Int> = []
            var bytesRead = 0
            if binary {
                return PageDraft(
                    rows: [], lines: [], pairs: [], next: nil, completed: [], lastLine: 0, bytesRead: 0)
            }
            if rawPreview {
                let reader = try SnapshotLineReader(
                    file: file, offset: next.rawOffset, chunkSize: 4096, cancellation: cancellation)
                while rows.count < count, let raw = try reader.next() {
                    let line = DiffLine(
                        id: raw.offset, kind: " ",
                        content: try UTF8DisplayPrefix.decode(raw.prefix, truncated: raw.truncated),
                        oldLine: nil, newLine: next.rawLine, truncated: raw.truncated,
                        hasNewline: raw.terminated)
                    rows.append(.line(line))
                    lines.append(line)
                    next.rawOffset = raw.nextOffset
                    next.rawLine += 1
                    next.displayed += 1
                }
                try reader.validate()
                return PageDraft(
                    rows: rows, lines: lines, pairs: [], next: next.rawOffset < byteCount ? next : nil,
                    completed: [], lastLine: next.displayed, bytesRead: reader.bytesRead)
            }

            // Keep the hunk heading available on continuation pages as well as its first page.
            if next.region < regions.count, case .header = regions[next.region].content {
            } else if next.region < regions.count {
                rows.append(.hunk(hunks[regions[next.region].hunkID]))
            }
            func read(_ run: DiskLineRun?, at index: Int, amount: Int) throws -> [DiffLine] {
                guard let run, amount > 0, index < run.count else { return [] }
                let requested = min(amount, run.count - index)
                let checkpoint = run.checkpoints.last(where: { $0.line <= index })!
                let reader = try SnapshotLineReader(
                    file: file, offset: checkpoint.offset, chunkSize: 4096, cancellation: cancellation)
                for _ in checkpoint.line..<index {
                    guard try reader.next(prefixLimit: 1) != nil else { throw ModelFailure.changed }
                }
                var result: [DiffLine] = []
                for position in index..<(index + requested) {
                    guard let raw = try reader.next(prefixLimit: DiskDiffBudget.prefixBytes + 1),
                        raw.prefix.first == run.kind, raw.nextOffset <= run.endOffset
                    else { throw ModelFailure.changed }
                    result.append(
                        DiffLine(
                            id: raw.offset, kind: Character(UnicodeScalar(run.kind)),
                            content: try UTF8DisplayPrefix.decode(
                                Data(raw.prefix.dropFirst()), truncated: raw.truncated),
                            oldLine: run.oldStart.map { $0 + position },
                            newLine: run.newStart.map { $0 + position },
                            truncated: raw.truncated, hasNewline: !noNewlineOffsets.contains(raw.nextOffset)))
                }
                try reader.validate()
                bytesRead += reader.bytesRead
                return result
            }

            while next.region < regions.count && rows.count < count {
                try cancellation.check()
                let region = regions[next.region]
                if case .header(let id) = region.content {
                    rows.append(.hunk(hunks[id]))
                    next.region += 1
                    continue
                }
                let total = split ? region.splitCount : region.unifiedCount
                guard next.row < total else { throw ModelFailure.changed }
                let amount = min(count - rows.count, total - next.row)
                switch region.content {
                case .unchanged(let run), .marker(let run):
                    let selected = try read(run, at: next.row, amount: amount)
                    lines += selected
                    rows += selected.map { split ? .split(SplitDiffRow(context: $0)) : .line($0) }
                case .change(let old, let new):
                    if split {
                        let lhs = try read(old, at: next.row, amount: amount)
                        let rhs = try read(new, at: next.row, amount: amount)
                        lines += lhs + rhs
                        for index in 0..<amount {
                            let left = index < lhs.count ? lhs[index] : nil
                            let right = index < rhs.count ? rhs[index] : nil
                            guard let id = left?.id ?? right?.id else { throw ModelFailure.changed }
                            let pair = SplitDiffRow(id: id, old: left, new: right)
                            pairs.append(pair)
                            rows.append(.split(pair))
                        }
                    } else {
                        let oldCount = old?.count ?? 0
                        let takeOld = min(amount, max(0, oldCount - next.row))
                        let oldIndex = min(next.row, oldCount)
                        let newIndex = max(0, next.row - oldCount)
                        let lhs = try read(old, at: oldIndex, amount: takeOld)
                        let rhs = try read(new, at: newIndex, amount: amount - takeOld)
                        lines += lhs + rhs
                        rows += (lhs + rhs).map(DiskDiffRow.line)
                        // Counterpart lines are fetched through sparse checkpoints, even when
                        // the added half of a replacement lies many megabytes after the removed half.
                        let matchingNew = try read(new, at: oldIndex, amount: lhs.count)
                        for index in 0..<min(lhs.count, matchingNew.count) {
                            pairs.append(
                                SplitDiffRow(id: lhs[index].id, old: lhs[index], new: matchingNew[index]))
                        }
                        let matchingOld = try read(old, at: newIndex, amount: rhs.count)
                        for index in 0..<min(rhs.count, matchingOld.count) {
                            pairs.append(
                                SplitDiffRow(
                                    id: matchingOld[index].id, old: matchingOld[index], new: rhs[index]))
                        }
                    }
                case .header: break
                }
                next.row += amount
                next.displayed += amount
                if next.row == total {
                    next.row = 0
                    next.region += 1
                    if next.region == regions.count || regions[next.region].hunkID != region.hunkID {
                        completed.insert(region.hunkID)
                    }
                }
            }
            let fd = try file.open()
            Darwin.close(fd)
            return PageDraft(
                rows: rows, lines: lines, pairs: pairs, next: next.region < regions.count ? next : nil,
                completed: completed, lastLine: next.displayed, bytesRead: bytesRead)
        }
        let highlighting = try await DiffHighlighting.prepare(
            lines: draft.lines, pairs: draft.pairs, filename: path)
        try Task.checkCancellation()
        return DiskDiffPage(
            rows: draft.rows, highlighting: highlighting, start: start, next: draft.next,
            firstLine: draft.lastLine > start.displayed ? start.displayed + 1 : 0, lastLine: draft.lastLine,
            completedHunks: draft.completed, bytesRead: draft.bytesRead,
            firstHunkContinues: start.region < regions.count
                && {
                    if case .header = regions[start.region].content { return false }
                    return true
                }())
    }
}

private struct PageDraft: Sendable {
    let rows: [DiskDiffRow]
    let lines: [DiffLine]
    let pairs: [SplitDiffRow]
    let next: DiskDiffCursor?
    let completed: Set<Int>
    let lastLine: Int
    let bytesRead: Int
}
