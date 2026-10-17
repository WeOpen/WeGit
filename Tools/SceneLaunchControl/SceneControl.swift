import AppKit
import SwiftUI

@MainActor
private func trace(_ event: String) {
    FileHandle.standardOutput.write(Data("Scene control: \(event)\n".utf8))
}

@MainActor
final class SceneControlDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        trace("did-finish windows=\(NSApp.windows.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            trace(
                "after-launch windows=\(NSApp.windows.count) visible=\(NSApp.windows.filter(\.isVisible).count)"
            )
        }
    }
}

@main
struct SceneControl: App {
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        trace(
            "init marker=\(arguments.contains("--uitesting")) "
                + "language=\(arguments.contains("-language")) "
                + "private-global=\(environment["GIT_CONFIG_GLOBAL"] == "/dev/null") "
                + "private-system=\(environment["GIT_CONFIG_SYSTEM"] == "/dev/null")")
    }

    #if !BARE_WINDOW_GROUP
        @NSApplicationDelegateAdaptor(SceneControlDelegate.self) private var delegate
    #endif

    var body: some Scene {
        #if BARE_WINDOW_GROUP
            WindowGroup { content() }
        #elseif SINGLE_WINDOW
            Window("Scene control", id: "control") { content() }
                .defaultSize(width: 400, height: 240)
                .defaultLaunchBehavior(.presented)
                .windowResizability(.contentMinSize)
                .commandsRemoved()
        #else
            WindowGroup("Scene control", id: "control") { content() }
                .defaultSize(width: 400, height: 240)
                .defaultLaunchBehavior(.presented)
                .windowResizability(.contentMinSize)
                .commandsRemoved()
        #endif
        #if !BARE_WINDOW_GROUP
            Settings { Text("Control settings") }.commandsRemoved()
        #endif
    }

    private func content() -> some View {
        trace("content-built")
        return Text("Native scene ready")
            .accessibilityIdentifier("control-ready")
            .frame(minWidth: 300, minHeight: 160)
            .onAppear { trace("content-appeared") }
    }
}
