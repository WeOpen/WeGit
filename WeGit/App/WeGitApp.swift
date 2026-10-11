import AppKit
import SwiftUI

@main
struct WeGitApp: App {
    @State private var app = AppState()
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    var body: some Scene {
        Window("WeGit", id: "main") {
            WorkspaceView(app: app)
                .environment(app.preferences)
                .preferredColorScheme(
                    app.appearance == "system" ? nil : app.appearance == "dark" ? .dark : .light
                )
                .task {
                    delegate.state = app
                    await app.restore()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                ) { _ in
                    if let session = app.session, !session.isBusy { Task { await session.refresh() } }
                }
        }
        .defaultSize(width: 1360, height: 880)
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentMinSize)
        .commands {
            MainWindowCommands()
            CommandGroup(replacing: .newItem) {
                Button("打开仓库…", action: app.openPanel).keyboardShortcut("o")
                Button("克隆仓库…", action: app.presentClone).keyboardShortcut(
                    "o", modifiers: [.command, .shift])
                Button("切换仓库…") { app.repositoryPickerPresented = true }.keyboardShortcut("k")
            }
            CommandMenu("仓库") {
                Button("切换分支…", action: app.presentBranchSwitcher).disabled(app.session?.canWrite != true)
                Button("刷新") { Task { await app.session?.refresh() } }.keyboardShortcut("r").disabled(
                    app.session == nil)
                Button("新建分支…") { app.branchPresented = true }.keyboardShortcut(
                    "n", modifiers: [.command, .shift]
                ).disabled(app.session?.status.head == nil || app.session?.canWrite != true)
                Divider()
                Button("暂存全部", action: app.stageAll).disabled(!app.canStageAll)
                Button("取消全部暂存", action: app.unstageAll).disabled(!app.canUnstageAll)
                Button("提交", action: app.commitCurrent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(app.session?.canCommit != true)
                Button("提交并推送…") { app.presentSync(.commitAndPush) }
                    .disabled(app.session?.canCommitAndPush != true)
                Divider()
                Button("拉取…") { app.presentSync(.pull) }.keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(app.session?.canSync != true)
                Button("推送…") { app.presentSync(.push) }.keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(app.session?.canSync != true)
                Button("关闭仓库", action: app.closeRepository).disabled(
                    app.session == nil || app.session?.isBusy == true
                        || app.preferences.configurationWriteInProgress)
                Button("活动记录") { app.activityPresented = true }
                Button("在 Terminal 中打开", action: app.openTerminal).disabled(app.session == nil)
                Button("在 Xcode 中打开…", action: app.openRepositoryInXcode).disabled(
                    app.session == nil || app.xcodeURL == nil)
                Button("复制仓库路径", action: app.copyRepositoryPath).disabled(app.session == nil)
                Button("搜索当前仓库…", action: app.presentSearch).keyboardShortcut(
                    "f", modifiers: [.command, .shift]
                )
                .disabled(app.session == nil)
                Button("命令面板…") { app.palettePresented = true }.keyboardShortcut(
                    "p", modifiers: [.command, .shift])
            }
            CommandMenu("工作区") {
                #if DEBUG
                    if app.canRecoverTrashFixture {
                        Button("核对并恢复回收夹具", action: app.recoverTrashFixture)
                    }
                #endif
                ForEach(Array(WorkspaceRoute.allCases.enumerated()), id: \.element.id) { index, route in
                    Button(route.rawValue) { app.workspace.route = route }.keyboardShortcut(
                        KeyEquivalent(Character(String(index + 1)))
                    ).disabled(app.session == nil)
                }
            }
        }
        Settings { SettingsView(app: app).environment(app.preferences) }
    }
}

private struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("显示 WeGit 主窗口") { openWindow(id: "main") }
        }
    }
}
