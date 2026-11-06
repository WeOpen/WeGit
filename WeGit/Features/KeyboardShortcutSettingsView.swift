import AppKit
import SwiftUI
import WeGitCore

struct KeyboardShortcutSettingsView: View {
    let store: KeyboardShortcutPersistence
    var didChange: @MainActor () -> Void = {}
    @Environment(\.themeColors) private var colors
    @State private var revision = 0
    @State private var recording: KeyboardShortcutCommand?
    @State private var query = ""
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let _ = revision
        VStack(alignment: .leading, spacing: 12) {
            WorkbenchSearchField(
                prompt: L10n.text("搜索命令"), text: $query, identifier: "shortcut-command-search",
                focus: $searchFocused)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        store.catalog.filter {
                            query.isEmpty || L10n.key($0.title).localizedCaseInsensitiveContains(query)
                        }
                    ) {
                        command in
                        HStack(spacing: 12) {
                            Text(L10n.key(command.title)).lineLimit(1)
                            Spacer()
                            Button(store.binding(for: command.id)?.displayValue ?? L10n.text("未设置")) {
                                error = nil
                                recording = command
                            }
                            .frame(minWidth: 88).accessibilityLabel(
                                L10n.text("修改\(L10n.key(command.title))快捷键")
                            )
                            .accessibilityValue(
                                store.binding(for: command.id)?.displayValue ?? L10n.text("未设置")
                            )
                            .accessibilityIdentifier("shortcut-edit-" + command.id)
                            Button {
                                perform { try store.restore(command.id) }
                            } label: {
                                Image(systemName: "arrow.counterclockwise").frame(width: 20, height: 20)
                            }
                            .workbenchIconButton().accessibilityLabel(
                                L10n.text("恢复\(L10n.key(command.title))快捷键")
                            )
                            .disabled(store.overrides[command.id] == nil)
                        }.padding(.vertical, 6).accessibilityElement(children: .contain)
                        Divider()
                    }
                }.padding(.horizontal, 12)
            }.accessibilityIdentifier("shortcut-command-list")
                .workbenchSurface()
            if let error { Text(error).font(.callout).foregroundStyle(colors.negative) }
            HStack {
                Spacer()
                Button(L10n.text("恢复所有快捷键")) { perform { try store.restoreAll() } }
                    .disabled(store.overrides.isEmpty).accessibilityIdentifier("shortcut-restore-all")
            }
        }.padding(12)
            .sheet(item: $recording) { command in
                ShortcutRecordingSheet(command: command, store: store) {
                    revision += 1
                    didChange()
                }
            }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            error = nil
            revision += 1
            didChange()
        } catch { self.error = error.localizedDescription }
    }
}

private struct ShortcutRecordingSheet: View {
    let command: KeyboardShortcutCommand
    let store: KeyboardShortcutPersistence
    let changed: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.key(command.title), symbol: "keyboard")
            ShortcutKeyCapture { binding in
                save(binding)
            } cancelled: {
                dismiss()
            }
            .frame(height: 64).workbenchSurface()
            .accessibilityIdentifier("shortcut-recorder")
            if let error { Text(error).font(.callout).foregroundStyle(colors.negative) }
            HStack {
                Button(L10n.text("清除快捷键")) { save(nil) }
                    .accessibilityIdentifier("shortcut-clear")
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(22).frame(width: 440)
    }

    private func save(_ binding: KeyboardShortcutBinding?) {
        do {
            try store.set(binding, for: command.id)
            changed()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// This responder captures keys only while its own sheet is focused. No event monitor
/// or global shortcut registration changes text input anywhere else in the app.
private struct ShortcutKeyCapture: NSViewRepresentable {
    let captured: @MainActor (KeyboardShortcutBinding) -> Void
    let cancelled: @MainActor () -> Void
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.captured = captured
        view.cancelled = cancelled
        return view
    }
    func updateNSView(_ view: CaptureView, context: Context) {
        view.captured = captured
        view.cancelled = cancelled
        view.label.stringValue = L10n.text("按下新的快捷键")
    }

    @MainActor final class CaptureView: NSView {
        let label = NSTextField(labelWithString: L10n.text("按下新的快捷键"))
        var captured: @MainActor (KeyboardShortcutBinding) -> Void = { _ in }
        var cancelled: @MainActor () -> Void = {}
        override var acceptsFirstResponder: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            label.alignment = .center
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            ])
            focusRingType = .exterior
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(L10n.text("按下新的快捷键"))
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { window.makeFirstResponder(self) }
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() { bounds.fill() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self,
                !event.modifierFlags.intersection([.command, .control]).isEmpty
            else { return false }
            captured(KeyboardShortcutBinding(event: event))
            return true
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                cancelled()
                return
            }
            if event.keyCode == 48 && event.modifierFlags.intersection([.command, .control]).isEmpty {
                if event.modifierFlags.contains(.shift) {
                    window?.selectPreviousKeyView(self)
                } else {
                    window?.selectNextKeyView(self)
                }
                return
            }
            captured(KeyboardShortcutBinding(event: event))
        }
    }
}
