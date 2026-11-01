import AppKit
import SwiftUI
import WeGitCore

/// A native selection/copy boundary inside each code cell, leaving paging and hunk
/// actions in SwiftUI. Neither selection nor display formatting can alter patches.
struct DiffSelectableText: NSViewRepresentable {
    @Environment(\.themeColors) private var colors
    let presentation: CodeTextPresentation
    let attributedText: NSAttributedString
    var selection: DiffTextSelection?
    var lineID = 0
    var side = DiffCodeSide.unified
    var wrappingWidth: CGFloat?
    var lineEnding = ""
    var performanceID: UUID?
    var readingLabel = L10n.text("代码文本")

    func makeNSView(context: Context) -> RawCodeTextView {
        let view = RawCodeTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        // SwiftUI supplies the effective width during measurement. Letting the
        // native frame resize this container would invalidate a cached result.
        view.textContainer?.widthTracksTextView = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: RawCodeTextView, context: Context) {
        view.selectedTextAttributes = [
            .backgroundColor: colors.isCustom
                ? colors.resolvedNSColor(.accent) : NSColor.selectedTextBackgroundColor,
            .foregroundColor: colors.isCustom ? NSColor(colors.selectionText) : NSColor.selectedTextColor,
        ]
        view.insertionPointColor = colors.resolvedNSColor(.text)
        view.performanceID = performanceID
        view.presentation = presentation
        view.lineEnding = lineEnding
        view.setAccessibilityLabel(readingLabel + (presentation.truncated ? L10n.text("，仅显示开头") : ""))
        view.selection = selection
        view.lineID = lineID
        view.side = side
        selection?.register(view, line: lineID, side: side)
        if !view.attributedString().isEqual(to: attributedText) {
            view.measuredWidth = nil
            view.measuredBounds = nil
            let selected = view.selectedRange()
            view.textStorage?.setAttributedString(attributedText)
            if selected.location <= attributedText.length {
                view.setSelectedRange(
                    NSRange(
                        location: selected.location,
                        length: min(selected.length, attributedText.length - selected.location)))
            }
        }
        view.toolTip = presentation.truncated ? L10n.text("本行仅显示开头；复制选区不包含省略标记。") : nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: RawCodeTextView, context: Context) -> CGSize?
    {
        let width = max(1, wrappingWidth ?? proposal.width ?? 1_000_000)
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        if view.measuredWidth == width, container.containerSize.width == width,
            let bounds = view.measuredBounds
        {
            return CGSize(
                width: wrappingWidth ?? proposal.width ?? ceil(bounds.width), height: ceil(bounds.height))
        }
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: 1_000_000)
        }
        layout.ensureLayout(for: container)
        let bounds = layout.usedRect(for: container)
        view.measuredWidth = width
        view.measuredBounds = bounds.size
        return CGSize(
            width: wrappingWidth ?? proposal.width ?? ceil(bounds.width), height: ceil(bounds.height))
    }
}

@MainActor
final class RawCodeTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var presentation = CodeTextPresentation(source: "", showWhitespace: false)
    var lineEnding = ""
    var measuredWidth: CGFloat?
    var measuredBounds: CGSize?
    var performanceID: UUID?
    #if WEGIT_PERFORMANCE
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if let performanceID, window?.occlusionState.contains(.visible) == true, !visibleRect.isEmpty {
                DispatchQueue.main.async { ViewPerformanceJournal.finish("diff", id: performanceID) }
            }
        }
    #endif
    weak var selection: DiffTextSelection?
    var lineID = 0
    var side = DiffCodeSide.unified

    private func offset(for event: NSEvent) -> Int {
        min(
            presentation.visibleSource.utf16.count,
            characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 1, let selection, let window {
            selection.begin(
                line: lineID, offset: offset(for: event), side: side,
                extending: event.modifierFlags.contains(.shift))
            // NSTextView's own tracking loop stays within a single cell. Track
            // this gesture in the shared loaded document so it can cross rows.
            while self.window === window && NSApp.isActive {
                guard
                    let next = window.nextEvent(
                        matching: [.leftMouseDragged, .leftMouseUp],
                        until: Date(timeIntervalSinceNow: 0.25), inMode: .eventTracking, dequeue: true)
                else { continue }
                if let peer = selection.cell(at: next.locationInWindow, in: window, side: side) {
                    selection.extend(line: peer.lineID, offset: peer.offset(for: next), side: side)
                }
                if next.type == .leftMouseUp { break }
                _ = autoscroll(with: next)
            }
            return
        }
        selection?.begin(
            line: lineID, offset: offset(for: event), side: side,
            extending: event.modifierFlags.contains(.shift))
        if event.modifierFlags.contains(.shift), selection?.spansCells == true {
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
        if selection?.spansCells != true {
            let range = selectedRange()
            selection?.begin(line: lineID, offset: range.location, side: side, extending: false)
            selection?.extend(line: lineID, offset: NSMaxRange(range), side: side)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let content = window?.contentView {
            let point =
                content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            var hit = content.hitTest(point)
            while let view = hit {
                if let peer = view as? RawCodeTextView, peer.selection === selection, peer.side == side {
                    if peer !== self || selection?.spansCells == true {
                        selection?.extend(line: peer.lineID, offset: peer.offset(for: event), side: side)
                        return
                    }
                    break
                }
                hit = view.superview
            }
        }
        super.mouseDragged(with: event)
    }

    override func copy(_ sender: Any?) {
        if selection?.spansCells == true {
            if selection?.copy() != true { NSSound.beep() }
            return
        }
        guard let source = presentation.selectedSource(in: selectedRange()), !source.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        let length = presentation.visibleSource.utf16.count
        selection?.begin(line: lineID, offset: 0, side: side, extending: false)
        selection?.extend(line: lineID, offset: length, side: side)
        setSelectedRange(NSRange(location: 0, length: length))
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        // Navigation keys can replace a shared cross-cell range with a native
        // range in this cell. Keep Copy bound to the range the user now sees.
        if window?.firstResponder === self, [123, 124, 125, 126, 115, 119].contains(event.keyCode) {
            let range = selectedRange()
            selection?.begin(line: lineID, offset: range.location, side: side, extending: false)
            selection?.extend(line: lineID, offset: NSMaxRange(range), side: side)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self,
            event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command
        {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                copy(nil)
                return true
            case "a":
                selectAll(nil)
                return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: L10n.text("复制选区"), action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let line = NSMenuItem(
            title: presentation.sourceIncomplete ? L10n.text("复制显示部分") : L10n.text("复制完整行"),
            action: #selector(copyLine(_:)),
            keyEquivalent: "")
        line.target = self
        menu.addItem(line)
        return menu
    }

    @objc private func copyLine(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            presentation.sourceIncomplete ? presentation.visibleSource : presentation.source + lineEnding,
            forType: .string)
    }
}
