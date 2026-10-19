import AppKit
import Foundation
import SwiftUI

@main
struct ThemeChecks {
    @MainActor
    static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let suite = "com.willxue.wegit.ThemeChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            defaults.synchronize()
        }
        var checks: [String] = []
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(
                    domain: "WeGit.ThemeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks.append(message)
        }
        func rejects(_ data: Data, _ message: String) throws {
            do { _ = try CustomTheme.decode(data) } catch {
                checks.append(message)
                return
            }
            try require(false, message)
        }
        func equal(_ a: NSColor, _ b: NSColor) -> Bool {
            guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
            return abs(a.redComponent - b.redComponent) < 0.0001
                && abs(a.greenComponent - b.greenComponent) < 0.0001
                && abs(a.blueComponent - b.blueComponent) < 0.0001
        }
        let oldWorkspace: [String: Any] = [
            "route": "更改", "selectedFile": "unstaged|src/a.swift", "inspector": false,
            "filter": "src", "branchFilter": "", "splitDiff": false, "wordDiff": true,
            "contextLines": 3, "ignoreWhitespace": false,
        ]
        let legacyView = try JSONDecoder().decode(
            RepositoryViewPreferences.self, from: JSONSerialization.data(withJSONObject: oldWorkspace))
        try require(
            legacyView.changesByFolder == nil && legacyView.selectedFile == "unstaged|src/a.swift"
                && legacyView.filter == "src",
            "Old workspace records preserve their view and default to the file list")
        var folderWorkspace = oldWorkspace
        folderWorkspace["changesByFolder"] = true
        let folderView = try JSONDecoder().decode(
            RepositoryViewPreferences.self, from: JSONSerialization.data(withJSONObject: folderWorkspace))
        let roundTripView = try JSONDecoder().decode(
            RepositoryViewPreferences.self, from: JSONEncoder().encode(folderView))
        try require(
            roundTripView.changesByFolder == true && roundTripView == folderView,
            "Folder display preference round-trips with the repository workspace")
        func level(_ color: NSColor) -> CGFloat {
            (color.usingColorSpace(.sRGB) ?? color).redComponent
        }
        /// Native semantic backgrounds collapse onto one value, so the built-in theme
        /// derives its own ladder. Assert the shape of that ladder rather than fixed
        /// numbers, so retuning the steps cannot silently flatten it again.
        func requireLadder(_ colors: AppColors, _ appearance: String) throws {
            let levels = [
                level(colors.resolvedNSColor(.sidebar)), level(colors.resolvedNSColor(.canvas)),
                level(colors.resolvedNSColor(.chrome)), level(colors.resolvedNSColor(.surface)),
            ]
            try require(
                Set(levels.map { ($0 * 10_000).rounded() }).count == levels.count,
                "Built-in \(appearance) keeps sidebar, canvas, chrome and surface distinct")
            try require(
                levels[0] == levels.min()! && levels[3] == levels.max()!,
                "Built-in \(appearance) runs from the recessed sidebar up to the raised surface")
        }

        func resolve(_ color: NSColor, using colors: AppColors) -> NSColor {
            var result = color
            colors.appearance.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB)!
            }
            return result
        }
        func painted(_ foreground: NSColor, over background: NSColor) -> NSColor {
            let foreground = foreground.usingColorSpace(.sRGB)!
            let background = background.usingColorSpace(.sRGB)!
            let alpha = foreground.alphaComponent
            return NSColor(
                srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
                green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
                blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha), alpha: 1)
        }
        func contrast(_ foreground: NSColor, against background: NSColor) -> Double {
            func luminance(_ color: NSColor) -> Double {
                let color = color.usingColorSpace(.sRGB)!
                let components = [color.redComponent, color.greenComponent, color.blueComponent].map {
                    Double($0) <= 0.04045 ? Double($0) / 12.92 : pow((Double($0) + 0.055) / 1.055, 2.4)
                }
                return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
            }
            let a = luminance(painted(foreground, over: background))
            let b = luminance(background)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        let starter = try CustomTheme.starter.validated()
        try require(
            starter.colors.count == ThemeColorRole.allCases.count,
            "The custom theme contains every exposed color role")
        try require(
            starter.contrastIssues.isEmpty, "Starter text pairs meet the declared 4.5:1 warning threshold")
        let black = ThemeRGB(hex: "#000000")!
        let white = ThemeRGB(hex: "#FFFFFF")!
        try require(
            abs(black.contrast(with: white) - 21) < 0.0001, "Contrast uses the measured sRGB luminance ratio")
        try require(
            ThemeRGB(hex: " #abcDEF ")?.hex == "#ABCDEF", "Hex input normalizes without losing color values")
        try require(
            ThemeRGB(hex: "#FFFFFFFF") == nil && ThemeRGB(hex: "var(--x)") == nil,
            "Unsupported alpha and non-hex expressions are rejected")
        var theme = starter
        theme.name = "深海 · My theme 🙂"
        theme[.accent] = "#2f76d0"
        theme = try theme.validated()
        try require(
            try CustomTheme.decode(theme.encoded()) == theme,
            "JSON export and import preserve Unicode names and all colors")
        var object = try JSONSerialization.jsonObject(with: theme.encoded()) as! [String: Any]
        object["version"] = 2
        try rejects(JSONSerialization.data(withJSONObject: object), "Unknown theme versions are refused")
        object = try JSONSerialization.jsonObject(with: theme.encoded()) as! [String: Any]
        var incomplete = theme.colors
        incomplete.removeValue(forKey: "canvas")
        object["colors"] = incomplete
        try rejects(JSONSerialization.data(withJSONObject: object), "Missing color roles are refused")
        incomplete = theme.colors
        incomplete["unknown"] = "#123456"
        object["colors"] = incomplete
        try rejects(JSONSerialization.data(withJSONObject: object), "Unknown color roles are refused")
        incomplete = theme.colors
        incomplete["canvas"] = "#12"
        object["colors"] = incomplete
        try rejects(JSONSerialization.data(withJSONObject: object), "Invalid hex colors are refused")
        try rejects(
            Data(repeating: 32, count: CustomTheme.maximumFileSize + 1), "Oversized imports are refused")
        try rejects(Data("{broken".utf8), "Malformed JSON is refused")

        let preferences = AppPreferences(defaults: defaults)
        preferences.appearance = "dark"
        let nativeDark = preferences.themeColors
        try require(
            nativeDark.custom == nil && nativeDark.dark, "Built-in Dark has no custom color overrides")
        try requireLadder(nativeDark, "Dark")
        preferences.appearance = "light"
        let nativeLight = preferences.themeColors
        try require(
            nativeLight.custom == nil && !nativeLight.dark, "Built-in Light has no custom color overrides")
        try requireLadder(nativeLight, "Light")

        for dark in [false, true] {
            for increased in [false, true] {
                let colors = AppColors(dark: dark, increasedContrast: increased)
                let canvas = colors.resolvedNSColor(.canvas)
                let backgrounds: [(String, NSColor)] = [
                    ("canvas", canvas),
                    ("added", painted(colors.resolvedNSColor(.diffAdded), over: canvas)),
                    ("removed", painted(colors.resolvedNSColor(.diffRemoved), over: canvas)),
                    (
                        "added word highlight",
                        painted(
                            colors.resolvedNSColor(.positive).withAlphaComponent(0.24),
                            over: painted(colors.resolvedNSColor(.diffAdded), over: canvas))
                    ),
                    (
                        "removed word highlight",
                        painted(
                            colors.resolvedNSColor(.negative).withAlphaComponent(0.22),
                            over: painted(colors.resolvedNSColor(.diffRemoved), over: canvas))
                    ),
                    (
                        "unfocused selection",
                        resolve(.unemphasizedSelectedContentBackgroundColor, using: colors)
                    ),
                ]
                for role in [
                    ThemeColorRole.text, .secondaryText, .comment, .positive, .negative, .modified,
                    .keyword, .string, .number,
                ] {
                    // DiffCodeRow applies word backgrounds to text/syntax spans;
                    // line numbers and status labels sit on the row/base surface.
                    let syntax = [ThemeColorRole.text, .comment, .keyword, .string, .number].contains(role)
                    for (name, background) in backgrounds where syntax || !name.contains("word") {
                        let ratio = contrast(colors.resolvedNSColor(role), against: background)
                        try require(
                            ratio >= 4.5,
                            "Native \(dark ? "Dark" : "Light") increased=\(increased) \(role.rawValue)/\(name) contrast \(ratio) meets 4.5:1"
                        )
                    }
                }
                for (name, background) in backgrounds where !name.contains("word") {
                    let ratio = contrast(
                        resolve(NSColor(colors.accentText), using: colors), against: background)
                    try require(
                        ratio >= 4.5,
                        "Native accent text/\(name) contrast \(ratio) meets 4.5:1")
                }
                for (name, fill) in [
                    ("primary action", colors.primaryAction),
                    ("destructive action", colors.destructiveAction),
                    ("sidebar selection", colors.selectionBackground),
                ] {
                    let ratio = contrast(.white, against: resolve(NSColor(fill), using: colors))
                    try require(
                        ratio >= 4.5,
                        "Native \(dark ? "Dark" : "Light") increased=\(increased) white/\(name) contrast \(ratio) meets 4.5:1"
                    )
                }
                let badge = painted(
                    resolve(NSColor.white.withAlphaComponent(0.09), using: colors),
                    over: resolve(NSColor(colors.selectionBackground), using: colors))
                let badgeRatio = contrast(.white, against: badge)
                try require(
                    badgeRatio >= 4.5,
                    "Native selected sidebar count contrast \(badgeRatio) meets 4.5:1 over its translucent badge"
                )
                for (role, source) in [
                    (ThemeColorRole.positive, NSColor.systemGreen), (.negative, .systemRed),
                    (.modified, .systemOrange), (.keyword, .systemPurple), (.string, .systemBrown),
                    (.number, .linkColor),
                    (.accent, .controlAccentColor),
                ] {
                    let before = resolve(colors.syntaxPalette[role] ?? source, using: colors)
                    let after =
                        role == .accent
                        ? resolve(NSColor(colors.accentText), using: colors) : colors.resolvedNSColor(role)
                    var beforeHue: CGFloat = 0
                    var afterHue: CGFloat = 0
                    before.getHue(&beforeHue, saturation: nil, brightness: nil, alpha: nil)
                    after.getHue(&afterHue, saturation: nil, brightness: nil, alpha: nil)
                    let difference = abs(beforeHue - afterHue)
                    try require(
                        min(difference, 1 - difference) < 0.001,
                        "Native \(dark ? "Dark" : "Light") increased=\(increased) \(role.rawValue) keeps its source hue"
                    )
                }
            }
        }

        preferences.appearance = "dark"
        let beforePreview = defaults.persistentDomain(forName: suite)!
        preferences.previewCustomTheme(theme)
        try require(preferences.themeColors.custom == theme, "Preview uses the draft palette immediately")
        try require(
            NSDictionary(dictionary: beforePreview).isEqual(to: defaults.persistentDomain(forName: suite)!),
            "Preview does not persist or change the selected built-in theme")
        var partial = theme
        partial[.accent] = "#12"
        preferences.previewCustomTheme(partial)
        try require(
            preferences.themeColors.custom == theme,
            "Incomplete hex edits retain the last valid preview instead of flashing the built-in theme")
        preferences.previewCustomTheme(nil)
        try require(
            preferences.themeColors == nativeDark, "Cancel restores the exact original built-in palette")

        try preferences.applyCustomTheme(theme)
        try require(
            preferences.appearance == "custom" && preferences.themeColors.custom == theme,
            "Apply selects a separate Custom theme")
        let restored = AppPreferences(defaults: defaults)
        try require(
            restored.customTheme == theme && restored.themeColors.custom == theme,
            "Restart restores the selected custom theme and palette")
        restored.appearance = "light"
        try require(
            restored.themeColors == nativeLight && restored.customTheme == theme,
            "Switching to Light leaves its built-in colors and the saved custom scheme intact")
        restored.appearance = "dark"
        try require(restored.themeColors == nativeDark, "Switching to Dark leaves its built-in colors intact")
        var invalid = theme
        invalid[.canvas] = "bad"
        let beforeInvalid = defaults.persistentDomain(forName: suite)!
        do {
            try restored.applyCustomTheme(invalid)
            try require(false, "Invalid apply must fail")
        } catch {
            try require(
                NSDictionary(dictionary: beforeInvalid).isEqual(
                    to: defaults.persistentDomain(forName: suite)!),
                "Invalid application cannot partially save theme state")
        }
        restored.resetInterface()
        try require(
            restored.appearance == "system" && restored.customTheme == theme,
            "Interface reset restores System while preserving the saved custom scheme")

        var lightCustom = theme
        lightCustom.controls = .light
        lightCustom[.chrome] = "#F5E8D0"
        restored.previewCustomTheme(lightCustom)
        try require(
            restored.resolvedAppearance == "light" && !restored.themeColors.dark,
            "The custom control appearance drives the native presentation independently")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let probe = ThemeWindowProbe()
        probe.colors = restored.themeColors
        window.contentView?.addSubview(probe)
        probe.apply()
        try require(
            window.titlebarAppearsTransparent,
            "Native titlebar remains transparent over the themed window surface")
        try require(
            equal(window.backgroundColor, restored.themeColors.resolvedNSColor(.chrome)),
            "The native window uses the custom header color")
        probe.colors = nativeDark
        probe.apply()
        try require(
            equal(window.backgroundColor, nativeDark.resolvedNSColor(.chrome)),
            "Returning from custom restores the native dark window surface")
        let host = NSHostingView(
            rootView: Color.clear.frame(width: 400, height: 300).workbenchAppearance(restored))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try require(
            equal(window.backgroundColor, restored.themeColors.resolvedNSColor(.chrome)),
            "The shared SwiftUI presentation entry point installs preferences before rendering")
        restored.previewCustomTheme(nil)
        restored.appearance = "dark"
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try require(
            equal(window.backgroundColor, nativeDark.resolvedNSColor(.chrome)),
            "A mounted SwiftUI window returns from custom preview to built-in Dark")
        var unreadable = theme
        unreadable[.text] = unreadable[.canvas]
        try require(
            unreadable.contrastIssues.contains {
                $0.foreground == .text && $0.background == .canvas && $0.ratio == 1
            },
            "Unreadable user colors produce measured warnings without being repainted")
        defaults.set(Data("corrupt".utf8), forKey: "customTheme")
        let damaged = AppPreferences(defaults: defaults)
        try require(
            damaged.customThemeLoadFailed && damaged.customTheme == starter,
            "Corrupt saved themes recover to a safe editable starter")

        let report: [String: Any] = [
            "passed": true, "checks": checks, "starterContrastIssues": starter.contrastIssues.count,
            "nativeContrastMinimum": 4.5,
            "nativeContrastPairs": checks.filter { $0.hasPrefix("Native ") && $0.contains("contrast") }.count,
            "nativeHueChecks": checks.filter { $0.contains("keeps its source hue") }.count,
            "scope":
                "Custom colors/persistence/rollback, native surfaces, actual role/background contrast and source hue in four appearance variants",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("\(checks.count) theme behavior checks passed.")
    }
}
