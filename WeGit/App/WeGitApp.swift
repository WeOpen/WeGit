import AppKit
import SwiftUI
import WeGitCore

@main
struct WeGitApp: App {
    @State private var app = AppState()
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    var body: some Scene {
        Window("WeGit", id: "main") {
            WorkspaceView(app: app)
                .workbenchControlFamily()
                .background(MenuBarRegistration(app: app, delegate: delegate).frame(width: 0, height: 0))
                .workbenchAppearance(app.preferences)

                .task {
                    delegate.state = app
                    await ViewPerformanceJournal.waitForProfiler()
                    guard !Task.isCancelled else { return }
                    await app.restore()
                    app.runtime.windowCoordinator?.restoreOpenWindows()
                    let arguments = ProcessInfo.processInfo.arguments
                    if let index = arguments.firstIndex(of: "--update-handoff"), index + 1 < arguments.count {
                        do {
                            guard let bridge = app.runtime.services.updateBridge else {
                                throw UpdateFailure.configurationMissing
                            }
                            try await bridge.reportStartupReadiness(
                                ticketURL: URL(fileURLWithPath: arguments[index + 1]))
                        } catch {
                            app.error = error.localizedDescription
                        }
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                ) { _ in
                    if !app.preferences.configurationWriteInProgress { app.runtime.refreshActiveSessions() }
                }
        }
        .defaultSize(width: 1360, height: 880)
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentMinSize)
        .commandsRemoved()
        Settings {
            SettingsView(app: app.runtime.activeState ?? app).workbenchControlFamily().workbenchAppearance(
                app.preferences)
        }.commandsRemoved()

    }
}
