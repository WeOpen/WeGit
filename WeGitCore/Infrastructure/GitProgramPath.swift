import Foundation

/// A configured program is one executable, never an evaluated command string.
enum GitProgramPath {
    static func decode(_ value: String) throws -> String {
        enum Quote { case none, single, double }
        var quote = Quote.none
        var escaped = false
        var ended = false
        var result = ""
        for character in value.trimmingCharacters(in: .whitespacesAndNewlines) {
            if escaped {
                guard character != "\n", character != "\r", character != "\0" else {
                    throw ModelFailure.invalidPath
                }
                result.append(character)
                escaped = false
                continue
            }
            switch quote {
            case .single:
                if character == "'" { quote = .none } else { result.append(character) }
            case .double:
                if character == "\"" {
                    quote = .none
                } else if character == "\\" {
                    escaped = true
                } else {
                    guard character != "$", character != "`" else { throw ModelFailure.invalidPath }
                    result.append(character)
                }
            case .none:
                if character.isWhitespace {
                    ended = true
                    continue
                }
                guard !ended else {
                    throw ModelFailure.unsupported(L10n.text("工具设置只接受一个可执行文件路径或命令名称。"))
                }
                if character == "'" {
                    quote = .single
                } else if character == "\"" {
                    quote = .double
                } else if character == "\\" {
                    escaped = true
                } else {
                    guard !"$`;&|<>()\0".contains(character) else { throw ModelFailure.invalidPath }
                    result.append(character)
                }
            }
        }
        guard quote == .none, !escaped, !result.isEmpty, result.utf8.count <= 4096 else {
            throw ModelFailure.invalidPath
        }
        return result
    }

    static func quote(_ value: String) -> String {
        if !value.isEmpty,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || "_./:+-".utf8.contains($0)
            })
        {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func resolve(_ value: String, engine: GitEngine, directory: URL) throws -> URL {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let exact = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).resolvingSymlinksInPath()
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: exact.path, isDirectory: &isDirectory),
                !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: exact.path)
            {
                return exact
            }
        }
        let decoded = try decode(value)
        let expanded = (decoded as NSString).expandingTildeInPath
        let candidates: [URL]
        if expanded.contains("/") {
            candidates = [URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL]
        } else {
            guard !expanded.hasPrefix("-") else { throw ModelFailure.invalidPath }
            candidates = (engine.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map {
                URL(fileURLWithPath: String($0), relativeTo: directory).appending(path: expanded)
            }
        }
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: resolved.path)
            {
                return resolved
            }
        }
        throw ModelFailure.unsupported(L10n.text("未找到可执行的签名工具，请选择已安装的工具。"))
    }

    static func readableFile(_ value: String, directory: URL) throws -> URL {
        let expanded = (value as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: url.path)
        else { throw ModelFailure.unsupported(L10n.text("请选择存在且可读取的文件。")) }
        return url
    }
}
