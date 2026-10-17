import AppKit
import SwiftUI
import WeGitCore

@main
struct WeGitApp: App {
    @State private var app = AppState()
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    var body: some Scene {
        let _ = AppStartupDiagnostics.record("scene-body")
        Window("WeGit", id: "main") {
            WorkspaceView(app: app)
                .workbenchControlFamily()
                .background(MenuBarRegistration(app: app, delegate: delegate).frame(width: 0, height: 0))
                .workbenchAppearance(app.preferences)
                .onAppear { AppStartupDiagnostics.record("workspace-appeared") }

                .task {
                    delegate.state = app
                    await ViewPerformanceJournal.waitForProfiler()
                    guard !Task.isCancelled else { return }
                    await app.restore()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                ) { _ in
                    if let session = app.session, !session.isBusy,
                        !app.preferences.configurationWriteInProgress
                    {
                        Task { await session.refresh() }
                    }
                }
        }
        .defaultSize(width: 1360, height: 880)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentMinSize)
        .commandsRemoved()
        Settings {
            SettingsView(app: app).workbenchControlFamily().workbenchAppearance(app.preferences)
        }.commandsRemoved()

    }
}
