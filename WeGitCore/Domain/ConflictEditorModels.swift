import Foundation

public struct ConflictEditorDirectoryIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let bornSeconds: Int64
    public let bornNanoseconds: Int64

}

public enum ConflictEditorSide: String, CaseIterable, Hashable, Sendable {
    case base
    case ours
    case theirs
    case result

    public var title: String {
        switch self {
        case .base: L10n.text("BASE")
        case .ours: L10n.text("OURS")
        case .theirs: L10n.text("THEIRS")
        case .result: L10n.text("RESULT")
        }
    }
}

public enum ConflictEditorChoice: String, CaseIterable, Hashable, Sendable {
    case base
    case ours
    case theirs
    case both

    public var title: String {
        switch self {
        case .base: L10n.text("接受 BASE")
        case .ours: L10n.text("接受 OURS")
        case .theirs: L10n.text("接受 THEIRS")
        case .both: L10n.text("接受两侧")
        }
    }
}

public struct ConflictEditorSource: Hashable, Sendable {
    public let title: String
    public let revision: String?

    public init(title: String, revision: String? = nil) {
        self.title = title
        self.revision = revision
    }
}

enum ConflictEditorOperationSnapshot: Hashable, Sendable {
    case merge(Data)
    case rebase(RebaseRecovery)
    case cherryPick(SingleCommitRecovery, Data)
    case revert(SingleCommitRecovery, Data)

    var sequencer: Sequencer {
        switch self {
        case .merge: .merge
        case .rebase: .rebase
        case .cherryPick: .cherryPick
        case .revert: .revert
        }
    }
}

public struct ConflictEditorBlockResolution: Identifiable, Hashable, Sendable {
    public let id: Int
    public let oursBytes: Data
    public let baseBytes: Data
    public let theirsBytes: Data

}

public struct ConflictEditorFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    public let mode: UInt16
    public let parentDirectories: [ConflictEditorDirectoryIdentity]

    init(
        device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64,
        modifiedNanoseconds: Int64, changedSeconds: Int64, changedNanoseconds: Int64,
        mode: UInt16, parentDirectories: [ConflictEditorDirectoryIdentity]
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds
        self.changedNanoseconds = changedNanoseconds
        self.mode = mode
        self.parentDirectories = parentDirectories
    }

    init(
        _ stamp: SnapshotFileStamp, mode: UInt16,
        parentDirectories: [ConflictEditorDirectoryIdentity]
    ) {
        self.init(
            device: UInt64(stamp.device), inode: UInt64(stamp.inode), size: stamp.size,
            modifiedSeconds: Int64(stamp.modifiedSeconds),
            modifiedNanoseconds: Int64(stamp.modifiedNanoseconds),
            changedSeconds: Int64(stamp.changedSeconds),
            changedNanoseconds: Int64(stamp.changedNanoseconds), mode: mode,
            parentDirectories: parentDirectories)
    }
}

public struct ConflictEditorBuffer: Identifiable, Hashable, Sendable {
    public let side: ConflictEditorSide
    public let source: ConflictEditorSource
    public let bytes: Data
    public let text: String

    public var id: ConflictEditorSide { side }

    init(side: ConflictEditorSide, source: ConflictEditorSource, bytes: Data) throws {
        guard !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else {
            throw ModelFailure.unsupported(L10n.text("此冲突文件不是可编辑的 UTF-8 文本，请使用外部工具处理。"))
        }
        self.side = side
        self.source = source
        self.bytes = bytes
        self.text = text
    }
}

public struct ConflictMarkerBlock: Identifiable, Hashable, Sendable {
    public let id: Int
    public let startLine: Int
    public let separatorLine: Int
    public let endLine: Int
    public let replacementRange: Range<Int>
    public let oursText: String
    public let baseText: String?
    public let theirsText: String
    public let oursBytes: Data
    public let baseBytes: Data?
    public let theirsBytes: Data

    public var hasBaseSection: Bool { baseText != nil }

    init(
        id: Int, startLine: Int, separatorLine: Int, endLine: Int, replacementRange: Range<Int>,
        oursText: String, baseText: String?, theirsText: String,
        oursBytes: Data, baseBytes: Data?, theirsBytes: Data
    ) {
        self.id = id
        self.startLine = startLine
        self.separatorLine = separatorLine
        self.endLine = endLine
        self.replacementRange = replacementRange
        self.oursText = oursText
        self.baseText = baseText
        self.theirsText = theirsText
        self.oursBytes = oursBytes
        self.baseBytes = baseBytes
        self.theirsBytes = theirsBytes
    }
}

public enum ConflictMarkerParser {
    public struct Analysis: Hashable, Sendable {
        public let blocks: [ConflictMarkerBlock]
        public let malformed: Bool

        public var resolved: Bool { blocks.isEmpty && !malformed }
    }

    private struct Line {
        let number: Int
        let start: Int
        let contentEnd: Int
        let next: Int
        let content: String
    }

    public static func analyze(_ text: String) -> Analysis {
        let bytes = Array(text.utf8)
        let lines = makeLines(bytes)
        var blocks: [ConflictMarkerBlock] = []
        var start: Line?
        var baseMarker: Line?
        var separator: Line?
        var malformed = false

        for line in lines {
            if line.content.hasPrefix("<<<<<<<") {
                if start != nil {
                    malformed = true
                } else {
                    start = line
                }
                continue
            }
            if line.content.hasPrefix("|||||||") {
                if start == nil || baseMarker != nil || separator != nil {
                    malformed = true
                } else {
                    baseMarker = line
                }
                continue
            }
            if line.content == "=======" {
                if start == nil || separator != nil {
                    malformed = true
                } else {
                    separator = line
                }
                continue
            }
            if line.content.hasPrefix(">>>>>>>") {
                guard let startLine = start, let separatorLine = separator else {
                    malformed = true
                    continue
                }
                let baseText: String?
                let baseBytes: Data?
                if let baseMarker {
                    baseBytes = data(bytes, from: baseMarker.next, through: separatorLine.start)
                    baseText = String(decoding: baseBytes!, as: UTF8.self)
                } else {
                    baseBytes = nil
                    baseText = nil
                }
                let oursEnd = baseMarker?.start ?? separatorLine.start
                let oursBytes = data(bytes, from: startLine.next, through: oursEnd)
                let theirsBytes = data(bytes, from: separatorLine.next, through: line.start)
                let oursText = String(decoding: oursBytes, as: UTF8.self)
                let theirsText = String(decoding: theirsBytes, as: UTF8.self)
                blocks.append(
                    ConflictMarkerBlock(
                        id: blocks.count, startLine: startLine.number, separatorLine: separatorLine.number,
                        endLine: line.number, replacementRange: startLine.start..<line.next,
                        oursText: oursText, baseText: baseText, theirsText: theirsText,
                        oursBytes: oursBytes, baseBytes: baseBytes, theirsBytes: theirsBytes))
                start = nil
                baseMarker = nil
                separator = nil
            }
        }
        if start != nil || baseMarker != nil || separator != nil { malformed = true }
        return Analysis(blocks: blocks, malformed: malformed)
    }

    public static func blocks(in text: String) -> [ConflictMarkerBlock] {
        analyze(text).blocks
    }

    public static func replacing(
        text: String, block: ConflictMarkerBlock, with choice: ConflictEditorChoice,
        baseOverride: Data? = nil
    ) throws -> String {
        let bytes = Array(text.utf8)
        guard block.replacementRange.lowerBound >= 0,
            block.replacementRange.upperBound <= bytes.count,
            block.replacementRange.lowerBound <= block.replacementRange.upperBound
        else { throw ModelFailure.changed }
        let replacement: String
        switch choice {
        case .base:
            guard let baseBytes = baseOverride ?? block.baseBytes else {
                throw ModelFailure.unsupported(L10n.text("这个冲突块没有独立的 BASE 内容。"))
            }
            replacement = String(decoding: baseBytes, as: UTF8.self)
        case .ours: replacement = String(decoding: block.oursBytes, as: UTF8.self)
        case .theirs: replacement = String(decoding: block.theirsBytes, as: UTF8.self)
        case .both: replacement = block.oursText + block.theirsText
        }
        var result = Data(bytes[..<block.replacementRange.lowerBound])
        result.append(contentsOf: replacement.utf8)
        result.append(contentsOf: bytes[block.replacementRange.upperBound...])
        guard let value = String(data: result, encoding: .utf8) else {
            throw ModelFailure.unsupported(L10n.text("结果不是有效的 UTF-8 文本。"))
        }
        return value
    }

    private static func makeLines(_ bytes: [UInt8]) -> [Line] {
        var result: [Line] = []
        var start = 0
        var number = 1
        while start <= bytes.count {
            let newline = bytes[start...].firstIndex(of: 0x0A)
            let contentEnd = newline ?? bytes.count
            let next = newline.map { $0 + 1 } ?? bytes.count
            var contentBytes = Array(bytes[start..<contentEnd])
            if contentBytes.last == 0x0D { contentBytes.removeLast() }
            result.append(
                Line(
                    number: number, start: start, contentEnd: contentEnd, next: next,
                    content: String(decoding: contentBytes, as: UTF8.self)))
            number += 1
            guard let newline else { break }
            start = newline + 1
        }
        return result
    }

    private static func data(_ bytes: [UInt8], from start: Int, through end: Int) -> Data {
        guard start < end else { return Data() }
        return Data(bytes[start..<end])
    }

    private static func selfStartReset<T>(_ value: inout T?) { value = nil }
}

public struct ConflictEditorDocument: Sendable {
    public let path: String
    public let head: String?
    public let sequencer: Sequencer
    let repositoryIdentity: String
    let operationSnapshot: ConflictEditorOperationSnapshot
    let attributesListing: Data
    let indexSnapshot: SelectedIndexSnapshot
    public let indexListing: Data
    public let entryListing: Data
    public let blockResolutions: [ConflictEditorBlockResolution]?
    public let base: ConflictEditorBuffer
    public let ours: ConflictEditorBuffer
    public let theirs: ConflictEditorBuffer
    public var result: ConflictEditorBuffer
    public let resultIdentity: ConflictEditorFileIdentity

    public var unresolvedBlocks: [ConflictMarkerBlock] {
        ConflictMarkerParser.blocks(in: result.text)
    }

    public var hasMalformedMarkers: Bool {
        ConflictMarkerParser.analyze(result.text).malformed
    }

    init(
        path: String, head: String?, sequencer: Sequencer, repositoryIdentity: String,
        operationSnapshot: ConflictEditorOperationSnapshot, attributesListing: Data,
        indexSnapshot: SelectedIndexSnapshot, indexListing: Data, entryListing: Data,
        blockResolutions: [ConflictEditorBlockResolution]?,
        base: ConflictEditorBuffer, ours: ConflictEditorBuffer, theirs: ConflictEditorBuffer,
        result: ConflictEditorBuffer, resultIdentity: ConflictEditorFileIdentity
    ) {
        self.path = path
        self.head = head
        self.sequencer = sequencer
        self.repositoryIdentity = repositoryIdentity
        self.operationSnapshot = operationSnapshot
        self.attributesListing = attributesListing
        self.indexSnapshot = indexSnapshot
        self.indexListing = indexListing
        self.entryListing = entryListing
        self.blockResolutions = blockResolutions
        self.base = base
        self.ours = ours
        self.theirs = theirs
        self.result = result
        self.resultIdentity = resultIdentity
    }
}

enum ConflictEditorBudget {
    static let bytes = 8 * 1024 * 1024
    static let indexBytes = 32 * 1024 * 1024
}
