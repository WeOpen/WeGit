import AppKit
import Observation
import SwiftUI
import WeGitCore

@MainActor final class MenuBarSessionSubscription {
    private let owner = UUID()
    private var session: RepositorySession?
    func use(_ next: RepositorySession?) {
        guard session !== next else { return }
        session?.deactivate(owner: owner)
        session = next
        next?.activate(owner: owner)
    }
    func release() { use(nil) }
}

struct MenuBarRegistration: View {
    let app: AppState
    let delegate: ApplicationDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.accessibilityHidden(true).onAppear {
            delegate.state = app.runtime.activeState ?? app
            if app.runtime.windowCoordinator == nil {
                let coordinator = WorkspaceWindowCoordinator(primary: app, delegate: delegate)
                coordinator.showPrimary = { openWindow(id: "main") }
                app.runtime.windowCoordinator = coordinator
            }
            if let window = app.nativeWindow { app.runtime.windowCoordinator?.register(window, app: app) }
            if delegate.menuBarController == nil {
                delegate.menuBarController = MenuBarController(app: app)
            }
            delegate.menuBarController?.showMainWindow = { app.runtime.windowCoordinator?.showActiveWindow() }
            delegate.menuBarController?.showSettings = { openSettings() }
            if delegate.applicationMenu == nil {
                delegate.applicationMenu = NativeApplicationMenu(app: app)
            }
            delegate.applicationMenu?.showMainWindow = {
                if !app.mainWorkspaceMounted { app.mainWindowRequested = true }
                app.runtime.windowCoordinator?.showActiveWindow()
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
    private var lastRequests: [UUID: UUID]
    private weak var contentApp: AppState?
    private let subscription = MenuBarSessionSubscription()

    init(app: AppState) {
        self.app = app
        lastRequests = [app.windowID: app.menuBarRequestID]
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        observe()
    }

    private func observe() {
        withObservationTracking {
            update(enabled: app.preferences.showMenuBar && app.allowsMenuBarExtra)
            let states = app.runtime.liveStates
            lastRequests = lastRequests.filter { id, _ in states.contains { $0.windowID == id } }
            for state in states {
                _ = state.session
                let request = state.menuBarRequestID
                if let previous = lastRequests[state.windowID], previous != request {
                    showPanel(for: state)
                }
                lastRequests[state.windowID] = request
            }
            _ = app.runtime.activeWindowID
            if popover.isShown { subscription.use(contentApp?.session) }
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
        showPanel(for: app.runtime.activeState ?? app)
    }

    private func showPanel(for app: AppState) {
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
        contentApp = app
        subscription.use(app.session)
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        contentApp?.menuBarPresented = false
        subscription.release()
        contentApp = nil
        popover.contentViewController = nil
    }
}
