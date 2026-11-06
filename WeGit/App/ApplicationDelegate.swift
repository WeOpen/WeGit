import AppKit
import WeGitCore

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState? {
        didSet {
            guard let state else { return }
            let urls = pendingThemeURLs
            pendingThemeURLs = []
            for url in urls { state.receiveThemeURL(url) }
        }
    }
    private var pendingThemeURLs: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls.prefix(8) {
            if let state {
                state.receiveThemeURL(url)
            } else if pendingThemeURLs.count < 8 {
                pendingThemeURLs.append(url)
            }
        }
    }
    var menuBarController: MenuBarController?
    var applicationMenu: NativeApplicationMenu?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = state ?? menuBarController?.app
        if let state, state.runtime.updateHandoffInProgress {
            guard state.runtime.services.updateBridge?.permitsNormalExit() == true else {
                return .terminateCancel
            }
            state.runtime.updateTerminationApproved = true
            return .terminateNow
        }
        guard let state, state.anyOperationRunning else {
            if let coordinator = state?.runtime.windowCoordinator, !coordinator.saveAllWindows() {
                return .terminateCancel
            }
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("Git 操作仍在进行")
        alert.informativeText = L10n.text("请等待 Git 操作或配置保存完成，或在操作面板中取消并核对实际状态后，再退出 WeGit。")
        AppPresentation.configure(
            alert, appearance: AppPresentation.appearance(for: state.preferences.resolvedAppearance))
        alert.addButton(withTitle: L10n.text("返回应用"))
        alert.runModal()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        let state = state ?? menuBarController?.app
        if state?.runtime.updateTerminationApproved != true {
            _ = state?.runtime.windowCoordinator?.saveAllWindows()
        }
        state?.authentication.cancelAll()
    }
}
