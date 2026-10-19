import AppKit

#if AUDIT_HOSTED_SWIFTUI
    import SwiftUI
#endif

/// An independent SDK control: no WeGit views, colors, model or persisted settings.
@MainActor
final class AccessibilityControlDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private weak var status: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dark = ProcessInfo.processInfo.environment["CONTROL_APPEARANCE"] == "dark"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Independent accessibility control"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        #if AUDIT_HOSTED_SWIFTUI
            window.contentView = NSHostingView(
                rootView: AccessibilityControlView().preferredColorScheme(dark ? .dark : .light))
        #else
            let content = ControlBackground(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
            func label(_ value: String, y: CGFloat, identifier: String) -> NSTextField {
                let label = NSTextField(labelWithString: value)
                label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                label.textColor = .textColor
                label.frame = NSRect(x: 30, y: y, width: 460, height: 24)
                label.setAccessibilityIdentifier(identifier)
                content.addSubview(label)
                return label
            }
            _ = label("Native SDK controls ready", y: 300, identifier: "control-ready")
            _ = label(
                "97b9c7429bbeaa4d55b94ddec05bbd4162325cbd", y: 264, identifier: "control-sha")
            status = label("Not activated", y: 228, identifier: "control-status")
            let scope = NSPopUpButton(frame: NSRect(x: 30, y: 174, width: 180, height: 28))
            scope.addItems(withTitles: ["All references", "Current branch"])
            scope.setAccessibilityIdentifier("control-scope")
            scope.setAccessibilityLabel("Browse scope")
            content.addSubview(scope)
            let action = NSPopUpButton(
                frame: NSRect(x: 230, y: 174, width: 180, height: 28), pullsDown: true)
            action.addItems(withTitles: ["Actions", "Inspect selection"])
            action.setAccessibilityIdentifier("control-actions")
            action.setAccessibilityLabel("Selection actions")
            content.addSubview(action)
            let button = NSButton(title: "Activate", target: self, action: #selector(activate))
            button.frame = NSRect(x: 30, y: 110, width: 100, height: 32)
            button.bezelStyle = .rounded
            button.setAccessibilityIdentifier("control-button")
            content.addSubview(button)
            window.contentView = content
        #endif
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func activate() { status?.stringValue = "Activated" }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private final class ControlBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
    }
}

#if AUDIT_HOSTED_SWIFTUI
    private struct AccessibilityControlView: View {
        @State private var scope = "All references"
        @State private var activated = false

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("Native SDK controls ready").accessibilityIdentifier("control-ready")
                Text("97b9c7429bbeaa4d55b94ddec05bbd4162325cbd")
                    .accessibilityIdentifier("control-sha")
                Text(activated ? "Activated" : "Not activated").accessibilityIdentifier("control-status")
                HStack(spacing: 20) {
                    Picker("Browse scope", selection: $scope) {
                        Text("All references").tag("All references")
                        Text("Current branch").tag("Current branch")
                    }.labelsHidden().accessibilityLabel("Browse scope")
                        .accessibilityIdentifier("control-scope")
                    Menu("Actions") { Button("Inspect selection") {} }
                        .accessibilityLabel("Selection actions").accessibilityIdentifier("control-actions")
                }
                Button("Activate") { activated = true }.accessibilityIdentifier("control-button")
                Spacer()
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color(nsColor: .textColor))
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

#endif

@main
struct AccessibilityControl {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AccessibilityControlDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
