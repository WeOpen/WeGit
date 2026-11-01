import AppKit
import SwiftUI
import WeGitCore

struct RepositoryContextMenu: View {
    let app: AppState
    let record: RecentRepository
    private var url: URL { URL(fileURLWithPath: record.path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: record.path) }

    var body: some View {
        Button(L10n.text("打开仓库")) {
            app.repositoryPickerPresented = false
            Task { await app.open(url) }
        }
        Button(record.pinned ? L10n.text("取消收藏") : L10n.text("收藏")) { app.pin(record) }
        Divider()
        Button(L10n.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.disabled(
            !exists)
        Button(L10n.text("在 Terminal 中打开")) { app.openTerminal(at: url) }.disabled(!exists)
        if app.xcodeURL != nil {
            Button(L10n.text("在 Xcode 中打开…")) { app.openRepositoryInXcode(at: url) }.disabled(!exists)
        }
        Button(L10n.text("复制仓库路径")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.path, forType: .string)
        }
        Divider()
        Button(L10n.text("移除最近记录"), role: .destructive) { app.forget(record) }
    }
}
