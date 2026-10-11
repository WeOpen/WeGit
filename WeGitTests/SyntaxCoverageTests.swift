import Foundation
import Testing

@testable import WeGitCore

struct SyntaxCoverageTests {
    @Test(arguments: [
        ("file.swift", "let value = \"中文🙂\" // note", "let"),
        ("file.m", "@interface Example", "interface"),
        ("file.js", "const value = 42", "const"),
        ("file.ts", "interface Example {}", "interface"),
        ("file.html", "<div class=\"title\">", "<div"),
        ("file.css", "color: #abcdef;", "color"),
        ("file.json", "{\"enabled\": true}", "true"),
        ("file.yaml", "enabled: true # note", "# note"),
        ("file.md", "# Document title", "# Document title"),
        ("file.py", "def example(): # note", "def"),
        ("file.java", "public class Example {}", "public"),
        ("file.kt", "fun example() = 42", "fun"),
        ("file.go", "func example() {}", "func"),
        ("file.rs", "pub fn example() {}", "pub"),
        ("file.sh", "echo 'value' # note", "echo"),
    ]) func initialLanguagesHaveBoundedLexicalHighlighting(sample: (String, String, String)) {
        let (path, source, expected) = sample
        let original = Data(source.utf8)
        let tokens = SyntaxHighlighter.tokens(source, filename: path)
        #expect(tokens.contains { (source as NSString).substring(with: $0.range) == expected })
        #expect(tokens.allSatisfy { Range($0.range, in: source) != nil })
        #expect(Data(source.utf8) == original)
    }

    @Test func unknownLanguagesAndOversizedLinesUsePlainText() {
        #expect(SyntaxHighlighter.tokens("let value = 3", filename: "unknown.xyz").isEmpty)
        #expect(SyntaxHighlighter.tokens(String(repeating: "a", count: 8193), filename: "file.swift").isEmpty)
        let source = "\"中文🙂\" + 42"
        let tokens = SyntaxHighlighter.tokens(source, filename: "file.swift")
        #expect(tokens.map { (source as NSString).substring(with: $0.range) } == ["\"中文🙂\"", "42"])
    }
}
