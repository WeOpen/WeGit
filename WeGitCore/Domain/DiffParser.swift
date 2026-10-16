import Foundation

public enum DiffParser {
    public static func parse(
        _ raw: Data, path: String, layer: DiffLayer, head: String?, indexTree: String? = nil,
        options: DiffReadOptions = DiffReadOptions()
    ) throws -> FileDiff {
        // Check the record budget before allocating strings for every line of a dense patch.
        try DiffReadBudget.validateLineCount(raw)
        try Task.checkCancellation()
        guard let text = String(data: raw, encoding: .utf8) else {
            return FileDiff(
                options: options, path: path, layer: layer, raw: raw, header: "", hunks: [],
                binary: true, preview: nil, head: head, indexTree: indexTree)
        }
        guard raw.isEmpty || raw.last == 10 else { throw ModelFailure.invalidOutput(L10n.text("差异输出被截断")) }
        let pieces = (text as NSString).components(separatedBy: "\n")
        // Type changes can produce separate deletion/addition patches for one selected path.
        // Combined merge patches use a different grammar. Show both faithfully, without block mutation.
        if pieces.filter({ $0.hasPrefix("diff --git ") }).count > 1
            || pieces.contains(where: { $0.hasPrefix("@@@") })
        {
            return FileDiff(
                options: options, path: path, layer: layer, raw: raw, header: "", hunks: [],
                binary: false, preview: text, head: head, indexTree: indexTree)
        }
        let regex = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        var header = ""
        var hunks: [DiffHunk] = []
        var title: String?
        var hunkRaw = ""
        var lines: [DiffLine] = []
        var old = 0
        var new = 0
        var remainingOld = 0
        var remainingNew = 0
        var id = 0
        var binary = false
        func validateCounts() throws {
            guard remainingOld == 0, remainingNew == 0 else {
                throw ModelFailure.invalidOutput(L10n.text("差异块行数与头信息不一致"))
            }
        }
        for (offset, line) in pieces.enumerated() {
            if offset.isMultiple(of: 256) { try Task.checkCancellation() }
            if offset == pieces.count - 1 { continue }
            let original = line + "\n"
            if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                try validateCounts()
                if let title {
                    hunks.append(DiffHunk(id: hunks.count, header: title, lines: lines, raw: hunkRaw))
                }
                func number(_ group: Int, default fallback: Int? = nil) throws -> Int {
                    let range = match.range(at: group)
                    if range.location == NSNotFound, let fallback { return fallback }
                    guard range.location != NSNotFound,
                        let number = Int((line as NSString).substring(with: range)), number >= 0
                    else {
                        throw ModelFailure.invalidOutput(L10n.text("差异块行号超出范围"))
                    }
                    return number
                }
                old = try number(1)
                remainingOld = try number(2, default: 1)
                new = try number(3)
                remainingNew = try number(4, default: 1)
                guard old <= Int.max - remainingOld, new <= Int.max - remainingNew,
                    remainingOld == 0 || old > 0, remainingNew == 0 || new > 0
                else {
                    throw ModelFailure.invalidOutput(L10n.text("差异块行号超出范围"))
                }
                title = line
                hunkRaw = original
                lines = []
                continue
            }
            guard title != nil else {
                if line.hasPrefix("@@") { throw ModelFailure.invalidOutput(L10n.text("无法识别差异块头信息")) }
                binary = binary || line.hasPrefix("Binary files ") || line == "GIT binary patch"
                header += original
                continue
            }
            guard let kind = line.first, [" ", "+", "-", "\\"].contains(kind) else {
                throw ModelFailure.invalidOutput(L10n.text("无法识别差异行"))
            }
            if kind == "\\" {
                guard line == "\\ No newline at end of file", let previous = lines.last, previous.kind != "\\"
                else {
                    throw ModelFailure.invalidOutput(L10n.text("非法行尾标记"))
                }
                lines[lines.count - 1] = DiffLine(
                    id: previous.id, kind: previous.kind, content: previous.content,
                    oldLine: previous.oldLine, newLine: previous.newLine,
                    truncated: previous.truncated, hasNewline: false)
            }
            let usesOld = kind == " " || kind == "-"
            let usesNew = kind == " " || kind == "+"
            guard !usesOld || remainingOld > 0, !usesNew || remainingNew > 0 else {
                throw ModelFailure.invalidOutput(L10n.text("差异块包含多余行"))
            }
            lines.append(
                DiffLine(
                    id: id, kind: kind, content: String(line.dropFirst()),
                    oldLine: usesOld ? old : nil, newLine: usesNew ? new : nil))
            if usesOld {
                old += 1
                remainingOld -= 1
            }
            if usesNew {
                new += 1
                remainingNew -= 1
            }
            hunkRaw += original
            id += 1
        }
        try validateCounts()
        if let title { hunks.append(DiffHunk(id: hunks.count, header: title, lines: lines, raw: hunkRaw)) }
        return FileDiff(
            options: options, path: path, layer: layer, raw: raw, header: header, hunks: hunks,
            binary: binary, preview: nil, head: head, indexTree: indexTree)
    }
}
