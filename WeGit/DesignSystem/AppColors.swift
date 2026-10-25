import AppKit
import SwiftUI
import Synchronization

/// Categorical color is independent of brand emphasis; it always accompanies a label or symbol.
enum InterfaceTone: CaseIterable {
    case blue, teal, violet, amber, green, rose
}

/// Values travel through SwiftUI's environment; editing a theme never replaces a view or session.
struct AppColors: Equatable, Sendable {
    var custom: CustomTheme?
    var dark = false
    var increasedContrast = false

    var isCustom: Bool { custom != nil }

    /// Calibrated per appearance so keywords, strings and numbers share one lightness
    /// instead of the louder system purple/brown/link defaults.
    var syntaxPalette: [ThemeColorRole: NSColor] {
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
        if let surface = NativePaperPalette.surface(role, dark: dark, increasedContrast: increasedContrast) {
            return surface
        }
        if let syntax = syntaxPalette[role] {
            return NativeReadableColors.foreground(syntax, wordHighlights: true)
        }
        switch role {
        case .accent: return NativePaperPalette.brand(dark: dark)
        case .canvas, .chrome, .sidebar, .surface: return .controlBackgroundColor
        case .border: return NativePaperPalette.border(dark: dark, increasedContrast: increasedContrast)
        case .text: return NativeReadableColors.text
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
        return Color(nsColor: nsColor(role))
    }
    var accent: Color { color(.accent) }
    var accentText: Color { custom == nil ? Color(nsColor: NativeReadableColors.accent) : accent }
    var primaryAction: Color { custom == nil ? Color(nsColor: NativeReadableColors.primaryFill) : accent }
    var destructiveAction: Color {
        custom == nil ? Color(nsColor: NativeReadableColors.destructiveFill) : negative
    }
    var brand: Color {
        custom == nil ? Color(nsColor: NativePaperPalette.brand(dark: dark)) : accent
    }
    func tone(_ tone: InterfaceTone) -> Color {
        let role: ThemeColorRole
        switch tone {
        case .blue: role = .number
        case .teal: role = .string
        case .violet: role = .keyword
        case .amber: role = .modified
        case .green: role = .positive
        case .rose: role = .negative
        }
        if custom != nil { return color(role) }
        return Color(nsColor: NativeReadableColors.category(tone))
    }

    func symbolTint(_ symbol: String) -> Color {
        if symbol.contains("tag") || symbol.contains("clock") { return tone(.violet) }
        if symbol.contains("branch") || symbol.contains("network") { return tone(.teal) }
        if symbol.contains("archive") || symbol.contains("tray") || symbol.contains("pencil") {
            return tone(.amber)
        }
        if symbol.contains("checkmark") || symbol.contains("terminal") { return tone(.green) }
        if symbol.hasPrefix("lock") || symbol.hasPrefix("key") || symbol.hasPrefix("shield") {
            return tone(.rose)
        }
        return tone(.blue)
    }

    var selectionBackground: Color {
        custom == nil ? Color(nsColor: NativeReadableColors.selectionFill) : accent
    }
    var canvas: Color { color(.canvas) }
    var chrome: Color { color(.chrome) }
    var sidebar: Color { color(.sidebar) }
    var surface: Color { color(.surface) }
    var border: Color { color(.border) }
    /// Required input boundaries remain opaque; the lighter border role structures surfaces.
    var controlBorder: Color {
        custom == nil
            ? Color(
                nsColor: NativePaperPalette.controlBorder(dark: dark, increasedContrast: increasedContrast))
            : border
    }
    /// Decoration only. Functional text, icons, focus and results use their existing roles.
    var celadon: Color {
        custom == nil ? Color(nsColor: NativePaperPalette.celadon(dark: dark)) : secondaryText
    }
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

/// Ivory and ink form the continuous workbench; categorical color stays in small meaningful accents.
/// Imported themes bypass this palette through the existing seventeen color roles.
private enum NativePaperPalette {
    static func surface(_ role: ThemeColorRole, dark: Bool, increasedContrast: Bool) -> NSColor? {
        switch role {
        case .canvas, .chrome, .surface: color(dark ? 0x1F1F1F : 0xF7F3ED)
        case .sidebar:
            color(
                dark ? (increasedContrast ? 0x141312 : 0x191817) : (increasedContrast ? 0xE7DED2 : 0xEEE7DC))
        default: nil
        }
    }

    static func border(dark: Bool, increasedContrast: Bool) -> NSColor {
        color(dark ? (increasedContrast ? 0x9F9487 : 0x4C443D) : (increasedContrast ? 0x847565 : 0xCBBFB0))
    }

    static func controlBorder(dark: Bool, increasedContrast: Bool) -> NSColor {
        color(dark ? (increasedContrast ? 0xCEC3B4 : 0x918373) : (increasedContrast ? 0x685749 : 0x8B7867))
    }

    static func brand(dark: Bool) -> NSColor { color(0xB3322D) }
    static func celadon(dark: Bool) -> NSColor { color(dark ? 0xA89A89 : 0xCFBFA9) }

    static let brandInk = NSColor(name: nil) { appearance in
        brand(dark: traits(appearance).dark)
    }

    static let ink = NSColor(name: nil) { appearance in
        let value = traits(appearance)
        return color(
            value.dark ? (value.increased ? 0xFFFDF8 : 0xF7F3ED) : (value.increased ? 0x151413 : 0x1F1F1F))
    }
    static let secondaryInk = NSColor(name: nil) { appearance in
        let value = traits(appearance)
        return color(
            value.dark ? (value.increased ? 0xDFD4C5 : 0xC3B8AA) : (value.increased ? 0x4C4138 : 0x5F574E))
    }

    static func traits(_ appearance: NSAppearance) -> (dark: Bool, increased: Bool) {
        let match = appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        return (
            match == .darkAqua || match == .accessibilityHighContrastDarkAqua,
            match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
        )
    }

    private static func color(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// Resolve native accents and status hues, then adjust only insufficient brightness.
/// Calibration uses the actual paper, porcelain, Diff and native selection surfaces.
private enum NativeReadableColors {
    private static let cache = Mutex<[Key: RGB]>([:])
    static let text = foreground(NativePaperPalette.ink, wordHighlights: true)
    static let accent = foreground(NativePaperPalette.brandInk)
    static let secondary = foreground(NativePaperPalette.secondaryInk)
    static let comment = foreground(NativePaperPalette.secondaryInk, wordHighlights: true)
    static let positive = foreground(.systemGreen)
    static let negative = foreground(.systemRed)
    static let modified = foreground(.systemOrange)
    static let keyword = foreground(.systemPurple, wordHighlights: true)
    static let string = foreground(.systemBrown, wordHighlights: true)
    static let number = foreground(.linkColor, wordHighlights: true)
    static let primaryFill = adjusted(NativePaperPalette.brandInk, fill: true)
    static let destructiveFill = adjusted(.systemRed, fill: true)
    static let selectionFill = adjusted(NativePaperPalette.brandInk, fill: true)

    static func category(_ tone: InterfaceTone) -> NSColor {
        let source: NSColor
        switch tone {
        case .blue: source = .systemBlue
        case .teal: source = .systemTeal
        case .violet: source = .systemPurple
        case .amber: source = .systemOrange
        case .green: source = .systemGreen
        case .rose: source = .systemPink
        }
        return adjusted(source, fill: false, minimumContrast: 6)
    }

    static func foreground(_ source: NSColor, wordHighlights: Bool = false) -> NSColor {
        adjusted(source, fill: false, wordHighlights: wordHighlights)
    }

    private static func adjusted(
        _ source: NSColor, fill: Bool, wordHighlights: Bool = false, minimumContrast: Double = 5
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = source
            appearance.performAsCurrentDrawingAppearance {
                let traits = NativePaperPalette.traits(appearance)
                guard let native = RGB(source),
                    let paper = NativePaperPalette.surface(
                        .canvas, dark: traits.dark, increasedContrast: traits.increased),
                    let porcelain = NativePaperPalette.surface(
                        .sidebar, dark: traits.dark, increasedContrast: traits.increased),
                    let canvas = RGB(paper), let sidebar = RGB(porcelain)
                else { return }
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
                    cached(
                        [native, canvas, sidebar, green, red, selected], wordHighlights: wordHighlights,
                        minimumContrast: minimumContrast
                    ) {
                        let addedSurface = green.withAlpha(0.10).over(canvas)
                        let removedSurface = red.withAlpha(0.10).over(canvas)
                        let base = [canvas, sidebar, addedSurface, removedSurface, selected.over(canvas)]
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
                        return toned(native, over: surfaces, canvas: canvas, minimumContrast: minimumContrast)
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
            if $0.count >= 256 { $0.removeAll(keepingCapacity: true) }
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
