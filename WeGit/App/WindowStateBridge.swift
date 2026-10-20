import AppKit
import SwiftUI
import WeGitCore

/// Uses AppKit's public autosave support for the native window and split views.
struct WindowStateBridge: NSViewRepresentable {
    let app: AppState
    let sidebarVisible: Bool
    let toggleSidebar: @MainActor () -> Void

    func makeNSView(context: Context) -> WindowStateProbe {
        let probe = WindowStateProbe()
        probe.setAccessibilityElement(false)
        probe.app = app
        probe.sidebarVisible = sidebarVisible
        probe.toggleSidebar = toggleSidebar
        return probe
    }

    func updateNSView(_ probe: WindowStateProbe, context: Context) {
        probe.sidebarVisible = sidebarVisible
        probe.toggleSidebar = toggleSidebar
        probe.scheduleConfiguration()
    }
}

@MainActor
final class WindowStateProbe: NSView {
    weak var app: AppState?
    private weak var configuredWindow: NSWindow?
    private var scheduled = false
    var sidebarVisible = true
    var toggleSidebar: @MainActor () -> Void = {}
    private weak var sidebarItem: NSToolbarItem?
    private var sidebarHost: NSHostingView<SidebarToolbarControl>?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfiguration()
    }

    func scheduleConfiguration() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scheduled = false
            configure()
        }
    }

    private func configure() {
        guard let window, let app else { return }
        if app.sidebarVisible != sidebarVisible { app.sidebarVisible = sidebarVisible }
        if configuredWindow !== window {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didResizeNotification, object: configuredWindow)
            configuredWindow = window
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResize), name: NSWindow.didResizeNotification,
                object: window)
            NotificationCenter.default.removeObserver(
                self, name: NSToolbar.willAddItemNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(toolbarWillAddItem), name: NSToolbar.willAddItemNotification,
                object: nil)
            if app.savesWindowState { _ = window.setFrameUsingName(app.nativeWindowStateName) }
        }
        updateMeasuredWidth()
        _ = window.setFrameAutosaveName(app.savesWindowState ? app.nativeWindowStateName : "")
        // Keep the native tracking separator and sidebar placement. SwiftUI uses
        // its own item identifier rather than AppKit's standard toggle identifier.
        // If that metadata changes, the system button remains fully functional.
        if let item = window.toolbar?.items.first(where: {
            $0.itemIdentifier == .toggleSidebar
                || $0.itemIdentifier.rawValue == "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
        }) {
            let control = SidebarToolbarControl(
                preferences: app.preferences, visible: sidebarVisible,
                toggle: { [weak self] in self?.toggleSidebar() })
            if sidebarItem !== item {
                let host = NSHostingView(rootView: control)
                host.frame.size = NSSize(
                    width: AppStyle.toolbarControlHeight, height: AppStyle.toolbarControlHeight)
                host.setContentHuggingPriority(.required, for: .horizontal)
                host.setContentHuggingPriority(.required, for: .vertical)
                item.view = host
                item.isBordered = false
                sidebarHost = host
                sidebarItem = item
            } else {
                sidebarHost?.rootView = control
            }
        }
        guard let content = window.contentView else { return }
        var index = 0
        func visit(_ view: NSView) {
            if let table = view as? NSTableView, table.style == .sourceList {
                // The sidebar paints its blue selection while retaining native
                // list focus, keyboard navigation and accessibility selection.
                table.selectionHighlightStyle = .none
            }
            if let split = view as? NSSplitView, split.isVertical {
                let name = "\(app.nativeSplitStatePrefix).\(index)"
                if app.savesWindowState {
                    if split.autosaveName == nil { split.autosaveName = name }
                } else if split.autosaveName?.hasPrefix(app.nativeSplitStatePrefix + ".") == true {
                    split.autosaveName = nil
                }
                index += 1
            }
            for child in view.subviews { visit(child) }
        }
        visit(content)
    }

    @objc private func windowDidResize(_ notification: Notification) { updateMeasuredWidth() }

    @objc private func toolbarWillAddItem(_ notification: Notification) {
        guard notification.object as? NSToolbar === window?.toolbar else { return }
        scheduleConfiguration()
    }

    private func updateMeasuredWidth() {
        guard let app, let window else { return }
        let width = window.contentLayoutRect.width
        if width > 0, app.windowContentWidth != width { app.windowContentWidth = width }
    }
}

private struct SidebarToolbarControl: View {
    let preferences: AppPreferences
    let visible: Bool
    let toggle: @MainActor () -> Void

    var body: some View {
        Button(action: toggle) {
            Label(L10n.text("侧栏"), systemImage: "sidebar.left")
                .labelStyle(.iconOnly).font(.system(size: AppStyle.toolbarSymbolSize))
                .frame(width: AppStyle.toolbarControlHeight, height: AppStyle.toolbarControlHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("toolbar-sidebar")
        .accessibilityValue(visible ? L10n.text("已打开") : L10n.text("已关闭"))
        .help(visible ? L10n.text("隐藏侧栏") : L10n.text("显示侧栏"))
        // SwiftUI can recreate the native sidebar item when its column hides.
        // A custom hosting view must own its background across that transition.
        .modifier(SidebarToolbarSurface())
        .workbenchAppearance(preferences)
    }
}

private struct SidebarToolbarSurface: ViewModifier {
    @Environment(\.themeColors) private var colors
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(colors.surface, in: Circle())
                .overlay {
                    Circle().strokeBorder(colors.border, lineWidth: contrast == .increased ? 2 : 1)
                        .allowsHitTesting(false)
                }
        } else {
            content.glassEffect(.regular.interactive(), in: Circle())
        }
    }
}
