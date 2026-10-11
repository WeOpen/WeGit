import Foundation
import Testing

@testable import WeGitCore

struct CodeTextPresentationTests {
    @Test func selectionAcrossLoadedCellsPreservesSourceOrderAndLineEndings() {
        let lines = [
            DiffLine(id: 1, kind: " ", content: "\tfirst 中文🙂\r", oldLine: 1, newLine: 1),
            DiffLine(id: 2, kind: "+", content: "  second\r", oldLine: nil, newLine: 2),
            DiffLine(id: 3, kind: "+", content: "third", oldLine: nil, newLine: 3),
        ]
        let start = CodeSelectionEndpoint(line: 1, offset: 1)
        let end = CodeSelectionEndpoint(line: 3, offset: 2)
        let expected = "first 中文🙂\r\n  second\r\nth"
        #expect(CodeSelection.text(in: lines, from: start, to: end) == expected)
        #expect(CodeSelection.text(in: lines, from: end, to: start) == expected)
        #expect(CodeSelection.text(in: Array(lines.prefix(2)), from: start, to: end) == nil)
        let truncated = [
            lines[0],
            DiffLine(id: 2, kind: "+", content: "partial", oldLine: nil, newLine: 2, truncated: true),
            lines[2],
        ]
        #expect(CodeSelection.text(in: truncated, from: start, to: end) == nil)
    }

    @Test func copyUsesOriginalWhitespaceAndUnicodeOffsets() throws {
        let raw = "\tlet 中文🙂 = \"a b\"\r"
        let shown = CodeTextPresentation(source: raw, showWhitespace: true)
        #expect(shown.displayed == "⇥let·中文🙂·=·\"a·b\"␍")
        #expect(shown.selectedSource(in: NSRange(location: 0, length: shown.displayed.utf16.count)) == raw)
        let selected = (raw as NSString).range(of: "中文🙂 =")
        #expect(shown.selectedSource(in: selected) == "中文🙂 =")
        #expect(shown.selectedSource(in: NSRange(location: 7, length: 1)) == nil)
    }

    @Test func truncatedDisplayDoesNotCopyEllipsisOrBrokenUnicode() {
        let raw = "ab🙂z"
        let shown = CodeTextPresentation(source: raw, showWhitespace: false, byteLimit: 4)
        #expect(shown.displayed == "ab…")
        #expect(shown.source == raw)
        #expect(shown.selectedSource(in: NSRange(location: 0, length: 3)) == "ab")
        #expect(shown.selectedSource(in: NSRange(location: 2, length: 1)) == "")
        #expect(!shown.visibleSource.contains("�"))
    }

    @Test func emptyAndInvalidSelectionsNeverFabricateSource() {
        let shown = CodeTextPresentation(source: "", showWhitespace: true)
        #expect(shown.displayed == " ")
        #expect(shown.selectedSource(in: NSRange(location: 0, length: 1)) == "")
        #expect(shown.selectedSource(in: NSRange(location: NSNotFound, length: 1)) == nil)
        #expect(shown.selectedSource(in: NSRange(location: 1, length: Int.max)) == nil)
    }
}
