import AppKit
import SwiftUI

/// Values travel through SwiftUI's environment; editing a theme never replaces a view or session.
struct AppColors: Equatable, Sendable {
    var custom: CustomTheme?
    var dark = false
    var increasedContrast = false

    var isCustom: Bool { custom != nil }

    /// Native semantic backgrounds collapse onto the same value in both appearances
    /// (`windowBackgroundColor` and `controlBackgroundColor` both resolve to pure white
    /// in light and 0.118 gray in dark), so the built-in theme derives an explicit
    /// recessed-to-raised ladder instead of borrowing role names.
    private struct SurfaceLadder {
        let sidebar: CGFloat
        let canvas: CGFloat
        let chrome: CGFloat
        let surface: CGFloat

        init(dark: Bool, increasedContrast: Bool) {
            switch (dark, increasedContrast) {
            case (false, false): (sidebar, canvas, chrome, surface) = (0.929, 0.964, 0.941, 1)
            case (false, true): (sidebar, canvas, chrome, surface) = (0.9, 0.95, 0.92, 1)
            case (true, false): (sidebar, canvas, chrome, surface) = (0.1, 0.118, 0.135, 0.185)
            case (true, true): (sidebar, canvas, chrome, surface) = (0.08, 0.098, 0.114, 0.21)
            }
        }

        func level(_ role: ThemeColorRole) -> CGFloat? {
            switch role {
            case .sidebar: sidebar
            case .canvas: canvas
            case .chrome: chrome
            case .surface: surface
            default: nil
            }
        }
    }

    /// Calibrated per appearance so keywords, strings and numbers share one lightness
    /// instead of the louder system purple/brown/link defaults.
    private var syntaxPalette: [ThemeColorRole: NSColor] {
        if dark {
            return [
                .keyword: NSColor(srgbRed: 0.72, green: 0.63, blue: 0.88, alpha: 1),
                .string: NSColor(srgbRed: 0.62, green: 0.8, blue: 0.71, alpha: 1),
                .number: NSColor(srgbRed: 0.6, green: 0.75, blue: 0.92, alpha: 1),
            ]
        }
        return [
            .keyword: NSColor(srgbRed: 0.45, green: 0.36, blue: 0.62, alpha: 1),
            .string: NSColor(srgbRed: 0.29, green: 0.49, blue: 0.42, alpha: 1),
            .number: NSColor(srgbRed: 0.28, green: 0.44, blue: 0.65, alpha: 1),
        ]
    }

    func nsColor(_ role: ThemeColorRole) -> NSColor {
        if let hex = custom?[role], let rgb = ThemeRGB(hex: hex) {
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
        if let level = SurfaceLadder(dark: dark, increasedContrast: increasedContrast).level(role) {
            return NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
        }
        if let syntax = syntaxPalette[role] { return syntax }
        switch role {
        case .accent: return .controlAccentColor
        case .canvas, .chrome, .sidebar, .surface: return .controlBackgroundColor
        case .border: return .separatorColor
        case .text: return .labelColor
        case .secondaryText, .comment: return .secondaryLabelColor
        case .positive: return .systemGreen
        case .negative: return .systemRed
        case .modified: return .systemOrange
        case .diffAdded: return NSColor.systemGreen.withAlphaComponent(0.10)
        case .diffRemoved: return NSColor.systemRed.withAlphaComponent(0.10)
        case .keyword, .string, .number: return .labelColor
        }
    }

    func color(_ role: ThemeColorRole) -> Color {
        if custom == nil, role == .text { return .primary }
        return Color(nsColor: nsColor(role))
    }
    var accent: Color { color(.accent) }
    var primaryAction: Color { accent }
    var destructiveAction: Color { negative }
    var brandBlue: Color { accent }
    var canvas: Color { color(.canvas) }
    var chrome: Color { color(.chrome) }
    var sidebar: Color { color(.sidebar) }
    var surface: Color { color(.surface) }
    var border: Color { color(.border) }
    var graphLine: Color { border }
    var focus: Color { custom == nil ? Color(nsColor: .keyboardFocusIndicatorColor) : accent }
    var text: Color { color(.text) }
    var secondaryText: Color { color(.secondaryText) }
    var positive: Color { color(.positive) }
    var negative: Color { color(.negative) }
    var modified: Color { color(.modified) }
    var link: Color { color(.number) }
    var keyword: Color { color(.keyword) }
    var string: Color { color(.string) }
    var comment: Color { color(.comment) }
    var diffAdded: Color { color(.diffAdded) }
    var diffRemoved: Color { color(.diffRemoved) }

    var selectionText: Color {
        guard let custom, let accent = ThemeRGB(hex: custom[.accent]) else { return .white }
        let black = ThemeRGB(hex: "#000000")!
        let white = ThemeRGB(hex: "#FFFFFF")!
        return black.contrast(with: accent) > white.contrast(with: accent) ? .black : .white
    }

    @MainActor var appearance: NSAppearance {
        NSAppearance(
            named: dark
                ? (increasedContrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
                : (increasedContrast ? .accessibilityHighContrastAqua : .aqua))!
    }

    @MainActor
    func resolvedNSColor(_ role: ThemeColorRole) -> NSColor {
        var result = nsColor(role)
        appearance.performAsCurrentDrawingAppearance {
            result = result.usingColorSpace(.sRGB) ?? result
        }
        return result
    }
}

private struct AppColorsKey: EnvironmentKey {
    static let defaultValue = AppColors()
}

extension EnvironmentValues {
    var themeColors: AppColors {
        get { self[AppColorsKey.self] }
        set { self[AppColorsKey.self] = newValue }
    }
}
