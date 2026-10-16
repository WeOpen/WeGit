import AppKit
import SwiftUI

/// One window-local surface under its transparent titlebar, for main, settings and sheets.
struct ThemeWindowBridge: NSViewRepresentable {
    let colors: AppColors

    func makeNSView(context: Context) -> ThemeWindowProbe {
        let view = ThemeWindowProbe()
        view.setAccessibilityElement(false)
        view.colors = colors
        return view
    }

    func updateNSView(_ view: ThemeWindowProbe, context: Context) {
        view.colors = colors
        view.apply()
    }
}

@MainActor
final class ThemeWindowProbe: NSView {
    var colors = AppColors()
    private var appliedColors: AppColors?
    private weak var appliedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        guard let window else { return }
        let background = colors.resolvedNSColor(.chrome)
        guard
            appliedWindow !== window || appliedColors != colors
                || !window.titlebarAppearsTransparent || !window.backgroundColor.isEqual(background)
        else { return }
        appliedWindow = window
        appliedColors = colors
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if !window.backgroundColor.isEqual(background) { window.backgroundColor = background }
    }
}
