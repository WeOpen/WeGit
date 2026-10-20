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

    private var counts: RepositorySyncCounts {
        RepositorySyncCounts(status: session.status, hasLoaded: session.hasLoaded, isStale: session.isStale)
    }

    private var syncHelp: String {
        guard let upstream = session.status.upstream, let ahead = counts.ahead, let behind = counts.behind
        else {
            return session.syncReason
        }
        return session.syncReason + "\n"
            + L10n.text("相对上游 \(upstream)：领先 \(ahead) 个提交，落后 \(behind) 个提交。") + "\n"
            + L10n.text("数量基于最近一次获取，请先获取以核对远端。")
    }

    var body: some View {
        syncButton(L10n.text("拉取"), symbol: "arrow.down", count: counts.behind, identifier: "toolbar-pull") {
            app.presentSync(.pull)
        }
        syncButton(L10n.text("推送"), symbol: "arrow.up", count: counts.ahead, identifier: "toolbar-push") {
            app.presentSync(.push)
        }
    }

    private func syncButton(
        _ title: String, symbol: String, count: Int?, identifier: String, action: @escaping () -> Void
    ) -> some View {
        let menuTitle = count.map { title + " " + String($0) } ?? title
        return Button(action: action) {
            if inToolbar {
                Label {
                    HStack(spacing: 6) {
                        Text(title)
                        if let count {
                            Text(String(count)).font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit().padding(.horizontal, 4).frame(minWidth: 16).frame(
                                    height: 16
                                )
                                .background(colors.text.opacity(0.08), in: .capsule)
                        }
                    }.fixedSize()
                } icon: {
                    Image(systemName: symbol)
                }
            } else {
                Label(menuTitle, systemImage: symbol)
            }
        }
        .workbenchControlFamily(toolbar: inToolbar)
        .accessibilityLabel(inToolbar ? title : menuTitle)
        .accessibilityValue(count.map(String.init) ?? L10n.text("待核对"))
        .help(syncHelp).disabled(!session.canSync).accessibilityIdentifier(identifier)
    }
}
