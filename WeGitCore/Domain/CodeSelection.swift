import Foundation

public struct CodeSelectionEndpoint: Equatable, Sendable {
    public let line: Int
    public let offset: Int
    public init(line: Int, offset: Int) {
        self.line = line
        self.offset = offset
    }
}

public enum CodeSelection {
    /// The caller supplies only the currently loaded code cells in display order.
    /// A truncated intermediate line cannot silently become a complete copied line.
    public static func text(
        in lines: [DiffLine], from anchor: CodeSelectionEndpoint, to extent: CodeSelectionEndpoint
    ) -> String? {
        guard let a = lines.firstIndex(where: { $0.id == anchor.line }),
            let b = lines.firstIndex(where: { $0.id == extent.line })
        else { return nil }
        let forward = a < b || a == b && anchor.offset <= extent.offset
        let first = forward ? anchor : extent
        let last = forward ? extent : anchor
        let lower = min(a, b)
        let upper = max(a, b)
        var result = ""
        for index in lower...upper {
            let line = lines[index]
            guard line.kind != "\\", !line.truncated || lower == upper else { return nil }
            let source = CodeTextPresentation(source: line.content, showWhitespace: false)
            let start = index == lower ? first.offset : 0
            let end = index == upper ? last.offset : line.content.utf16.count
            guard start >= 0, end >= start, end <= line.content.utf16.count,
                let part = source.selectedSource(in: NSRange(location: start, length: end - start))
            else { return nil }
            // Only a cell's visible prefix is selectable. A multi-cell selection must
            // not skip a hidden suffix before proceeding to the next code cell.
            guard index == upper || source.visibleSource.utf16.count == line.content.utf16.count else {
                return nil
            }
            result += part
            if index < upper && line.hasNewline { result += "\n" }
        }
        return result
    }
}
