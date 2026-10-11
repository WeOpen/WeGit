import AppKit
import SwiftUI

struct RepositoryContextMenu: View {
    let app: AppState
    let record: RecentRepository
    private var url: URL { URL(fileURLWithPath: record.path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: record.path) }

    var body: some View {
        Button("打开仓库") {
            app.repositoryPickerPresented = false
            Task { await app.open(url) }
        }
        Button(record.pinned ? "取消收藏" : "收藏") { app.pin(record) }
        Divider()
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.disabled(!exists)
        Button("在 Terminal 中打开") { app.openTerminal(at: url) }.disabled(!exists)
        if app.xcodeURL != nil {
            Button("在 Xcode 中打开…") { app.openRepositoryInXcode(at: url) }.disabled(!exists)
        }
        Button("复制仓库路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.path, forType: .string)
        }
        Divider()
        Button("移除最近记录", role: .destructive) { app.forget(record) }
    }
}
