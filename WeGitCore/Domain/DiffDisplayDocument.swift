import Foundation

public enum DiffDisplayRow: Identifiable, Sendable {
    case hunk(DiffHunk)
    case line(DiffLine)
    case split(SplitDiffRow)
    case gap(DiffContextGap)

    public enum ID: Hashable, Sendable {
        case hunk(Int)
        case line(Int)
        case gap(Int)
    }
    public var id: ID {
        switch self {
        case .hunk(let hunk): .hunk(hunk.id)
        case .line(let line): .line(line.id)
        case .split(let row): .line(row.id)
        case .gap(let gap): .gap(gap.id)
        }
    }
    public var isContent: Bool {
        switch self {
        case .line, .split: true
        case .hunk, .gap: false
        }
    }
}

public struct DiffDisplayPage: Sendable {
    public let rows: [DiffDisplayRow]
    public let highlighting: DiffHighlighting
    public let nextOffset: Int
}

/// A bounded, complete patch is parsed once. Only requested display pages get highlighting
/// and SwiftUI rows. This is presentation paging, not streaming Git's patch output.
public struct DiffDisplayDocument: Sendable {
    public let rows: [DiffDisplayRow]
    public let contentRows: Int
    private let pairs: [Int: SplitDiffRow]
    private let path: String

    @concurrent
    public static func prepare(_ diff: FileDiff, split: Bool) async throws -> DiffDisplayDocument {
        var rows: [DiffDisplayRow] = []
        var pairs: [Int: SplitDiffRow] = [:]
        let gaps = Dictionary(uniqueKeysWithValues: DiffContextGap.gaps(for: diff).map { ($0.id, $0) })
        if let preview = diff.preview {
            let lines = (preview as NSString).components(separatedBy: "\n")
            for (id, text) in lines.enumerated() {
                if id.isMultiple(of: 256) { try Task.checkCancellation() }
                if id == lines.count - 1 && text.isEmpty { continue }
                rows.append(
                    .line(
                        DiffLine(
                            id: id, kind: " ", content: text, oldLine: nil, newLine: id + 1,
                            hasNewline: id < lines.count - 1)))
            }
        } else {
            for hunk in diff.hunks {
                try Task.checkCancellation()
                if let gap = gaps[hunk.id] { rows.append(.gap(gap)) }
                rows.append(.hunk(hunk))
                let aligned = DiffAlignment.rows(hunk.lines)
                for row in aligned {
                    if let old = row.old, let new = row.new, old.kind == "-", new.kind == "+" {
                        pairs[old.id] = row
                        pairs[new.id] = row
                    }
                }
                if split {
                    rows += aligned.map(DiffDisplayRow.split)
                } else {
                    rows += hunk.lines.map(DiffDisplayRow.line)
                }
            }
            if let gap = gaps[diff.hunks.count] { rows.append(.gap(gap)) }
        }
        try Task.checkCancellation()
        return DiffDisplayDocument(
            rows: rows, contentRows: rows.count(where: \.isContent), pairs: pairs, path: diff.path)
    }

    @concurrent
    public func page(from offset: Int, count: Int = DiffReadBudget.pageRows) async throws -> DiffDisplayPage {
        guard offset >= 0, offset <= rows.count, (1...2_000).contains(count) else {
            throw ModelFailure.unsupported(L10n.text("差异显示范围无效。"))
        }
        try Task.checkCancellation()
        let end = offset + min(count, rows.count - offset)
        let selected = Array(rows[offset..<end])
        var lines: [Int: DiffLine] = [:]
        var selectedPairs: [Int: SplitDiffRow] = [:]
        func include(_ line: DiffLine?) {
            guard let line else { return }
            lines[line.id] = line
            if let pair = pairs[line.id] { selectedPairs[pair.id] = pair }
        }
        for row in selected {
            switch row {
            case .line(let line): include(line)
            case .split(let pair):
                include(pair.old)
                include(pair.new)
            case .hunk, .gap: break
            }
        }
        let highlighting = try await DiffHighlighting.prepare(
            lines: lines.values.sorted { $0.id < $1.id },
            pairs: selectedPairs.values.sorted { $0.id < $1.id }, filename: path)
        return DiffDisplayPage(rows: selected, highlighting: highlighting, nextOffset: end)
    }
}
