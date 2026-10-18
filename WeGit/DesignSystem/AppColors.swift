import AppKit
import SwiftUI
import Synchronization

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
        case .secondaryText: return NativeReadableColors.secondary
        case .comment: return NativeReadableColors.comment
        case .positive: return NativeReadableColors.positive
        case .negative: return NativeReadableColors.negative
        case .modified: return NativeReadableColors.modified
        case .diffAdded: return NSColor.systemGreen.withAlphaComponent(0.10)
        case .diffRemoved: return NSColor.systemRed.withAlphaComponent(0.10)
        case .keyword: return NativeReadableColors.keyword
        case .string: return NativeReadableColors.string
        case .number: return NativeReadableColors.number
        }
    }

    func color(_ role: ThemeColorRole) -> Color {
        if custom == nil, role == .text { return .primary }
        return Color(nsColor: nsColor(role))
    }
    var accent: Color { color(.accent) }
    var primaryAction: Color { custom == nil ? Color(nsColor: NativeReadableColors.primaryFill) : accent }
    var destructiveAction: Color {
        custom == nil ? Color(nsColor: NativeReadableColors.destructiveFill) : negative
    }
    var brandBlue: Color { custom == nil ? Color(nsColor: .systemBlue) : accent }
    var selectionBackground: Color {
        custom == nil ? Color(nsColor: NativeReadableColors.selectionFill) : accent
    }
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

/// Resolve the user's native appearance first, then change only the tone of an
/// insufficient pair. Custom theme values and native surfaces remain untouched.
private enum NativeReadableColors {
    private static let cache = Mutex<[Key: RGB]>([:])
    static let secondary = foreground(.secondaryLabelColor)
    static let comment = foreground(.secondaryLabelColor, wordHighlights: true)
    static let positive = foreground(.systemGreen)
    static let negative = foreground(.systemRed)
    static let modified = foreground(.systemOrange)
    static let keyword = foreground(.systemPurple, wordHighlights: true)
    static let string = foreground(.systemBrown, wordHighlights: true)
    static let number = foreground(.linkColor, wordHighlights: true)
    static let primaryFill = adjusted(.controlAccentColor, fill: true)
    static let destructiveFill = adjusted(.systemRed, fill: true)
    static let selectionFill = adjusted(.systemBlue, fill: true)

    private static func foreground(_ source: NSColor, wordHighlights: Bool = false) -> NSColor {
        adjusted(source, fill: false, wordHighlights: wordHighlights)
    }

    private static func adjusted(_ source: NSColor, fill: Bool, wordHighlights: Bool = false) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = source
            appearance.performAsCurrentDrawingAppearance {
                guard let native = RGB(source), let canvas = RGB(.controlBackgroundColor) else { return }
                if fill {
                    result =
                        cached([native, canvas, .white], minimumContrast: 6) {
                            // Keep white labels readable over native glass feedback
                            // and the sidebar count badge's 9% white overlay.
                            toned(native, over: [.white], canvas: canvas, minimumContrast: 6)
                        }.color
                    return
                }
                guard let selected = RGB(.unemphasizedSelectedContentBackgroundColor),
                    let green = RGB(.systemGreen), let red = RGB(.systemRed)
                else { return }
                result =
                    cached([native, canvas, green, red, selected], wordHighlights: wordHighlights) {
                        let addedSurface = green.withAlpha(0.10).over(canvas)
                        let removedSurface = red.withAlpha(0.10).over(canvas)
                        let base = [canvas, addedSurface, removedSurface, selected.over(canvas)]
                        var surfaces = base
                        if wordHighlights {
                            // Only native text/syntax spans sit on word highlights.
                            // Their tint uses the status tones resolved on base surfaces.
                            surfaces += [
                                toned(green, over: base, canvas: canvas)
                                    .withAlpha(0.24).over(addedSurface),
                                toned(red, over: base, canvas: canvas)
                                    .withAlpha(0.22).over(removedSurface),
                            ]
                        }
                        return toned(native, over: surfaces, canvas: canvas)
                    }.color
            }
            return result
        }
    }

    private static func cached(
        _ colors: [RGB], wordHighlights: Bool = false, minimumContrast: Double = 5, build: () -> RGB
    ) -> RGB {
        let key = Key(colors: colors, wordHighlights: wordHighlights, minimumContrast: minimumContrast)
        if let value = cache.withLock({ $0[key] }) { return value }
        let value = build()
        cache.withLock {
            if $0.count >= 128 { $0.removeAll(keepingCapacity: true) }
            $0[key] = value
        }
        return value
    }

    private struct Key: Hashable, Sendable {
        var colors: [RGB]
        var wordHighlights: Bool
        var minimumContrast: Double
    }

    private static func toned(
        _ native: RGB, over surfaces: [RGB], canvas: RGB, minimumContrast: Double = 5
    ) -> RGB {
        func minimum(_ color: RGB) -> Double {
            surfaces.map { color.over($0).contrast(with: $0) }.min()!
        }
        // Leave a margin for 8-bit compositing; the public target is 4.5.
        let target = minimumContrast
        if minimum(native) >= target { return native }
        let initial = native.over(canvas)
        let endpoint = minimum(.black) > minimum(.white) ? RGB.black : RGB.white
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<18 {
            let fraction = (lower + upper) / 2
            if minimum(initial.mixed(with: endpoint, fraction: fraction)) >= target {
                upper = fraction
            } else {
                lower = fraction
            }
        }
        // A neutral mix changes brightness without rotating the source hue.
        return initial.mixed(with: endpoint, fraction: upper)
    }

    private struct RGB: Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha = 1.0

        static let black = RGB(red: 0, green: 0, blue: 0)
        static let white = RGB(red: 1, green: 1, blue: 1)

        init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
        init?(_ color: NSColor) {
            guard let color = color.usingColorSpace(.sRGB) else { return nil }
            self.init(
                red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
                alpha: color.alphaComponent)
        }
        var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
        var luminance: Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        func contrast(with other: RGB) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }
        func over(_ background: RGB) -> RGB {
            RGB(
                red: red * alpha + background.red * (1 - alpha),
                green: green * alpha + background.green * (1 - alpha),
                blue: blue * alpha + background.blue * (1 - alpha))
        }
        func withAlpha(_ alpha: Double) -> RGB {
            RGB(red: red, green: green, blue: blue, alpha: alpha)
        }
        func mixed(with other: RGB, fraction: Double) -> RGB {
            RGB(
                red: red + (other.red - red) * fraction,
                green: green + (other.green - green) * fraction,
                blue: blue + (other.blue - blue) * fraction)
        }
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
