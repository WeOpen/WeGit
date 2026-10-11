import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state, state.anyOperationRunning else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Git 操作仍在进行"
        alert.informativeText = "请等待 Git 操作或配置保存完成，或在操作面板中取消并核对实际状态后，再退出 WeGit。"
        alert.addButton(withTitle: "返回应用")
        alert.runModal()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        state?.saveCurrentWorkspace()
        state?.authentication.cancelAll()
    }
}
