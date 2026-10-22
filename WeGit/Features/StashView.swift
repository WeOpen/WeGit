import SwiftUI
import WeGitCore

struct StashView: View {
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    var body: some View {
        StashBrowser(
            service: session.service, status: session.status, canWrite: session.canWrite,
            writeReason: session.writeReason, refreshID: session.statusRenderID,
            perform: { name, operation in
                guard app.session === session else { return }
                session.performResult(name, operation: operation)
            }, showChanges: { app.workspace.route = .changes }
        ) { contents, part in
            StashDiffView(app: app, session: session, contents: contents, part: part)
        }.id(session.id)
    }
}

private struct StashDiffView: View {
    let app: AppState
    let session: RepositorySession
    let contents: StashContents
    let part: StashPart
    @State private var detail: CommitDetailState
    init(app: AppState, session: RepositorySession, contents: StashContents, part: StashPart) {
        self.app = app
        self.session = session
        self.contents = contents
        self.part = part
        _detail = State(initialValue: CommitDetailState(service: session.service))
    }
    private var comparison: (GitCommit, String?) {
        switch part {
        case .working: (contents.working, contents.index.id)
        case .index: (contents.index, contents.base)
        case .untracked: (contents.untracked ?? contents.working, nil)
        }
    }
    var body: some View {
        CommitFilesView(app: app, session: session, detail: detail, stashContext: true)
            .task(id: "\(comparison.0.id):\(comparison.1 ?? "root")") {
                await detail.select(comparison.0, parent: comparison.1)
            }
            .onDisappear { detail.releaseCache() }
    }
}
