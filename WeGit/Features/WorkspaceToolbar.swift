import SwiftUI
import WeGitCore

struct RepositorySyncSummary: View {
    @Environment(\.themeColors) private var colors
    let session: RepositorySession

    var summary: String {
        if !session.hasLoaded || session.isStale { return L10n.text("待核对") }
        if session.status.head == nil { return L10n.text("尚无提交") }
        if session.status.isDetached { return "Detached" }
        if session.status.upstream == nil { return L10n.text("无上游") }
        guard let ahead = session.status.ahead, let behind = session.status.behind else {
            return L10n.text("待核对")
        }
        return ahead == 0 && behind == 0 ? L10n.text("已同步") : "↑\(ahead) ↓\(behind)"
    }

    var body: some View {
        Text(summary).font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(colors.secondaryText).lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(colors.surface, in: .capsule)
            .help(
                !session.hasLoaded || session.isStale
                    ? L10n.text("等待核对仓库与上游状态")
                    : session.status.upstream.map { L10n.text("上游：") + $0 } ?? L10n.text("尚未配置上游分支")
            )
            .accessibilityLabel(L10n.text("同步状态：") + summary)
    }
}

struct RepositoryFetchMenu: View {
    let session: RepositorySession
    /// Toolbar items get the toolbar cell size; copies inside a menu popover keep
    /// the in-window 30pt control height.
    var inToolbar = false

    var body: some View {
        Menu {
            ForEach(session.remotes, id: \.self) { remote in
                Button(L10n.text("获取 \(remote)")) {
                    session.perform(L10n.text("获取")) { try await $0.fetch(remote: remote) }
                }
            }
        } label: {
            Label(L10n.text("获取"), systemImage: "arrow.clockwise")
        }.workbenchGlassMenu(toolbar: inToolbar).disabled(!session.canWrite || session.remotes.isEmpty)
            .help(session.remotes.isEmpty ? L10n.text("尚未配置 Remote") : L10n.text("选择要获取的远端"))
            .accessibilityIdentifier("toolbar-fetch")
    }
}

struct RepositorySyncButtons: View {
    @Environment(\.themeColors) private var colors
    let app: AppState
    let session: RepositorySession
    var inToolbar = false

    var body: some View {
        Button(L10n.text("拉取"), systemImage: "arrow.down") { app.presentSync(.pull) }
            .workbenchControlFamily(toolbar: inToolbar)
            .help(session.syncReason).disabled(!session.canSync).accessibilityIdentifier("toolbar-pull")
        Button(L10n.text("推送"), systemImage: "arrow.up") { app.presentSync(.push) }
            .workbenchControlFamily(toolbar: inToolbar)
            .help(session.syncReason).disabled(!session.canSync).accessibilityIdentifier("toolbar-push")
    }
}
