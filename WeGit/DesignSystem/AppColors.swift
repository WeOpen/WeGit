import AppKit
import SwiftUI

/// Values travel through SwiftUI's environment; editing a theme never replaces a view or session.
struct AppColors: Equatable, Sendable {
    var custom: CustomTheme?
    var dark = false
    var increasedContrast = false

    var isCustom: Bool { custom != nil }

    func nsColor(_ role: ThemeColorRole) -> NSColor {
        if let hex = custom?[role], let rgb = ThemeRGB(hex: hex) {
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
        switch role {
        case .accent: return .controlAccentColor
        case .canvas, .chrome: return .controlBackgroundColor
        case .sidebar: return .windowBackgroundColor
        case .surface: return .controlBackgroundColor
        case .border: return .separatorColor
        case .text: return .labelColor
        case .secondaryText, .comment: return .secondaryLabelColor
        case .positive: return .systemGreen
        case .negative: return .systemRed
        case .modified: return .systemOrange
        case .diffAdded: return NSColor.systemGreen.withAlphaComponent(0.10)
        case .diffRemoved: return NSColor.systemRed.withAlphaComponent(0.10)
        case .keyword: return .systemPurple
        case .string: return .systemBrown
        case .number: return .linkColor
        }
    }

    func color(_ role: ThemeColorRole) -> Color {
        if custom == nil, role == .text { return .primary }
        return Color(nsColor: nsColor(role))
    }
    var accent: Color { color(.accent) }
    var primaryAction: Color { accent }
    var destructiveAction: Color { negative }
    var brandBlue: Color { custom == nil ? Color(nsColor: .systemBlue) : accent }
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
