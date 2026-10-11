import SwiftUI
import WeGitCore

struct FileContextMenu: View {
    let app: AppState
    let session: RepositorySession
    let path: String
    var body: some View {
        Button("在文本编辑器中打开") { app.openFile(path, in: session) }
            .disabled(!app.canOpenFile(path, in: session))
        if app.xcodeURL != nil {
            Button("在 Xcode 中打开") { app.openFile(path, in: session, withXcode: true) }
                .disabled(!app.canOpenFile(path, in: session))
        }
        Button("在 Finder 中显示") { app.revealFile(path, in: session) }
        Button("复制相对路径") { app.copyFilePath(path, in: session, absolute: false) }
        Button("复制绝对路径") { app.copyFilePath(path, in: session, absolute: true) }
    }
}
