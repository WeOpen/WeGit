import AppKit
import Observation
import SwiftUI
import WeGitCore

struct MenuBarRegistration: View {
    let app: AppState
    let delegate: ApplicationDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.accessibilityHidden(true).onAppear {
            delegate.state = app
            if delegate.menuBarController == nil {
                delegate.menuBarController = MenuBarController(app: app)
            }
            delegate.menuBarController?.showMainWindow = { openWindow(id: "main") }
            delegate.menuBarController?.showSettings = { openSettings() }
            if delegate.applicationMenu == nil {
                delegate.applicationMenu = NativeApplicationMenu(app: app)
            }
            delegate.applicationMenu?.showMainWindow = {
                if !app.mainWorkspaceMounted { app.mainWindowRequested = true }
                openWindow(id: "main")
            }
            delegate.applicationMenu?.showSettings = { openSettings() }
            delegate.applicationMenu?.start()
        }
    }
}

/// Owns one native status item and popover, including while the main window is closed.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    let app: AppState
    var showMainWindow: @MainActor () -> Void = {}
    var showSettings: @MainActor () -> Void = {}
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var lastRequest: UUID

    init(app: AppState) {
        self.app = app
        lastRequest = app.menuBarRequestID
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        observe()
    }

    private func observe() {
        withObservationTracking {
            update(enabled: app.preferences.showMenuBar && app.allowsMenuBarExtra)
            let request = app.menuBarRequestID
            if request != lastRequest {
                lastRequest = request
                togglePanel()
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func update(enabled: Bool) {
        if enabled, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = MenuBarSymbol.image
            item.button?.toolTip = L10n.text("WeGit 快速访问")
            item.button?.setAccessibilityLabel(L10n.text("WeGit 快速访问"))
            item.button?.setAccessibilityIdentifier("menu-bar-status-item")
            item.button?.target = self
            item.button?.action = #selector(togglePanel)
            self.item = item
        } else if !enabled, let item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
        let title = L10n.text("WeGit 快速访问")
        item?.button?.toolTip = title
        item?.button?.setAccessibilityLabel(title)
        item?.button?.image?.accessibilityDescription = title
    }

    @objc private func togglePanel() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let content = MenuBarPanel(
            app: app, showMainWindow: { [weak self] in self?.showMainWindow() },
            showSettings: { [weak self] in self?.showSettings() },
            closePanel: { [weak self] in self?.popover.performClose(nil) }
        ).workbenchAppearance(app.preferences)
        let host = NSHostingController(rootView: content)
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        app.menuBarPresented = false
        if !app.mainWorkspaceMounted && !app.mainWindowRequested { app.session?.deactivate() }
        popover.contentViewController = nil
    }
}
