import Foundation

public enum DiskDiffBudget {
    public static let bytes = 256 * 1024 * 1024
    public static let lines = 2_000_000
    public static let regions = 100_000
    public static let prefixBytes = 8192
    public static let headerBytes = 512
}

public struct DiskDiffHunk: Identifiable, Sendable, Hashable {
    public let id: Int
    public let header: String
    public let byteRange: Range<Int>
    public let oldRange: Range<Int>
    public let newRange: Range<Int>
}

struct DiskLineRun: Sendable {
    let offset: Int
    var endOffset: Int
    var count: Int
    let kind: UInt8
    let oldStart: Int?
    let newStart: Int?
    var checkpoints: [DiskLineCheckpoint]
}

enum DiskRegionContent: Sendable {
    case header(Int)
    case unchanged(DiskLineRun)
    case change(old: DiskLineRun?, new: DiskLineRun?)
    case marker(DiskLineRun)
}

struct DiskDiffRegion: Sendable {
    let hunkID: Int
    var content: DiskRegionContent
    var unifiedCount: Int {
        switch content {
        case .header: 0
        case .unchanged(let run), .marker(let run): run.count
        case .change(let old, let new): (old?.count ?? 0) + (new?.count ?? 0)
        }
    }
    var splitCount: Int {
        switch content {
        case .header: 0
        case .unchanged(let run), .marker(let run): run.count
        case .change(let old, let new): max(old?.count ?? 0, new?.count ?? 0)
        }
    }
}

struct DiskLineCheckpoint: Sendable {
    let line: Int
    let offset: Int
}

/// An immutable, file-backed snapshot. The index contains ranges and counts, never every
/// line's text. Its private file stays alive while any view or operation holds the snapshot.
public struct DiskDiffSnapshot: Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let layer: DiffLayer
    public let options: DiffReadOptions
    public let head: String?
    public let digest: String
    public let byteCount: Int
    public let binary: Bool
    public let rawPreview: Bool
    public let additions: Int
    public let deletions: Int
    public let hunks: [DiskDiffHunk]
    public let unifiedRows: Int
    public let splitRows: Int
    public let canApplyHunk: Bool
    let file: SnapshotFile
    let regions: [DiskDiffRegion]
    let noNewlineOffsets: Set<Int>
    let rawLineCount: Int
    let checkpoints: [DiskLineCheckpoint]
    let headerEnd: Int
    let sourceOID: String?

    static func index(
        file: SnapshotFile, path: String, layer: DiffLayer, options: DiffReadOptions,
        head: String?, preview: Bool = false
    ) async throws -> DiskDiffSnapshot {
        try await SnapshotIO.run { cancellation in
            let reader = try SnapshotLineReader(file: file, hashes: true, cancellation: cancellation)
            let regex = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
            var regions: [DiskDiffRegion] = []
            var hunks: [DiskDiffHunk] = []
            var checkpoints: [DiskLineCheckpoint] = []
            var rawLines = 0
            var sections = 0
            var rawPreview = preview
            var binary = false
            var applicable =
                !options.ignoreWhitespace && options.contextLines > 0
                && (layer == .staged || layer == .unstaged)
            var headerEnd = 0
            var sourceOID: String?
            var currentHeader: String?
            var currentOffset = 0
            var oldRange = 0..<0
            var newRange = 0..<0
            var oldLine = 0
            var newLine = 0
            var oldRemaining = 0
            var newRemaining = 0
            var previousKind: UInt8?
            var pending: DiskLineRun?
            var added = 0
            var removed = 0

            func flushRun() {
                guard let run = pending else { return }
                let hunkID = hunks.count
                switch run.kind {
                case 32: regions.append(DiskDiffRegion(hunkID: hunkID, content: .unchanged(run)))
                case 45: regions.append(DiskDiffRegion(hunkID: hunkID, content: .change(old: run, new: nil)))
                case 43:
                    if let last = regions.last, last.hunkID == hunkID,
                        case .change(let old?, nil) = last.content, old.endOffset == run.offset
                    {
                        regions[regions.count - 1].content = .change(old: old, new: run)
                    } else {
                        regions.append(DiskDiffRegion(hunkID: hunkID, content: .change(old: nil, new: run)))
                    }
                default: regions.append(DiskDiffRegion(hunkID: hunkID, content: .marker(run)))
                }
                pending = nil
            }

            func closeHunk(at end: Int) throws {
                flushRun()
                guard let currentHeader else { return }
                guard oldRemaining == 0, newRemaining == 0 else {
                    throw ModelFailure.invalidOutput("差异块行数与头信息不一致")
                }
                hunks.append(
                    DiskDiffHunk(
                        id: hunks.count, header: currentHeader, byteRange: currentOffset..<end,
                        oldRange: oldRange, newRange: newRange))
            }

            while let line = try reader.next() {
                if rawLines.isMultiple(of: DiffReadBudget.pageRows) {
                    checkpoints.append(DiskLineCheckpoint(line: rawLines + 1, offset: line.offset))
                }
                rawLines += 1
                guard rawLines <= DiskDiffBudget.lines else {
                    throw DiffContentLimit.lines(DiskDiffBudget.lines)
                }
                guard rawPreview || regions.count < DiskDiffBudget.regions else {
                    throw DiffContentLimit.regions(DiskDiffBudget.regions)
                }
                if preview { continue }
                guard line.terminated else { throw ModelFailure.invalidOutput("差异输出被截断") }
                let prefix = line.prefix
                // Headers are small in normal Git output. Body text is never decoded during indexing.
                let structural = prefix.first == 64 || prefix.first == 100 || currentHeader == nil
                let text = structural ? String(decoding: prefix, as: UTF8.self) : ""
                if text.hasPrefix("diff --git ") {
                    sections += 1
                    if sections > 1 { rawPreview = true }
                }
                if text.hasPrefix("@@@") || text.hasPrefix("diff --cc ") || text.hasPrefix("diff --combined ")
                {
                    rawPreview = true
                }
                if rawPreview { continue }
                if let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                    try closeHunk(at: line.offset)
                    func number(_ group: Int, fallback: Int = 1) throws -> Int {
                        let range = match.range(at: group)
                        if range.location == NSNotFound { return fallback }
                        guard let value = Int((text as NSString).substring(with: range)), value >= 0 else {
                            throw ModelFailure.invalidOutput("差异块行号超出范围")
                        }
                        return value
                    }
                    oldLine = try number(1)
                    newLine = try number(3)
                    oldRemaining = try number(2)
                    newRemaining = try number(4)
                    guard oldLine <= Int.max - oldRemaining, newLine <= Int.max - newRemaining,
                        oldRemaining == 0 || oldLine > 0, newRemaining == 0 || newLine > 0
                    else { throw ModelFailure.invalidOutput("差异块行号超出范围") }
                    let oldStart = oldLine - (oldRemaining == 0 ? 0 : 1)
                    let newStart = newLine - (newRemaining == 0 ? 0 : 1)
                    oldRange = oldStart..<(oldStart + oldRemaining)
                    newRange = newStart..<(newStart + newRemaining)
                    if hunks.isEmpty { headerEnd = line.offset }
                    currentOffset = line.offset
                    currentHeader =
                        String(decoding: text.utf8.prefix(DiskDiffBudget.headerBytes), as: UTF8.self)
                        + (line.truncated || text.utf8.count > DiskDiffBudget.headerBytes ? "…" : "")
                    previousKind = nil
                    regions.append(DiskDiffRegion(hunkID: hunks.count, content: .header(hunks.count)))
                    continue
                }
                guard currentHeader != nil else {
                    if text.hasPrefix("@@") { throw ModelFailure.invalidOutput("无法识别差异块头信息") }
                    if text.hasPrefix("Binary files ") || text == "GIT binary patch" { binary = true }
                    if ["new file mode ", "deleted file mode ", "rename from ", "old mode "].contains(
                        where: text.hasPrefix)
                    {
                        applicable = false
                    }
                    if text.hasPrefix("index ") {
                        let oid = String(text.dropFirst(6).prefix(while: { $0 != "." }))
                        if [40, 64].contains(oid.count), oid.allSatisfy({ $0.isHexDigit }),
                            oid.contains(where: { $0 != "0" })
                        {
                            sourceOID = oid
                        }
                        if text.hasSuffix(" 160000") { sourceOID = nil }
                    }
                    continue
                }
                guard let kind = prefix.first, [32, 43, 45, 92].contains(kind) else {
                    throw ModelFailure.invalidOutput("无法识别差异行")
                }
                if kind == 92 {
                    guard prefix == Data("\\ No newline at end of file".utf8), previousKind != nil,
                        previousKind != 92
                    else {
                        throw ModelFailure.invalidOutput("非法行尾标记")
                    }
                }
                let usesOld = kind == 32 || kind == 45
                let usesNew = kind == 32 || kind == 43
                guard !usesOld || oldRemaining > 0, !usesNew || newRemaining > 0 else {
                    throw ModelFailure.invalidOutput("差异块包含多余行")
                }
                if pending?.kind != kind { flushRun() }
                if pending == nil {
                    pending = DiskLineRun(
                        offset: line.offset, endOffset: line.nextOffset, count: 1, kind: kind,
                        oldStart: usesOld ? oldLine : nil, newStart: usesNew ? newLine : nil,
                        checkpoints: [DiskLineCheckpoint(line: 0, offset: line.offset)])
                } else {
                    let count = pending!.count
                    if count.isMultiple(of: DiffReadBudget.pageRows) {
                        pending?.checkpoints.append(DiskLineCheckpoint(line: count, offset: line.offset))
                    }
                    pending?.endOffset = line.nextOffset
                    pending?.count += 1
                }
                if usesOld {
                    oldLine += 1
                    oldRemaining -= 1
                }
                if usesNew {
                    newLine += 1
                    newRemaining -= 1
                }
                if kind == 43 { added += 1 }
                if kind == 45 { removed += 1 }
                previousKind = kind
                guard regions.count < DiskDiffBudget.regions else {
                    throw DiffContentLimit.regions(DiskDiffBudget.regions)
                }
            }
            if !rawPreview { try closeHunk(at: Int(file.stamp.size)) }
            try reader.validate()
            binary = binary || reader.containsNUL || !reader.validUTF8
            if rawPreview || binary {
                hunks = []
                regions = []
            }
            let unified = rawPreview ? rawLines : regions.reduce(0) { $0 + $1.unifiedCount }
            let split = rawPreview ? rawLines : regions.reduce(0) { $0 + $1.splitCount }
            return DiskDiffSnapshot(
                id: UUID(), path: path, layer: layer, options: options, head: head,
                digest: reader.digest, byteCount: Int(file.stamp.size), binary: binary,
                rawPreview: rawPreview,
                additions: added, deletions: removed, hunks: hunks, unifiedRows: unified, splitRows: split,
                canApplyHunk: applicable && !rawPreview && !binary && !hunks.isEmpty,
                file: file, regions: regions,
                noNewlineOffsets: Set(
                    regions.compactMap { region -> Int? in
                        if case .marker(let run) = region.content { return run.offset }
                        return nil
                    }),
                rawLineCount: rawLines, checkpoints: checkpoints,
                headerEnd: headerEnd, sourceOID: sourceOID)
        }
    }
}
