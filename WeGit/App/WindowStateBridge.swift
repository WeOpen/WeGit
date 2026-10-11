import AppKit
import SwiftUI

/// Uses AppKit's public autosave support for the native window and split views.
struct WindowStateBridge: NSViewRepresentable {
    let app: AppState

    func makeNSView(context: Context) -> WindowStateProbe {
        let probe = WindowStateProbe()
        probe.setAccessibilityElement(false)
        probe.app = app
        return probe
    }

    func updateNSView(_ probe: WindowStateProbe, context: Context) { probe.scheduleConfiguration() }
}

@MainActor
final class WindowStateProbe: NSView {
    weak var app: AppState?
    private weak var configuredWindow: NSWindow?
    private var scheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfiguration()
    }

    func scheduleConfiguration() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scheduled = false
            configure()
        }
    }

    private func configure() {
        guard let window, let app else { return }
        if configuredWindow !== window {
            configuredWindow = window
            if app.savesWindowState { _ = window.setFrameUsingName(app.nativeWindowStateName) }
        }
        _ = window.setFrameAutosaveName(app.savesWindowState ? app.nativeWindowStateName : "")
        guard let content = window.contentView else { return }
        var index = 0
        func visit(_ view: NSView) {
            if let split = view as? NSSplitView, split.isVertical {
                let name = "\(app.nativeSplitStatePrefix).\(index)"
                if app.savesWindowState {
                    if split.autosaveName == nil { split.autosaveName = name }
                } else if split.autosaveName?.hasPrefix(app.nativeSplitStatePrefix + ".") == true {
                    split.autosaveName = nil
                }
                index += 1
            }
            for child in view.subviews { visit(child) }
        }
        visit(content)
    }
}
