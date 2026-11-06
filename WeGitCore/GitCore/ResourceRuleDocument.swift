import Foundation

/// Operates on UTF-8 byte ranges. Unselected lines, spacing, comments and endings
/// are never reserialized by Git's configuration writer.
enum ResourceRuleDocument {
    struct Line {
        var body: String
        let ending: String
    }

    static func lines(_ data: Data) throws -> [Line] {
        guard data.count <= 4 * 1024 * 1024, !data.contains(0),
            let text = String(data: data, encoding: .utf8)
        else { throw ModelFailure.invalidPath }
        _ = text
        var result: [Line] = []
        var start = data.startIndex
        while start < data.endIndex {
            if let newline = data[start...].firstIndex(of: 10) {
                let crlf = newline > start && data[newline - 1] == 13
                let end = crlf ? newline - 1 : newline
                result.append(
                    Line(
                        body: String(decoding: data[start..<end], as: UTF8.self), ending: crlf ? "\r\n" : "\n"
                    ))
                start = newline + 1
            } else {
                result.append(Line(body: String(decoding: data[start...], as: UTF8.self), ending: ""))
                break
            }
        }
        return result
    }

    static func bytes(_ lines: [Line]) -> Data {
        Data(lines.map { $0.body + $0.ending }.joined().utf8)
    }

    static func quote(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    static func unquote(_ value: String) throws -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        let chars = Array(value.utf8.dropFirst().dropLast())
        var result = Data()
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char != 92 {
                result.append(char)
                index += 1
                continue
            }
            index += 1
            guard index < chars.count else { throw ModelFailure.invalidPath }
            switch chars[index] {
            case 110: result.append(10)
            case 114: result.append(13)
            case 116: result.append(9)
            case 98: result.append(8)
            case 97: result.append(7)
            case 118: result.append(11)
            case 102: result.append(12)
            case 92, 34: result.append(chars[index])
            case 48...55:
                guard index + 2 < chars.count, chars[index + 1] >= 48, chars[index + 1] <= 55,
                    chars[index + 2] >= 48, chars[index + 2] <= 55
                else { throw ModelFailure.invalidPath }
                let byte =
                    Int(chars[index] - 48) * 64 + Int(chars[index + 1] - 48) * 8 + Int(chars[index + 2] - 48)
                guard byte <= 255 else { throw ModelFailure.invalidPath }
                result.append(UInt8(byte))
                index += 2
            default: throw ModelFailure.invalidPath
            }
            index += 1
        }
        guard let text = String(data: result, encoding: .utf8), !result.contains(0) else {
            throw ModelFailure.invalidPath
        }
        return text
    }

    static func moduleName(_ line: String, section requested: String = "submodule") throws -> String? {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("[") else { return nil }
        var quoted = false
        var escaped = false
        var close: String.Index?
        for index in value.indices.dropFirst() {
            let char = value[index]
            if escaped {
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                continue
            }
            if char == "\"" { quoted.toggle() }
            if !quoted && char == "]" {
                close = index
                break
            }
        }
        guard let close else { throw ModelFailure.invalidPath }
        let section = String(value[value.index(after: value.startIndex)..<close])
        if section.lowercased().hasPrefix(requested + ".") {
            return String(section.dropFirst(requested.count + 1)).lowercased()
        }
        guard
            section.lowercased().hasPrefix(requested + " ")
                || section.lowercased().hasPrefix(requested + "\t")
        else { return nil }
        return try unquote(String(section.dropFirst(requested.count)).trimmingCharacters(in: .whitespaces))
    }

    static func moduleKeys(
        _ original: Data, name: String, updates: [String: String?], append: Bool = false,
        section: String = "submodule"
    )
        throws -> Data
    {
        var document = try lines(original)
        var current: String?
        var seen: Set<String> = []
        for index in document.indices {
            let body = document[index].body
            if body.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                current = try moduleName(body, section: section)
                continue
            }
            guard current == name, let equals = body.firstIndex(of: "=") else { continue }
            let key = body[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard let update = updates[key] else { continue }
            // Duplicate keys are rejected instead of silently changing precedence.
            guard seen.insert(key).inserted else { throw ModelFailure.changed }
            let valueStart = body.index(after: equals)
            var comment: String.Index?
            var quoted = false
            var escaped = false
            for cursor in body[valueStart...].indices {
                let char = body[cursor]
                if escaped {
                    escaped = false
                    continue
                }
                if char == "\\" {
                    escaped = true
                    continue
                }
                if char == "\"" { quoted.toggle() }
                if !quoted && (char == "#" || char == ";") {
                    comment = cursor
                    break
                }
            }
            let end = comment ?? body.endIndex
            guard let value = update else {
                document[index].body = comment.map { String(body[$0...]) } ?? ""
                continue
            }
            let whitespace = body[valueStart..<end].prefix { $0 == " " || $0 == "\t" }
            let tail = body[valueStart..<end].reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
            document[index].body =
                String(body[...equals]) + whitespace + quote(value) + String(tail)
                + (comment.map { String(body[$0...]) } ?? "")
        }
        // Empty removed property lines preserve the existing newline exactly.
        if append {
            let missing = updates.keys.filter { !seen.contains($0) && updates[$0]! != nil }.sorted()
            if !missing.isEmpty {
                let ending = document.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
                let missingFinalEnding = document.last?.ending.isEmpty == true
                if let last = document.last, last.ending.isEmpty {
                    document[document.count - 1] = Line(body: last.body, ending: ending)
                }
                document.append(Line(body: "[" + section + " " + quote(name) + "]", ending: ending))
                for (index, key) in missing.enumerated() {
                    document.append(
                        Line(
                            body: "\t" + key + " = " + quote(updates[key]!!),
                            ending: missingFinalEnding && index == missing.count - 1 ? "" : ending))
                }
            }
        } else {
            for (key, value) in updates where value != nil && !seen.contains(key) {
                throw ModelFailure.changed
            }
        }
        return bytes(document)
    }

    static func attributeTokens(_ body: String) throws -> [Range<String.Index>] {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return [] }
        var result: [Range<String.Index>] = []
        var cursor = body.startIndex
        while cursor < body.endIndex {
            while cursor < body.endIndex && (body[cursor] == " " || body[cursor] == "\t") {
                cursor = body.index(after: cursor)
            }
            guard cursor < body.endIndex else { break }
            let start = cursor
            if result.isEmpty && body[cursor] == "\"" {
                cursor = body.index(after: cursor)
                var escaped = false
                var closed = false
                while cursor < body.endIndex {
                    let char = body[cursor]
                    cursor = body.index(after: cursor)
                    if escaped {
                        escaped = false
                        continue
                    }
                    if char == "\\" {
                        escaped = true
                        continue
                    }
                    if char == "\"" {
                        closed = true
                        break
                    }
                }
                guard closed else { throw ModelFailure.invalidPath }
            } else {
                while cursor < body.endIndex && body[cursor] != " " && body[cursor] != "\t" {
                    cursor = body.index(after: cursor)
                }
            }
            result.append(start..<cursor)
        }
        return result
    }

    static func lfsRule(_ original: Data, pattern: String, action: LFSRuleAction) throws -> Data {
        var document = try lines(original)
        if action == .track {
            let ending = document.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
            let missingFinalEnding = document.last?.ending.isEmpty == true
            if let last = document.last, last.ending.isEmpty {
                document[document.count - 1] = Line(body: last.body, ending: ending)
            }
            document.append(
                Line(
                    body: quote(pattern) + " filter=lfs diff=lfs merge=lfs -text",
                    ending: missingFinalEnding ? "" : ending))
        } else {
            var found = false
            for index in document.indices {
                let body = document[index].body
                let tokens = try attributeTokens(body)
                guard let first = tokens.first, try unquote(String(body[first])) == pattern else { continue }
                let removed = tokens.dropFirst().filter {
                    ["filter=lfs", "diff=lfs", "merge=lfs"].contains(String(body[$0]))
                }
                if !removed.isEmpty { found = true }
                for range in removed.reversed() { document[index].body.removeSubrange(range) }
            }
            guard found else { throw ModelFailure.changed }
        }
        let result = bytes(document)
        guard result.count <= 4 * 1024 * 1024 else { throw RecoveryBudget.exceeded }
        return result
    }
}
