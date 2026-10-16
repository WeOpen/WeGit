import Foundation

public struct DiffContextGap: Identifiable, Hashable, Sendable {
    public let id: Int
    public let oldStart: Int
    public let newStart: Int
    public let count: Int?
    public let expandsUpward: Bool

    private static let rangePattern = try? NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)

    public static func sourceOID(for diff: FileDiff) -> String? {
        guard !diff.binary, diff.preview == nil, !diff.options.ignoreWhitespace,
            diff.layer == .staged || diff.layer == .unstaged || diff.layer == .commit,
            !diff.header.split(separator: "\n").contains(where: { $0.hasSuffix(" 160000") })
        else { return nil }
        for line in diff.header.split(separator: "\n") where line.hasPrefix("index ") {
            let oid = String(line.dropFirst(6).prefix(while: { $0 != "." }))
            if [40, 64].contains(oid.count), oid.allSatisfy({ $0.isHexDigit }),
                oid.contains(where: { $0 != "0" })
            {
                return oid
            }
        }
        return nil
    }

    /// Only unchanged intervals are expanded. Whitespace-filtered patches cannot establish
    /// byte-identical old/new context, so they deliberately have no expandable gaps.
    public static func gaps(for diff: FileDiff) -> [DiffContextGap] {
        guard sourceOID(for: diff) != nil, !diff.hunks.isEmpty, let regex = rangePattern else {
            return []
        }
        var result: [DiffContextGap] = []
        var oldEnd = 0
        var newEnd = 0
        for hunk in diff.hunks {
            guard
                let match = regex.firstMatch(
                    in: hunk.header, range: NSRange(hunk.header.startIndex..., in: hunk.header))
            else { return [] }
            func number(_ group: Int, fallback: Int = 1) -> Int {
                let range = match.range(at: group)
                return range.location == NSNotFound
                    ? fallback : Int((hunk.header as NSString).substring(with: range)) ?? -1
            }
            let oldCount = number(2)
            let newCount = number(4)
            let oldBegin = number(1) - (oldCount == 0 ? 0 : 1)
            let newBegin = number(3) - (newCount == 0 ? 0 : 1)
            guard oldBegin >= oldEnd, newBegin >= newEnd, oldCount >= 0, newCount >= 0,
                oldBegin < Int.max - oldCount, newBegin < Int.max - newCount
            else { return [] }
            let count = oldBegin - oldEnd
            guard count == newBegin - newEnd else { return [] }
            if count > 0 {
                result.append(
                    DiffContextGap(
                        id: hunk.id, oldStart: oldEnd + 1, newStart: newEnd + 1, count: count,
                        expandsUpward: hunk.id == 0))
            }
            oldEnd = oldBegin + oldCount
            newEnd = newBegin + newCount
        }
        // The blob's end is only read when requested; the first screen needs no full-file read.
        result.append(
            DiffContextGap(
                id: diff.hunks.count, oldStart: oldEnd + 1, newStart: newEnd + 1, count: nil,
                expandsUpward: false))
        return result
    }

    public static func gaps(for snapshot: DiskDiffSnapshot) -> [DiffContextGap] {
        guard !snapshot.binary, !snapshot.rawPreview, !snapshot.options.ignoreWhitespace,
            snapshot.layer == .staged || snapshot.layer == .unstaged || snapshot.layer == .commit,
            snapshot.sourceOID != nil, !snapshot.hunks.isEmpty
        else { return [] }
        var result: [DiffContextGap] = []
        var oldEnd = 0
        var newEnd = 0
        for hunk in snapshot.hunks {
            let count = hunk.oldRange.lowerBound - oldEnd
            guard count >= 0, count == hunk.newRange.lowerBound - newEnd,
                hunk.oldRange.upperBound < Int.max, hunk.newRange.upperBound < Int.max
            else { return [] }
            if count > 0 {
                result.append(
                    DiffContextGap(
                        id: hunk.id, oldStart: oldEnd + 1, newStart: newEnd + 1, count: count,
                        expandsUpward: hunk.id == 0))
            }
            oldEnd = hunk.oldRange.upperBound
            newEnd = hunk.newRange.upperBound
        }
        result.append(
            DiffContextGap(
                id: snapshot.hunks.count, oldStart: oldEnd + 1, newStart: newEnd + 1, count: nil,
                expandsUpward: false))
        return result
    }
}

public struct DiffContextPage: Sendable {
    public let lines: [DiffLine]
    public let consumedLines: Int
    public let hasMore: Bool
}

/// Keeps one immutable Git blob, bounded independently of the patch. Never reads live worktree
/// content or reconstructs apply patches from the expanded presentation.
public actor DiffContextReader {
    private let service: RepositoryService
    private let oid: String?
    private let gaps: [DiffContextGap]
    private var source: Data?
    private var diskSource: DiskContextSource?

    public init(diff: FileDiff, service: RepositoryService) {
        self.service = service
        oid = DiffContextGap.sourceOID(for: diff)
        gaps = DiffContextGap.gaps(for: diff)
    }

    public init(snapshot: DiskDiffSnapshot, service: RepositoryService) {
        self.service = service
        oid = snapshot.sourceOID
        gaps = DiffContextGap.gaps(for: snapshot)
    }

    public func page(for gap: DiffContextGap, offset: Int, limit: Int = 20) async throws -> DiffContextPage {
        guard gaps.contains(gap), let oid, offset >= 0, (1...200).contains(limit),
            offset <= (gap.count ?? Int.max), offset < Int.max - gap.oldStart
        else { throw ModelFailure.unsupported(L10n.text("这个范围无法展开上下文。")) }
        try Task.checkCancellation()
        if source == nil && diskSource == nil {
            try service.location.validateIdentity()
            let sizeText = try await service.engine.run(
                ["cat-file", "-s", oid], in: service.location.root
            ).text.removingLastNewline
            guard let size = Int(sizeText), size >= 0 else {
                throw ModelFailure.invalidOutput(L10n.text("无法读取上下文对象大小"))
            }
            guard size <= DiskDiffBudget.bytes else {
                throw DiffContentLimit.bytes(DiskDiffBudget.bytes)
            }
            if size > DiffReadBudget.patchBytes {
                diskSource = try await DiskContextSource.readBlob(oid, service: service)
            } else {
                let data = try await service.engine.run(
                    ["cat-file", "blob", oid], in: service.location.root,
                    outputLimit: DiffReadBudget.patchBytes
                ).stdout
                try Task.checkCancellation()
                guard data.count == size, !data.contains(0) else {
                    throw ModelFailure.unsupported(L10n.text("此对象不支持文本上下文。"))
                }
                source = data
            }
        }
        let requested = min(limit, gap.count.map { $0 - offset } ?? limit)
        let start =
            gap.expandsUpward
            ? gap.oldStart + (gap.count ?? 0) - offset - requested : gap.oldStart + offset
        if let diskSource {
            return try await diskSource.page(gap: gap, start: start, count: requested, consumed: offset)
        }
        guard let source else { throw ModelFailure.changed }
        var lines: [DiffLine] = []
        var consumed = 0
        var lineNumber = 1
        var beginning = 0
        var fileHasMore = false
        func appendLine(ending: Int, newline: Bool) throws {
            guard lineNumber >= start, consumed < requested else { return }
            guard let text = String(data: source[beginning..<ending], encoding: .utf8) else {
                throw ModelFailure.unsupported(L10n.text("上下文包含不受支持的文本编码。"))
            }
            let delta = lineNumber - gap.oldStart
            guard gap.newStart <= Int.max - delta else {
                throw ModelFailure.invalidOutput(L10n.text("上下文行号超出范围"))
            }
            let newNumber = gap.newStart + delta
            lines.append(
                DiffLine(
                    id: -(lineNumber * 2), kind: " ", content: text,
                    oldLine: lineNumber, newLine: newNumber, hasNewline: newline))
            consumed += 1
            if !newline {
                lines.append(
                    DiffLine(
                        id: -(lineNumber * 2 + 1), kind: "\\", content: " No newline at end of file",
                        oldLine: nil, newLine: nil))
            }
        }
        if requested > 0 {
            for index in source.indices {
                if index.isMultiple(of: 16_384) { try Task.checkCancellation() }
                guard source[index] == 10 else { continue }
                try appendLine(ending: index, newline: true)
                beginning = index + 1
                lineNumber += 1
                if consumed == requested {
                    fileHasMore = beginning < source.count
                    break
                }
            }
            if consumed < requested && beginning < source.count {
                try appendLine(ending: source.count, newline: false)
            }
        }
        if gap.count != nil && consumed != requested {
            throw ModelFailure.invalidOutput(L10n.text("上下文范围与补丁对象不一致"))
        }
        return DiffContextPage(
            lines: lines, consumedLines: consumed,
            hasMore: gap.count.map { offset + consumed < $0 } ?? fileHasMore)
    }
}
