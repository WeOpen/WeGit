import AppKit
import SwiftUI
import WeGitCore

@MainActor
final class WorkspaceWindowCoordinator: NSObject {
    private weak var primary: AppState?
    private weak var delegate: ApplicationDelegate?
    private var controllers: [UUID: WorkspaceWindowController] = [:]
    private var windows: [UUID: WeakWorkspaceWindow] = [:]
    private var closeDelegates: [UUID: WorkspaceCloseDelegate] = [:]
    private var failedClosedWindows: [UUID: (AppState, NSWindow)] = [:]
    private let previousActiveID: UUID?
    private var restored = false
    var showPrimary: @MainActor () -> Void = {}

    init(primary: AppState, delegate: ApplicationDelegate) {
        self.primary = primary
        self.delegate = delegate
        previousActiveID = primary.runtime.persistence?.lastActiveID
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(becameKey), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: nil)
    }

    func register(_ window: NSWindow, app: AppState) {
        windows[app.windowID] = WeakWorkspaceWindow(window)
        app.nativeWindow = window
        if window.delegate !== closeDelegates[app.windowID] {
            let proxy = WorkspaceCloseDelegate(app: app, original: window.delegate)
            closeDelegates[app.windowID] = proxy
            window.delegate = proxy
        }
        // Preserve the primary scene's stable automation/accessibility identity;
        // additional windows use their persistent session ID.
        window.setAccessibilityIdentifier(
            app.windowID == app.runtime.primaryWindowID
                ? "main" : "workspace-window-" + app.windowID.uuidString)
        if window.isKeyWindow { activate(app) }
    }

    func newWindow(repository: URL? = nil, restoring id: UUID? = nil) {
        guard let primary else { return }
        guard !primary.isMigrationBlocked, !primary.runtime.updateHandoffInProgress else { return }
        if let id, let existing = windows[id]?.value {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        if let id, id == primary.windowID {
            showPrimary()
            return
        }
        let app = AppState(sharedWith: primary, windowID: id ?? UUID())
        let controller = WorkspaceWindowController(app: app, repository: repository)
        controllers[app.windowID] = controller
        if let window = controller.window {
            register(window, app: app)
            if let visible = NSApp.keyWindow {
                window.cascadeTopLeft(from: NSPoint(x: visible.frame.minX, y: visible.frame.maxY))
            }
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func showActiveWindow() {
        guard let primary else { return }
        if let active = primary.runtime.activeState, let window = windows[active.windowID]?.value {
            window.makeKeyAndOrderFront(nil)
        } else {
            showPrimary()
        }
    }

    func reopenClosedWindow() {
        guard let primary,
            let saved = primary.runtime.persistence?.windows.first(where: { !$0.open })
        else { return }
        newWindow(restoring: saved.id)
    }

    func restoreOpenWindows() {
        guard !restored, let primary else { return }
        restored = true
        guard primary.preferences.restoreWindow,
            !AppState.isUITesting || ProcessInfo.processInfo.arguments.contains("--uitesting-restore-windows")
        else { return }
        for snapshot in primary.runtime.persistence?.windows ?? []
        where snapshot.open && snapshot.id != primary.windowID {
            newWindow(restoring: snapshot.id)
        }
        if let previousActiveID { windows[previousActiveID]?.value?.makeKeyAndOrderFront(nil) }
    }

    func saveAllWindows(forceForUpdate: Bool = false) -> Bool {
        guard let primary else { return true }
        var saved = true
        for app in primary.runtime.liveStates where app.mainWorkspaceMounted || app.workspaceSaveError != nil
        {
            if !app.saveCurrentWorkspace(forceForUpdate: forceForUpdate) { saved = false }
        }
        guard saved else { return false }
        guard primary.runtime.persistence != nil || !primary.preferences.restoreWindow else { return false }
        guard !primary.runtime.sessions.values.contains(where: { $0.draftSaveError != nil }) else {
            return false
        }
        do {
            try primary.runtime.persistence?.flush()
            return true
        } catch {
            primary.error = error.localizedDescription
            return false
        }
    }

    @objc private func becameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let primary,
            let app = primary.runtime.liveStates.first(where: { $0.nativeWindow === window })
        else { return }
        activate(app)
    }

    private func activate(_ app: AppState) {
        app.runtime.activeWindowID = app.windowID
        delegate?.state = app
        app.saveCurrentWorkspace()
    }

    @objc private func closed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let pair = windows.first(where: { $0.value.value === window }), let primary,
            let app = primary.runtime.liveStates.first(where: { $0.windowID == pair.key })
        else { return }
        guard app.windowDidClose() else {
            // A direct NSWindow.close can bypass delegate validation. Keep the
            // state and window alive so failed persistence cannot discard input.
            failedClosedWindows[pair.key] = (app, window)
            return
        }
        failedClosedWindows.removeValue(forKey: pair.key)
        windows.removeValue(forKey: pair.key)
        let closeDelegate = closeDelegates.removeValue(forKey: pair.key)
        let controller = controllers.removeValue(forKey: pair.key)
        // Keep forwarding and the hosting owner alive through this notification
        // delivery, including SwiftUI's own windowWillClose callback.
        DispatchQueue.main.async { withExtendedLifetime((closeDelegate, controller)) {} }
        if app.runtime.activeWindowID == app.windowID {
            app.runtime.activeWindowID = app.runtime.liveStates.first(where: \.mainWorkspaceMounted)?.windowID
        }
        delegate?.state = app.runtime.liveStates.first(where: \.mainWorkspaceMounted) ?? primary
    }
}

@MainActor private final class WeakWorkspaceWindow {
    weak var value: NSWindow?
    init(_ value: NSWindow) { self.value = value }
}

@MainActor private final class WorkspaceWindowController: NSWindowController {
    let app: AppState
    init(app: AppState, repository: URL?) {
        self.app = app
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "WeGit"
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: AdditionalWorkspaceRoot(app: app, repository: repository))
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Retains SwiftUI's own delegate and forwards every delegate method except the
/// close decision, which first verifies the window's persistence transaction.
@MainActor private final class WorkspaceCloseDelegate: NSObject, NSWindowDelegate {
    private weak var app: AppState?
    // NSObject's forwarding hooks are nonisolated. AppKit delegate access is
    // still confined to the main actor, checked at both forwarding entry points.
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
    init(app: AppState, original: (any NSWindowDelegate)?) {
        self.app = app
        self.original = original
        super.init()
    }
    nonisolated override func responds(to selector: Selector!) -> Bool {
        MainActor.preconditionIsolated()
        return super.responds(to: selector) || original?.responds(to: selector) == true
    }
    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        MainActor.preconditionIsolated()
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard original?.windowShouldClose?(sender) != false else { return false }
        guard let app else { return true }
        if !app.prepareWindowClose() {
            let alert = NSAlert()
            alert.messageText = L10n.text("请先完成当前窗口的操作")
            alert.informativeText =
                app.session?.draftSaveError
                ?? app.workspaceSaveError
                ?? L10n.text("请等待克隆或仓库创建完成，或在操作面板中取消并核对结果。")
            AppPresentation.configure(
                alert, appearance: AppPresentation.appearance(for: app.preferences.resolvedAppearance))
            alert.addButton(withTitle: L10n.text("返回窗口"))
            alert.runModal()
            return false
        }
        return true
    }
}

private struct AdditionalWorkspaceRoot: View {
    let app: AppState
    let repository: URL?
    var body: some View {
        WorkspaceView(app: app).workbenchControlFamily().workbenchAppearance(app.preferences)
            .task {
                await app.restore()
                guard !Task.isCancelled else { return }
                if let repository { await app.open(repository) }
            }
    }
}
