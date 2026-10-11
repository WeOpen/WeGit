import Foundation

/// Display substitutions preserve UTF-16 offsets. Synthetic ellipses and empty-line
/// placeholders are never part of the source text copied by the native reader.
public struct CodeTextPresentation: Sendable {
    public let source: String
    public let visibleSource: String
    public let displayed: String
    public let truncated: Bool
    public let sourceIncomplete: Bool

    public init(source: String, showWhitespace: Bool, truncated: Bool = false, byteLimit: Int = 8192) {
        self.source = source
        sourceIncomplete = truncated
        var prefix = Data(source.utf8.prefix(max(0, byteLimit)))
        while String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        visibleSource = String(decoding: prefix, as: UTF8.self)
        self.truncated = truncated || prefix.count < source.utf8.count
        let whitespace =
            showWhitespace
            ? visibleSource.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\t", with: "⇥")
            : visibleSource
        let code = whitespace.replacingOccurrences(of: "\r", with: showWhitespace ? "␍" : " ")
        displayed = code + (self.truncated ? "…" : code.isEmpty ? " " : "")
    }

    public func selectedSource(in selection: NSRange) -> String? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
            selection.location <= visibleSource.utf16.count
        else { return nil }
        let count = min(selection.length, visibleSource.utf16.count - selection.location)
        let units = Array(visibleSource.utf16)
        let end = selection.location + count
        for offset in [selection.location, end] where offset > 0 && offset < units.count {
            if (0xDC00...0xDFFF).contains(units[offset]), (0xD800...0xDBFF).contains(units[offset - 1]) {
                return nil
            }
        }
        return String(decoding: units[selection.location..<end], as: UTF16.self)
    }
}
