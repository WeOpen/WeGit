import SwiftUI
import WeGitCore

struct FileContextMenu: View {
    let app: AppState
    let session: RepositorySession
    let path: String
    var historyPath: String?
    var body: some View {
        Button(L10n.text("查看文件历史…")) {
            guard app.session === session else { return }
            app.fileHistoryRequest = FileHistoryRequest(session: session, path: historyPath ?? path)
        }.accessibilityIdentifier("file-history:" + path)
        Button(L10n.text("逐行归属…")) {
            guard app.session === session, let revision = session.status.head else { return }
            app.blameRequest = BlameRequest(session: session, path: historyPath ?? path, revision: revision)
        }.accessibilityIdentifier("file-blame:" + path)
            .disabled(
                session.status.head == nil
                    || session.status.files.contains {
                        $0.path == path && ($0.untracked || $0.index == "A")
                    })
        Button(L10n.text("在文本编辑器中打开")) { app.openFile(path, in: session) }
            .disabled(!app.canOpenFile(path, in: session))
        if app.xcodeURL != nil {
            Button(L10n.text("在 Xcode 中打开")) { app.openFile(path, in: session, withXcode: true) }
                .disabled(!app.canOpenFile(path, in: session))
        }
        Button(L10n.text("在 Finder 中显示")) { app.revealFile(path, in: session) }
        Button(L10n.text("复制相对路径")) { app.copyFilePath(path, in: session, absolute: false) }
        Button(L10n.text("复制绝对路径")) { app.copyFilePath(path, in: session, absolute: true) }
    }
}
