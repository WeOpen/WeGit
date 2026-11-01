import Foundation

struct DiskContextSource: Sendable {
    let file: SnapshotFile
    let lineCount: Int
    let checkpoints: [DiskLineCheckpoint]

    static func readBlob(_ oid: String, service: RepositoryService) async throws -> DiskContextSource {
        try service.location.validateIdentity()
        let directory = try await SnapshotIO.run { _ in try SnapshotDirectory() }
        let url = directory.url.appending(path: "context")
        _ = try await service.engine.run(
            ["cat-file", "blob", oid], in: service.location.root, timeout: 120,
            outputLimit: DiskDiffBudget.bytes, stdoutFile: url)
        return try await SnapshotIO.run { cancellation in
            let file = try SnapshotFile(directory: directory, url: url)
            let reader = try SnapshotLineReader(file: file, hashes: true, cancellation: cancellation)
            var count = 0
            var checkpoints: [DiskLineCheckpoint] = []
            while let line = try reader.next(prefixLimit: 0) {
                if count.isMultiple(of: DiffReadBudget.pageRows) {
                    checkpoints.append(DiskLineCheckpoint(line: count + 1, offset: line.offset))
                }
                count += 1
                guard count <= DiskDiffBudget.lines else {
                    throw DiffContentLimit.lines(DiskDiffBudget.lines)
                }
            }
            try reader.validate()
            guard !reader.containsNUL && reader.validUTF8 else {
                throw ModelFailure.unsupported(L10n.text("此对象不支持文本上下文。"))
            }
            return DiskContextSource(file: file, lineCount: count, checkpoints: checkpoints)
        }
    }

    func page(gap: DiffContextGap, start: Int, count: Int, consumed: Int) async throws -> DiffContextPage {
        try await SnapshotIO.run { cancellation in
            var lines: [DiffLine] = []
            var read = 0
            if count > 0, start <= lineCount {
                guard let checkpoint = checkpoints.last(where: { $0.line <= start }) else {
                    throw ModelFailure.changed
                }
                let reader = try SnapshotLineReader(
                    file: file, offset: checkpoint.offset, chunkSize: 4096, cancellation: cancellation)
                for _ in checkpoint.line..<start { _ = try reader.next(prefixLimit: 0) }
                while read < count, let raw = try reader.next() {
                    let oldNumber = start + read
                    let delta = oldNumber - gap.oldStart
                    guard delta >= 0, gap.newStart <= Int.max - delta else {
                        throw ModelFailure.invalidOutput(L10n.text("上下文行号超出范围"))
                    }
                    lines.append(
                        DiffLine(
                            id: -(oldNumber * 2), kind: " ",
                            content: try UTF8DisplayPrefix.decode(raw.prefix, truncated: raw.truncated),
                            oldLine: oldNumber, newLine: gap.newStart + delta, truncated: raw.truncated,
                            hasNewline: raw.terminated))
                    if !raw.terminated {
                        lines.append(
                            DiffLine(
                                id: -(oldNumber * 2 + 1), kind: "\\", content: " No newline at end of file",
                                oldLine: nil, newLine: nil))
                    }
                    read += 1
                }
                try reader.validate()
            }
            if gap.count != nil && read != count {
                throw ModelFailure.invalidOutput(L10n.text("上下文范围与补丁对象不一致"))
            }
            return DiffContextPage(
                lines: lines, consumedLines: read,
                hasMore: gap.count.map { consumed + read < $0 } ?? (start + read <= lineCount))
        }
    }
}
