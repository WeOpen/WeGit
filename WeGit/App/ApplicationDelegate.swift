import AppKit
import WeGitCore

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    var menuBarController: MenuBarController?
    var applicationMenu: NativeApplicationMenu?
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppStartupDiagnostics.record("application-did-finish")
        #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--uitesting"),
                ProcessInfo.processInfo.environment["WEGIT_UI_STARTUP_TRACE"] == "1"
            else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                AppStartupDiagnostics.record(
                    "windows-after-launch total=\(NSApp.windows.count) visible=\(NSApp.windows.filter(\.isVisible).count)"
                )
            }
        #endif
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state, state.anyOperationRunning else {
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
        state?.saveCurrentWorkspace()
        state?.authentication.cancelAll()
    }
}
