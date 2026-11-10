import AppKit
import CryptoKit
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
        func level(_ color: NSColor) -> Double {
            let color = color.usingColorSpace(.sRGB)!
            let channels = [color.redComponent, color.greenComponent, color.blueComponent].map {
                let channel = Double($0)
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        func requireLadder(_ colors: AppColors, _ appearance: String) throws {
            let sidebar = level(colors.resolvedNSColor(.sidebar))
            let canvas = level(colors.resolvedNSColor(.canvas))
            try require(
                equal(colors.resolvedNSColor(.canvas), colors.resolvedNSColor(.surface))
                    && equal(colors.resolvedNSColor(.canvas), colors.resolvedNSColor(.chrome)),
                "Built-in \(appearance) central panes and headers share one surface")
            try require(
                sidebar < canvas && (colors.dark ? canvas < 0.05 : canvas > 0.85),
                "Built-in \(appearance) sidebars are recessed beside a clean paper or dark ink reading surface"
            )
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
                try requireLadder(colors, "dark=\(dark), increased=\(increased)")
                let canvas = colors.resolvedNSColor(.canvas)
                let expectedCanvas = ThemeRGB(hex: dark ? "#1F1F1F" : "#F7F3ED")!
                try require(
                    equal(
                        canvas,
                        NSColor(
                            srgbRed: expectedCanvas.red, green: expectedCanvas.green,
                            blue: expectedCanvas.blue, alpha: 1)),
                    "Built-in ink/ivory canvas uses the specified brand color")
                for tone in InterfaceTone.allCases {
                    let foreground = resolve(NSColor(colors.tone(tone)), using: colors)
                    for role in [ThemeColorRole.canvas, .sidebar] {
                        let background = painted(
                            foreground.withAlphaComponent(0.10), over: colors.resolvedNSColor(role))
                        let ratio = contrast(foreground, against: background)
                        try require(
                            ratio >= 4.5,
                            "Categorical \(tone) badge on \(role) dark=\(dark) increased=\(increased) contrast \(ratio) meets 4.5:1"
                        )
                    }
                }
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
                    resolve(NSColor.white.withAlphaComponent(0.10), using: colors),
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
                    (.accent, NSColor(colors.brand)),
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
        let legacySuite = suite + ".Legacy"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set(Data("corrupt".utf8), forKey: "customTheme")
        let damaged = AppPreferences(defaults: legacyDefaults)
        try require(
            damaged.customThemeLoadFailed && damaged.customTheme == starter,
            "Corrupt saved themes recover to a safe editable starter")
        try require(
            legacyDefaults.data(forKey: "customTheme") == Data("corrupt".utf8),
            "Corrupt legacy bytes are retained")

        let librarySuite = suite + ".Library"
        let libraryDefaults = UserDefaults(suiteName: librarySuite)!
        defer { libraryDefaults.removePersistentDomain(forName: librarySuite) }
        libraryDefaults.set(try theme.encoded(), forKey: "customTheme")
        libraryDefaults.set("custom", forKey: "appearance")
        let migrated = AppPreferences(defaults: libraryDefaults)
        let migratedID = migrated.activeCustomThemeID!
        try require(
            migrated.customThemes.count == 1 && migrated.customTheme == theme
                && migrated.appearance == "custom", "Legacy custom theme migrates all colors and selection")
        try require(
            AppPreferences(defaults: libraryDefaults).activeCustomThemeID == migratedID,
            "Migration ID remains stable across initialization")
        let duplicate = try migrated.duplicateCustomTheme(migratedID)
        try require(
            duplicate != migratedID && migrated.customThemes.count == 2
                && migrated.customThemes.allSatisfy { $0.theme.name == theme.name },
            "Same-name themes retain independent IDs")
        var changed = theme
        changed.name = "Edited copy"
        changed[.accent] = "#268AE5"
        _ = try migrated.saveCustomTheme(changed, id: duplicate, expected: theme, activate: false)
        try require(
            migrated.customTheme == theme
                && migrated.customThemes.first { $0.id == duplicate }?.theme == changed,
            "Editing a copy cannot overwrite the active original")
        do {
            _ = try migrated.saveCustomTheme(theme, id: duplicate, expected: theme, activate: false)
            try require(false, "Stale editor must fail")
        } catch CustomThemeLibrary.Failure.changed { checks.append("Stale editor is rejected") }
        try migrated.activateCustomTheme(duplicate)
        try require(
            AppPreferences(defaults: libraryDefaults).customTheme == changed,
            "Activation persists exact edited colors")
        let owner = UUID()
        let other = UUID()
        try require(
            migrated.previewCustomTheme(theme, owner: owner, sourceID: duplicate), "Editor acquires a preview"
        )
        try require(
            !migrated.previewCustomTheme(changed, owner: other)
                && !migrated.previewCustomTheme(nil, owner: other),
            "Other windows cannot replace or cancel an owned preview")
        _ = migrated.previewCustomTheme(nil, owner: owner)
        try require(
            migrated.customTheme == changed && migrated.themeColors.custom == changed,
            "Preview cancellation restores the active selection")
        let deleted = migrated.customThemes.first { $0.id == duplicate }!
        try migrated.deleteCustomTheme(duplicate)
        try require(
            migrated.appearance == "system" && migrated.customThemes.count == 1,
            "Deleting active theme falls back explicitly to System")
        try migrated.restoreDeletedCustomTheme(deleted)
        try require(
            migrated.customThemes.contains { $0.id == duplicate }, "Deletion undo preserves the stable ID")
        let duplicateImport = try migrated.importCustomTheme(changed)
        try require(
            duplicateImport == duplicate && migrated.customThemes.count == 2,
            "Repeated same-content import does not add another theme")

        let uriData = try changed.normalizedData()
        let checksum = CryptoKit.SHA256.hash(data: uriData).map { String(format: "%02x", $0) }.joined()
        let encoded = uriData.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let uri = URL(string: "wegit://theme/import?v=1&data=" + encoded + "&sha256=" + checksum)!
        try require(
            try ThemeImportPayload.parse(uri).theme == changed, "URI imports the exact edited snapshot")
        for value in [
            uri.absoluteString + "&v=1", uri.absoluteString + "#fragment",
            uri.absoluteString.replacingOccurrences(of: "theme/import", with: "command/run"),
            uri.absoluteString.replacingOccurrences(of: checksum, with: String(repeating: "0", count: 64)),
        ] {
            var rejected = false
            do { _ = try ThemeImportPayload.parse(URL(string: value)!) } catch { rejected = true }
            try require(rejected, "Malformed, unsupported or mismatched URI rejected")
        }
        let originalLibrary = libraryDefaults.data(forKey: CustomThemeLibrary.key)!
        libraryDefaults.set(Data("corrupt library".utf8), forKey: CustomThemeLibrary.key)
        let corruptLibrary = AppPreferences(defaults: libraryDefaults)
        try require(
            corruptLibrary.themeLibraryLoadFailed, "Damaged library is identified without overriding it")
        do {
            _ = try corruptLibrary.importCustomTheme(theme)
            try require(false, "Corrupt library must not be overwritten")
        } catch CustomThemeLibrary.Failure.invalid {
            checks.append("Corrupt library blocks implicit replacement")
        }
        try corruptLibrary.rebuildThemeLibraryFromLegacy()
        try require(
            libraryDefaults.dictionaryRepresentation().keys.contains {
                $0.hasPrefix("customThemes.recovery.")
            }, "Explicit recovery retains original damaged bytes separately")
        libraryDefaults.set(originalLibrary, forKey: CustomThemeLibrary.key)

        let libraryReport = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(
            path: ".build/ci/theme-library-performance.json")
        try FileManager.default.createDirectory(
            at: libraryReport.deletingLastPathComponent(), withIntermediateDirectories: true)
        var libraryWorkloads: [[String: Any]] = []
        var uriWorkloads: [[String: Any]] = []
        var migrationSamples: [[String: Any]] = []
        var activeSamples: [[String: Any]] = []
        var activeWorkload = "library"
        var activeCount = 0
        let clock = ContinuousClock()
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        func p95(_ samples: [[String: Any]], _ key: String) -> Double {
            samples.map { $0[key] as! Double }.sorted()[28]
        }
        func savePerformance(passed: Bool = false, failure: String? = nil) throws {
            var report: [String: Any] = [
                "format": 1, "requiredSerialSamples": 30, "allPassed": passed,
                "workloads": libraryWorkloads, "uriWorkloads": uriWorkloads,
                "migrationSamples": migrationSamples, "activeWorkload": activeWorkload,
                "activeCount": activeCount, "activeSamples": activeSamples,
                "budgets": [
                    "loadMilliseconds": 100, "activateMilliseconds": 50,
                    "uriParseMilliseconds": 50, "legacyMigrationMilliseconds": 100,
                ],
                "scope":
                    "Optimized standalone preferences helper; fresh legacy domain per migration, filesystem/defaults caches uncontrolled. Not full application startup, cold process launch or UI acceptance.",
                "applicationStartupMeasured": false,
            ]
            if migrationSamples.count == 30 {
                report["p95MigrationMilliseconds"] = p95(migrationSamples, "migrationMilliseconds")
            }
            if let failure { report["failure"] = failure }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: libraryReport, options: .atomic)
        }
        func exactTheme(_ actual: CustomTheme, _ expected: CustomTheme) -> Bool {
            ThemeColorRole.allCases.count == 17 && actual.name == expected.name
                && actual.controls == expected.controls
                && ThemeColorRole.allCases.allSatisfy { actual[$0] == expected[$0] }
        }
        func payload(bytes: Int) throws -> Data {
            let original = try changed.normalizedData()
            try require(original.count <= bytes, "Fixed URI content fits the boundary fixture")
            // JSON trailing whitespace changes transport size, not the theme's
            // allowed fields, normalized content or content identity.
            return original + Data(repeating: 32, count: bytes - original.count)
        }
        func themeURI(_ data: Data, bytes: Int? = nil) throws -> URL {
            let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let prefix = "wegit://theme/import?v=1&data="
            let suffix = "&sha256=" + digest
            let originalSize = prefix.utf8.count + encoded.utf8.count + suffix.utf8.count
            let extra = (bytes ?? originalSize) - originalSize
            try require(
                extra >= 0 && extra % 2 == 0 && extra / 2 <= encoded.utf8.count,
                "Exact URI boundary can be formed without adding fields")
            // Percent-encoding legal base64url bytes pads the transport while
            // URLComponents still decodes the same canonical payload.
            let padded = encoded.utf8.enumerated().map { index, byte in
                index < extra / 2 ? String(format: "%%%02X", byte) : String(UnicodeScalar(byte))
            }.joined()
            let url = URL(string: prefix + padded + suffix)!
            try require(
                url.absoluteString.utf8.count == bytes ?? originalSize,
                "URI fixture has its exact declared transport size")
            return url
        }
        do {
            try savePerformance()
            for count in [1, 10, 100] {
                activeWorkload = "library"
                activeCount = count
                activeSamples = []
                var library = CustomThemeLibrary()
                library.entries = (0..<count).map { index in
                    var value = theme
                    value.name = "Theme \(index)"
                    return CustomThemeEntry(theme: value)
                }
                library.activeThemeID = library.entries[0].id
                library.selectedAppearance = "custom"
                let data = try library.encoded()
                for iteration in 0..<30 {
                    libraryDefaults.set(data, forKey: CustomThemeLibrary.key)
                    var start = clock.now
                    let loaded = AppPreferences(defaults: libraryDefaults)
                    let load = milliseconds(start.duration(to: clock.now))
                    let expectedEntry = library.entries[iteration % count]
                    start = clock.now
                    try loaded.activateCustomTheme(expectedEntry.id)
                    let activate = milliseconds(start.duration(to: clock.now))
                    let valid =
                        loaded.customThemes.map(\.id) == library.entries.map(\.id)
                        && loaded.activeCustomThemeID == expectedEntry.id && loaded.appearance == "custom"
                        && exactTheme(loaded.customTheme, expectedEntry.theme)
                    activeSamples.append([
                        "iteration": iteration + 1, "loadMilliseconds": load,
                        "activateMilliseconds": activate,
                        "selectedID": expectedEntry.id.uuidString, "identityAndColorsVerified": valid,
                    ])
                    try savePerformance()
                    try require(valid, "Library sample preserves all IDs, selected theme and 17 colors")
                }
                let p95Load = p95(activeSamples, "loadMilliseconds")
                let p95Activate = p95(activeSamples, "activateMilliseconds")
                let passed = p95Load < 100 && p95Activate < 50
                libraryWorkloads.append([
                    "count": count, "samples": activeSamples, "p95Load": p95Load,
                    "p95Activate": p95Activate, "passed": passed,
                ])
                try savePerformance()
                try require(passed, "Library load/activation keeps the frozen 100/50 ms budgets")
            }
            try require(
                ThemeImportPayload.maximumPayloadBytes == 8192
                    && ThemeImportPayload.maximumURIBytes == 16384,
                "URI limits retain the frozen 8/16 KiB contract")
            let uriFixtures: [(name: String, data: Data, uriBytes: Int?, accepted: Bool)] = [
                ("payload-limit", try payload(bytes: 8192), nil, true),
                ("uri-limit", try payload(bytes: 8191), 16384, true),
                ("payload-over-limit", try payload(bytes: 8193), nil, false),
                ("uri-over-limit", try payload(bytes: 8192), 16385, false),
            ]
            for fixture in uriFixtures {
                let url = try themeURI(fixture.data, bytes: fixture.uriBytes)
                activeWorkload = fixture.name
                activeCount = fixture.data.count
                activeSamples = []
                for iteration in 1...30 {
                    let start = clock.now
                    let result = Result { try ThemeImportPayload.parse(url) }
                    let elapsed = milliseconds(start.duration(to: clock.now))
                    let valid: Bool
                    switch result {
                    case .success(let value):
                        valid =
                            fixture.accepted && exactTheme(value.theme, changed)
                            && value.id == changed.contentDigest
                    case .failure(let error):
                        valid = !fixture.accepted && error is ThemeImportPayload.Failure
                    }
                    activeSamples.append([
                        "iteration": iteration, "parseMilliseconds": elapsed,
                        "expectedOutcomeVerified": valid,
                    ])
                    try savePerformance()
                    try require(
                        valid, "URI sample preserves 17 colors/identity or rejects the exact oversized input")
                }
                let percentile = p95(activeSamples, "parseMilliseconds")
                uriWorkloads.append([
                    "name": fixture.name, "payloadBytes": fixture.data.count,
                    "uriBytes": url.absoluteString.utf8.count, "expectedAccepted": fixture.accepted,
                    "payloadSHA256": SHA256.hash(data: fixture.data).map { String(format: "%02x", $0) }
                        .joined(),
                    "samples": activeSamples, "p95ParseMilliseconds": percentile, "passed": percentile < 50,
                ])
                try savePerformance()
                try require(percentile < 50, "URI parsing keeps the frozen 50 ms budget")
            }
            activeWorkload = "legacy-migration"
            activeCount = 1
            activeSamples = []
            let legacyBytes = try changed.encoded()
            for iteration in 1...30 {
                let domain = suite + ".Migration.\(iteration)"
                let privateDefaults = UserDefaults(suiteName: domain)!
                defer { privateDefaults.removePersistentDomain(forName: domain) }
                let appearance = ["custom", "system", "light", "dark"][(iteration - 1) % 4]
                privateDefaults.set(legacyBytes, forKey: "customTheme")
                privateDefaults.set(appearance, forKey: "appearance")
                try require(
                    privateDefaults.data(forKey: CustomThemeLibrary.key) == nil,
                    "Migration sample starts without a versioned theme library")
                let start = clock.now
                let value = AppPreferences(defaults: privateDefaults)
                let elapsed = milliseconds(start.duration(to: clock.now))
                let entry = value.customThemes.first
                let reopened = AppPreferences(defaults: privateDefaults)
                let valid =
                    value.customThemes.count == 1 && value.activeCustomThemeID == entry?.id
                    && exactTheme(value.customTheme, changed) && value.appearance == appearance
                    && value.themeLibrary.selectedAppearance == appearance
                    && reopened.activeCustomThemeID == entry?.id && reopened.customThemes.count == 1
                    && exactTheme(reopened.customTheme, changed) && reopened.appearance == appearance
                    && privateDefaults.data(forKey: "customTheme") == legacyBytes
                    && !value.themeLibraryLoadFailed && !value.customThemeLoadFailed
                migrationSamples.append([
                    "iteration": iteration, "migrationMilliseconds": elapsed, "appearance": appearance,
                    "migratedID": entry?.id.uuidString ?? "", "identityAndColorsVerified": valid,
                ])
                try savePerformance()
                try require(
                    valid, "Legacy migration preserves 17 colors, original bytes, selection and stable ID")
            }
            try require(
                p95(migrationSamples, "migrationMilliseconds") < 100,
                "Legacy migration keeps the frozen 100 ms budget")
            activeWorkload = "complete"
            activeSamples = []
            try savePerformance(passed: true)
        } catch {
            try savePerformance(failure: String(describing: error))
            throw error
        }

        // Exercise the same decoder, contrast checks and persistence used by the theme editor.
        let websiteThemes = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "site/public/themes", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: websiteThemes.path) {
            let files = try FileManager.default.contentsOfDirectory(
                at: websiteThemes, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            try require(!files.isEmpty, "Website theme collection is not empty")
            for file in files {
                let imported = try CustomTheme.decode(Data(contentsOf: file))
                try require(
                    imported.contrastIssues.isEmpty,
                    "Website \(imported.name) has no client contrast warnings")
                try require(
                    try CustomTheme.decode(imported.encoded()) == imported,
                    "Website \(imported.name) imports and exports without losing colors")
                try preferences.applyCustomTheme(imported)
                let saved = AppPreferences(defaults: defaults)
                try require(
                    saved.customTheme == imported && saved.appearance == "custom",
                    "Website \(imported.name) applies and restores all colors from private preferences")
            }
        }

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
