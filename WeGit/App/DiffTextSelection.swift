import AppKit
import Observation
import WeGitCore

enum DiffCodeSide: Hashable { case unified, old, new }

@Observable @MainActor
final class DiffTextSelection {
    private(set) var revision = 0
    private var sources: [DiffCodeSide: [DiffLine]] = [:]
    private var anchor: CodeSelectionEndpoint?
    private var extent: CodeSelectionEndpoint?
    private var side: DiffCodeSide?
    private var explicitLine: Int?
    @ObservationIgnored private var cells: [CellKey: WeakCell] = [:]
    private struct CellKey: Hashable {
        let side: DiffCodeSide
        let line: Int
    }
    private struct WeakCell { weak var view: RawCodeTextView? }

    func replace(_ values: [DiffCodeSide: [DiffLine]]) {
        sources = values
        anchor = nil
        extent = nil
        side = nil
        explicitLine = nil
        revision += 1
        updateCells()
    }

    func register(_ view: RawCodeTextView, line: Int, side: DiffCodeSide) {
        cells[CellKey(side: side, line: line)] = WeakCell(view: view)
    }

    func cell(at point: NSPoint, in window: NSWindow, side: DiffCodeSide) -> RawCodeTextView? {
        cells.values.compactMap(\.view).first { view in
            view.window === window && view.side == side && !view.isHiddenOrHasHiddenAncestor
                && view.bounds.contains(view.convert(point, from: nil))
        }
    }

    func begin(line: Int, offset: Int, side: DiffCodeSide, extending: Bool) {
        explicitLine = nil
        if !extending || self.side != side || anchor == nil {
            anchor = CodeSelectionEndpoint(line: line, offset: offset)
        }
        self.side = side
        extent = CodeSelectionEndpoint(line: line, offset: offset)
        revision += 1
        updateCells()
    }

    func extend(line: Int, offset: Int, side: DiffCodeSide) {
        guard self.side == side, anchor != nil else { return }
        extent = CodeSelectionEndpoint(line: line, offset: offset)
        revision += 1
        updateCells()
    }

    func selectWholeLine(_ line: Int, side: DiffCodeSide) {
        guard let source = sources[side]?.first(where: { $0.id == line }) else { return }
        anchor = CodeSelectionEndpoint(line: line, offset: 0)
        extent = CodeSelectionEndpoint(line: line, offset: source.content.utf16.count)
        self.side = side
        explicitLine = line
        revision += 1
        updateCells()
    }

    func selectedLineIDs(includeContext: Bool) -> Set<Int> {
        guard let anchor, let extent, let side, let source = sources[side],
            let a = source.firstIndex(where: { $0.id == anchor.line }),
            let b = source.firstIndex(where: { $0.id == extent.line })
        else { return [] }
        let forward = a < b || a == b && anchor.offset <= extent.offset
        let first = forward ? anchor : extent
        let last = forward ? extent : anchor
        let lower = min(a, b)
        let upper = max(a, b)
        var ids: Set<Int> = []
        for index in lower...upper {
            let line = source[index]
            guard line.kind == "+" || line.kind == "-" || (includeContext && line.kind == " ") else {
                continue
            }
            let start = index == lower ? first.offset : 0
            let end = index == upper ? last.offset : line.content.utf16.count
            if start < end || explicitLine == line.id || (line.content.isEmpty && index < upper) {
                ids.insert(line.id)
            }
        }
        return ids
    }

    var spansCells: Bool { anchor?.line != extent?.line && anchor != nil && extent != nil }
    func copy() -> Bool {
        guard let anchor, let extent, let side, let source = sources[side],
            let text = CodeSelection.text(in: source, from: anchor, to: extent), !text.isEmpty
        else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    private func updateCells() {
        cells = cells.filter { $0.value.view != nil }
        for (key, cell) in cells {
            guard let view = cell.view else { continue }
            var range = NSRange(location: 0, length: 0)
            if let side, key.side == side, let source = sources[side], let anchor, let extent,
                let a = source.firstIndex(where: { $0.id == anchor.line }),
                let b = source.firstIndex(where: { $0.id == extent.line }),
                let index = source.firstIndex(where: { $0.id == key.line }), min(a, b) <= index,
                index <= max(a, b)
            {
                let forward = a < b || a == b && anchor.offset <= extent.offset
                let first = forward ? anchor : extent
                let last = forward ? extent : anchor
                let start = index == min(a, b) ? first.offset : 0
                let end = index == max(a, b) ? last.offset : view.presentation.visibleSource.utf16.count
                range = NSRange(location: start, length: max(0, end - start))
            }
            view.setSelectedRange(
                NSIntersectionRange(range, NSRange(location: 0, length: view.string.utf16.count)))
        }
    }
}
