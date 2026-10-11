import Foundation

public struct SplitDiffRow: Identifiable, Sendable {
    public let id: Int
    public let old: DiffLine?
    public let new: DiffLine?

    public init(id: Int, old: DiffLine?, new: DiffLine?) {
        self.id = id
        self.old = old
        self.new = new
    }

    public init(context line: DiffLine) {
        id = line.id
        old = line
        new = line
    }
}

public enum DiffAlignment {
    public static func rows(_ lines: [DiffLine]) -> [SplitDiffRow] {
        var result: [SplitDiffRow] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                let old = index < removed.count ? removed[index] : nil
                let new = index < added.count ? added[index] : nil
                if let id = old?.id ?? new?.id {
                    result.append(SplitDiffRow(id: id, old: old, new: new))
                }
            }
            removed = []
            added = []
        }
        for line in lines {
            switch line.kind {
            case "-": removed.append(line)
            case "+": added.append(line)
            default:
                flush()
                result.append(SplitDiffRow(id: line.id, old: line, new: line))
            }
        }
        flush()
        return result
    }
}

public enum SyntaxKind: Sendable { case keyword, string, number, comment }
public struct SyntaxToken: Sendable {
    public let range: NSRange
    public let kind: SyntaxKind
}

/// Lightweight lexical highlighting is independent from the raw patch and never changes its bytes.
public enum SyntaxHighlighter {
    private static let hashRegex = try? NSRegularExpression(
        pattern:
            #"#[^\n]*|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\b(?:import|from|def|class|return|if|else|elif|for|while|in|try|except|True|False|None|echo|then|fi|do|done)\b|\b\d+(?:\.\d+)?\b"#
    )
    private static let commonRegex = try? NSRegularExpression(
        pattern:
            #"//[^\n]*|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\b(?:import|struct|class|actor|enum|func|let|var|const|public|private|static|final|return|if|else|for|while|switch|case|guard|throw|throws|try|await|async|function|export|default|new|true|false|null|nil|package|interface|type|fn|pub|use|impl|mut|match|self|Self|fun|val|data|object|override|suspend|when|as|by)\b|\b\d+(?:\.\d+)?\b"#
    )
    private static let markupRegex = try? NSRegularExpression(
        pattern: #"<!--.*?-->|</?[A-Za-z][\w:-]*|"[^"]*"|'[^']*'|\b\d+(?:\.\d+)?\b"#)
    private static let cssRegex = try? NSRegularExpression(
        pattern:
            #"/\*.*?\*/|@[\w-]+|[\w-]+(?=\s*:)|#[0-9a-fA-F]{3,8}\b|"[^"]*"|'[^']*'|\b\d+(?:\.\d+)?(?:px|em|rem|%)?"#
    )
    private static let markdownRegex = try? NSRegularExpression(
        pattern: #"^#{1,6}\s+.*|`+[^`]+`+|\*\*[^*]+\*\*|!?\[[^\]]+\]\([^)]*\)|<!--.*?-->"#)
    private static let jsonRegex = try? NSRegularExpression(
        pattern: #""(?:[^"\\]|\\.)*"|\b(?:true|false|null)\b|-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)

    public static func tokens(_ text: String, filename: String) -> [SyntaxToken] {
        let ext = (filename as NSString).pathExtension.lowercased()
        let supported = [
            "swift", "m", "mm", "h", "js", "jsx", "ts", "tsx", "html", "css", "json", "yml", "yaml", "md",
            "py", "java", "kt", "go", "rs", "sh", "bash", "zsh",
        ]
        guard supported.contains(ext) else { return [] }
        let hashComment = ["py", "sh", "bash", "zsh", "yml", "yaml"].contains(ext)
        let selected: NSRegularExpression?
        switch ext {
        case "html": selected = markupRegex
        case "css": selected = cssRegex
        case "md": selected = markdownRegex
        case "json": selected = jsonRegex
        default: selected = hashComment ? hashRegex : commonRegex
        }
        guard text.utf8.count <= 8192, let regex = selected else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            let value = (text as NSString).substring(with: match.range)
            let kind: SyntaxKind =
                value.hasPrefix("//") || value.hasPrefix("/*") || value.hasPrefix("<!--")
                    || (hashComment && value.hasPrefix("#"))
                ? .comment
                : value.hasPrefix("\"") || value.hasPrefix("'") || value.hasPrefix("`")
                    ? .string
                    : value.first?.isNumber == true || ext == "json" && value.hasPrefix("-")
                        ? .number : .keyword
            return SyntaxToken(range: match.range, kind: kind)
        }
    }
}
