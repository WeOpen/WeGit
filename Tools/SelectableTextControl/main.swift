import AppKit
import SwiftUI

struct ControlView: View {
    @State private var changed = false
    private var value: String {
        (changed ? "B-endpoint/" : "A-endpoint/") + String(repeating: "long-path/", count: 14)
            + "repository.git"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LabeledContent("Plain") {
                Text(value).textSelection(.enabled).accessibilityIdentifier("plain-value")
            }
            LabeledContent("Identity") {
                Text(value).textSelection(.enabled).id(value).accessibilityIdentifier("identity-value")
            }
            LabeledContent("Explicit value") {
                Text(value).textSelection(.enabled).accessibilityValue(value).accessibilityIdentifier(
                    "explicit-value")
            }
            Button("Change") { changed.toggle() }
        }.padding(24).frame(width: 640, height: 280)
    }
}
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Selectable Text Control"
        w.contentView = NSHostingView(rootView: ControlView())
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        NSApp.activate(ignoringOtherApps: true)
    }
}
let delegate = Delegate()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
