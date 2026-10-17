import AppKit

#if HOSTED_SWIFTUI
    import SwiftUI
#endif

@MainActor
private func logControl(_ event: String) {
    FileHandle.standardOutput.write(Data("AppKit control: \(event)\n".utf8))
}

@MainActor
final class AppKitControlDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logControl("did-finish screens=\(NSScreen.screens.count)")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AppKit host control"
        window.isReleasedWhenClosed = false
        #if HOSTED_SWIFTUI
            window.contentView = NSHostingView(
                rootView: Text("Native scene ready").accessibilityIdentifier("control-ready")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { logControl("hosted-content-appeared") })
        #else
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
            let label = NSTextField(labelWithString: "Native scene ready")
            label.setAccessibilityIdentifier("control-ready")
            label.alignment = .center
            label.frame = NSRect(x: 50, y: 110, width: 300, height: 24)
            content.addSubview(label)
            window.contentView = content
        #endif
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        logControl("window-ordered visible=\(window.isVisible)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AppKitControl {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppKitControlDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
