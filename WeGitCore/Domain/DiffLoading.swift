import Darwin
import Foundation

public enum DiffReadBudget {
    public static let automaticBytes = 512 * 1024
    public static let automaticChangedLines = 2_000
    public static let patchBytes = 8 * 1024 * 1024
    public static let previewBytes = 2 * 1024 * 1024
    public static let patchLines = 100_000
    public static let pageRows = 400

    static func validateLineCount(_ data: Data) throws {
        var records = data.isEmpty || data.last == 10 ? 0 : 1
        for index in data.indices {
            if index.isMultiple(of: 16_384) { try Task.checkCancellation() }
            if data[index] == 10 {
                records += 1
                if records > patchLines { throw DiffContentLimit.lines(patchLines) }
            }
        }
    }
}

public enum DiffContentLimit: Error, LocalizedError, Sendable, Equatable {
    case bytes(Int)
    case lines(Int)
    case regions(Int)

    public var errorDescription: String? {
        switch self {
        case .bytes(let count):
            "内容超过 \(count / 1024 / 1024) MiB 的读取上限。请在外部工具中查看完整内容。"
        case .lines(let count):
            "内容超过 \(count) 行的读取上限。请在外部工具中查看完整内容。"
        case .regions(let count):
            "差异超过 \(count) 个区间的读取上限。请缩小比较范围或在外部工具中查看。"
        }
    }
}

public struct DiffSummary: Sendable, Equatable {
    public let path: String
    public let layer: DiffLayer
    public let additions: Int?
    public let deletions: Int?
    public let fileBytes: Int64?
    public let binary: Bool

    public var needsExplicitLoad: Bool {
        (additions ?? 0) > DiffReadBudget.automaticChangedLines - (deletions ?? 0)
            || (fileBytes ?? 0) > DiffReadBudget.automaticBytes
    }

    /// --numstat -z with --no-renames: two numeric fields, then an unescaped path.
    public static func parse(_ raw: Data, path: String, layer: DiffLayer) throws -> DiffSummary {
        guard raw.isEmpty || raw.last == 0 else { throw ModelFailure.invalidOutput("差异摘要被截断") }
        var additions = 0
        var deletions = 0
        var binary = false
        for record in raw.split(separator: 0) {
            let fields = record.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[2].isEmpty else {
                throw ModelFailure.invalidOutput("差异摘要字段不完整")
            }
            if fields[0] == Data("-".utf8) && fields[1] == Data("-".utf8) {
                binary = true
                continue
            }
            guard let added = Int(String(decoding: fields[0], as: UTF8.self)), added >= 0,
                let removed = Int(String(decoding: fields[1], as: UTF8.self)), removed >= 0,
                added <= Int.max - additions, removed <= Int.max - deletions
            else { throw ModelFailure.invalidOutput("差异摘要行数无效") }
            additions += added
            deletions += removed
        }
        return DiffSummary(
            path: path, layer: layer, additions: binary ? nil : additions,
            deletions: binary ? nil : deletions, fileBytes: nil, binary: binary)
    }
}

public enum DiffReadResult: Sendable {
    case loaded(FileDiff)
    case disk(DiskDiffSnapshot)
    case deferred(DiffSummary, limit: DiffContentLimit?)
}

extension RepositoryService {
    /// The summary never materializes the patch. Explicit reads remain bounded; display paging
    /// is separate from Git's complete patch output and must never be used as an apply patch.
    @concurrent
    public func readDiff(
        path: String, layer: DiffLayer, options: DiffReadOptions = DiffReadOptions(),
        loadLarge: Bool = false
    ) async throws -> DiffReadResult {
        try Task.checkCancellation()
        guard layer != .commit else { throw ModelFailure.unsupported("提交差异需要明确的比较对象。") }
        try location.validateIdentity()
        try validate(path)
        guard (0...200).contains(options.contextLines) else {
            throw ModelFailure.unsupported("上下文行数须在 0～200 之间。")
        }
        let summary: DiffSummary
        if layer == .untracked {
            let size = try await SnapshotIO.run { cancellation in
                let reader = try RepositoryFileReader(
                    location: location, path: path, cancellation: cancellation)
                try reader.validate()
                return reader.size
            }
            summary = DiffSummary(
                path: path, layer: layer, additions: nil, deletions: nil, fileBytes: size,
                binary: false)
        } else {
            var arguments = [
                "diff", "--numstat", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", "--no-color",
            ]
            if layer == .staged { arguments.append("--cached") }
            if options.ignoreWhitespace { arguments.append("--ignore-all-space") }
            arguments += ["--", path]
            let output = try await engine.run(arguments, in: location.root, outputLimit: 64 * 1024)
            summary = try DiffSummary.parse(output.stdout, path: path, layer: layer)
        }
        try Task.checkCancellation()
        if !loadLarge && summary.needsExplicitLoad { return .deferred(summary, limit: nil) }
        let ceiling = layer == .untracked ? DiffReadBudget.previewBytes : DiffReadBudget.patchBytes
        do {
            let value = try await diff(
                path: path, layer: layer, options: options,
                outputLimit: loadLarge ? ceiling : DiffReadBudget.automaticBytes)
            try Task.checkCancellation()
            return .loaded(value)
        } catch ProcessFailure.outputLimit {
            try Task.checkCancellation()
            if !loadLarge { return .deferred(summary, limit: nil) }
            return try await readDisk(summary: summary, options: options)
        } catch is DiffContentLimit {
            try Task.checkCancellation()
            if !loadLarge { return .deferred(summary, limit: nil) }
            return try await readDisk(summary: summary, options: options)
        }
    }

    private func readDisk(summary: DiffSummary, options: DiffReadOptions) async throws -> DiffReadResult {
        do {
            return .disk(try await diskDiff(path: summary.path, layer: summary.layer, options: options))
        } catch ProcessFailure.outputLimit {
            try Task.checkCancellation()
            return .deferred(summary, limit: .bytes(DiskDiffBudget.bytes))
        } catch let limit as DiffContentLimit {
            try Task.checkCancellation()
            return .deferred(summary, limit: limit)
        }
    }
}
