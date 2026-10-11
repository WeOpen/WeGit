import Foundation

public struct WordDiffRanges: Sendable, Equatable {
    public let removed: [NSRange]
    public let added: [NSRange]
    let cells: Int
}

/// Display-only ranges into the original UTF-16 strings. Never used to reconstruct patches.
public enum WordDiff {
    private static let tokenizer = try? NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}_]+|\s+|\X"#)
    private struct Token {
        let text: String
        let range: NSRange
    }

    /// nil requests the existing whole-line presentation when the bounded comparison is too large.
    public static func ranges(old: String, new: String, maximumCells: Int = 40_000) -> WordDiffRanges? {
        if old == new { return WordDiffRanges(removed: [], added: [], cells: 0) }
        guard old.utf8.count + new.utf8.count <= 8192, maximumCells > 0,
            let lhs = tokens(old), let rhs = tokens(new)
        else { return nil }
        let width = rhs.count + 1
        let cells = (lhs.count + 1) * width
        guard cells <= min(maximumCells, 40_000), lhs.count <= 256, rhs.count <= 256 else { return nil }
        var lengths = [UInt16](repeating: 0, count: cells)
        for i in lhs.indices.reversed() {
            for j in rhs.indices.reversed() {
                lengths[i * width + j] =
                    lhs[i].text == rhs[j].text
                    ? 1 + lengths[(i + 1) * width + j + 1]
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var i = 0
        var j = 0
        var removed: [NSRange] = []
        var added: [NSRange] = []
        while i < lhs.count && j < rhs.count {
            if lhs[i].text == rhs[j].text {
                i += 1
                j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                append(lhs[i].range, to: &removed)
                i += 1
            } else {
                append(rhs[j].range, to: &added)
                j += 1
            }
        }
        while i < lhs.count {
            append(lhs[i].range, to: &removed)
            i += 1
        }
        while j < rhs.count {
            append(rhs[j].range, to: &added)
            j += 1
        }
        return WordDiffRanges(removed: removed, added: added, cells: cells)
    }

    private static func tokens(_ text: String) -> [Token]? {
        guard let tokenizer else { return nil }
        return tokenizer.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            Token(text: (text as NSString).substring(with: $0.range), range: $0.range)
        }
    }

    private static func append(_ range: NSRange, to ranges: inout [NSRange]) {
        guard range.length > 0 else { return }
        if let last = ranges.last, NSMaxRange(last) == range.location {
            ranges[ranges.count - 1] = NSUnionRange(last, range)
        } else {
            ranges.append(range)
        }
    }
}

public struct DiffHighlighting: Sendable {
    public let syntax: [Int: [SyntaxToken]]
    public let words: [Int: [NSRange]]
    public let fallbackLines: Int

    public static let empty = DiffHighlighting(syntax: [:], words: [:], fallbackLines: 0)

    public func merging(_ other: DiffHighlighting) -> DiffHighlighting {
        DiffHighlighting(
            syntax: syntax.merging(other.syntax) { _, new in new },
            words: words.merging(other.words) { _, new in new },
            fallbackLines: fallbackLines + other.fallbackLines)
    }

    @concurrent
    public static func prepare(_ diff: FileDiff) async throws -> DiffHighlighting {
        try Task.checkCancellation()
        return try await prepare(
            lines: diff.hunks.flatMap(\.lines), pairs: diff.hunks.flatMap { DiffAlignment.rows($0.lines) },
            filename: diff.path)
    }

    @concurrent
    public static func prepare(lines: [DiffLine], pairs: [SplitDiffRow], filename: String) async throws
        -> DiffHighlighting
    {
        var syntax: [Int: [SyntaxToken]] = [:]
        var words: [Int: [NSRange]] = [:]
        var remainingCells = 200_000
        var fallback = 0
        for line in lines {
            try Task.checkCancellation()
            let tokens = SyntaxHighlighter.tokens(line.content, filename: filename)
            if !tokens.isEmpty { syntax[line.id] = tokens }
        }
        for row in pairs {
            try Task.checkCancellation()
            guard let old = row.old, let new = row.new, old.kind == "-", new.kind == "+" else { continue }
            guard
                !old.truncated, !new.truncated,
                let ranges = WordDiff.ranges(
                    old: old.content, new: new.content, maximumCells: remainingCells)
            else {
                fallback += 2
                continue
            }
            remainingCells -= ranges.cells
            if !ranges.removed.isEmpty { words[old.id] = ranges.removed }
            if !ranges.added.isEmpty { words[new.id] = ranges.added }
        }
        return DiffHighlighting(syntax: syntax, words: words, fallbackLines: fallback)
    }
}
