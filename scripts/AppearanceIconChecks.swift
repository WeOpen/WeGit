import AppKit
import Foundation

@main
struct AppearanceIconChecks {
    @MainActor
    static func main() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let originalAppearance = application.appearance
        let suite = "com.willxue.wegit.AppearanceChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let report = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks: [String] = []
        var samples: [[String: Any]] = []
        defer {
            application.appearance = originalAppearance
            application.applicationIconImage = nil
            defaults.removePersistentDomain(forName: suite)
            defaults.synchronize()
        }

        func record(_ passed: Bool, _ name: String) throws {
            guard passed else {
                let result: [String: Any] = [
                    "passed": false, "failedCheck": name, "checks": checks, "samples": samples,
                ]
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: report)
                throw NSError(
                    domain: "WeGit.AppearanceChecks", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: name])
            }
            checks.append(name)
        }

        func isDark(_ image: NSImage?, label: String) throws -> Bool {
            guard let image,
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                let color = NSBitmapImageRep(cgImage: cgImage)
                    .colorAt(x: cgImage.width * 16 / 100, y: cgImage.height / 2)?
                    .usingColorSpace(.sRGB)
            else { throw NSError(domain: "WeGit.AppearanceChecks", code: 2) }
            let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
            samples.append(["label": label, "rgb": rgb])
            return max(color.redComponent, color.greenComponent, color.blueComponent) < 0.45
        }

        func waitForSystem(_ preferences: AppPreferences, dark: Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while preferences.systemUsesDarkAppearance != dark && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try record(
                preferences.systemUsesDarkAppearance == dark,
                "System appearance observation reaches " + (dark ? "Dark" : "Light"))
        }

        func checkDockCanvas(_ image: NSImage?, label: String) throws {
            let cgImage = image!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let width = bitmap.pixelsWide
            let height = bitmap.pixelsHigh
            let xs = (0..<width).filter {
                bitmap.colorAt(x: $0, y: height / 2)!.alphaComponent > 0.5
            }
            let ys = (0..<height).filter {
                bitmap.colorAt(x: width / 2, y: $0)!.alphaComponent > 0.5
            }
            let horizontal = Double(xs.last! - xs.first! + 1) / Double(width)
            let vertical = Double(ys.last! - ys.first! + 1) / Double(height)
            // Use a real system app as the scale reference, rendered on the same canvas.
            let finder = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
            let reference = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: reference)
            finder.draw(
                in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy,
                fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let referenceX = (0..<width).filter {
                reference.colorAt(x: $0, y: height / 2)!.alphaComponent > 0.5
            }
            let referenceY = (0..<height).filter {
                reference.colorAt(x: width / 2, y: $0)!.alphaComponent > 0.5
            }
            let targetX = Double(referenceX.last! - referenceX.first! + 1) / Double(width)
            let targetY = Double(referenceY.last! - referenceY.first! + 1) / Double(height)
            samples.append([
                "label": label + "-canvas", "horizontalExtent": horizontal, "verticalExtent": vertical,
                "finderHorizontalExtent": targetX, "finderVerticalExtent": targetY,
            ])
            try record(
                abs(horizontal - targetX) <= 2 / Double(width)
                    && abs(vertical - targetY) <= 2 / Double(height),
                label + " Dock artwork matches Finder within two pixels")
            try record(
                abs(xs.first! + xs.last! - referenceX.first! - referenceX.last!) <= 2
                    && abs(ys.first! + ys.last! - referenceY.first! - referenceY.last!) <= 2,
                label + " Dock artwork shares Finder's visual center")
        }

        func checkSealRepresentations(_ name: String, dark: Bool) throws {
            let image = NSImage(contentsOf: Bundle.main.url(forResource: name, withExtension: "icns")!)!
            let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
            try record(
                Set(bitmaps.map(\.pixelsWide)).isSuperset(of: [16, 32, 64, 128, 256, 512, 1024]),
                name + " contains every required native pixel size")
            for (index, bitmap) in bitmaps.enumerated() {
                let width = bitmap.pixelsWide
                let height = bitmap.pixelsHigh
                var maximumGreen: CGFloat = 0
                var darkInkPixels = 0
                // This region is inside the red face, contains the Ku impression,
                // and excludes the Git branch and the surrounding ivory/ink tile.
                for y in Int(CGFloat(height) * 0.657)..<Int(CGFloat(height) * 0.76) {
                    for x in Int(CGFloat(width) * 0.615)..<Int(CGFloat(width) * 0.73) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                            color.alphaComponent > 0.8
                        else { continue }
                        maximumGreen = max(maximumGreen, color.greenComponent)
                        let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
                        if rgb.max()! < 0.4 && rgb.max()! - rgb.min()! < 0.1 { darkInkPixels += 1 }
                    }
                }
                samples.append([
                    "label": name + "-seal-\(width)-rep-\(index)",
                    "maximumGreen": maximumGreen, "darkInkPixels": darkInkPixels,
                ])
                try record(
                    dark ? maximumGreen < 0.45 && (width < 128 || darkInkPixels > 3) : maximumGreen > 0.5,
                    name + " \(width)px representation \(index) keeps the " + (dark ? "black" : "white")
                        + " Ku impression")
            }
        }

        do {
            application.appearance = NSAppearance(named: .aqua)
            application.applicationIconImage = NSImage(
                contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "icns")!)
            defaults.set("dark", forKey: "appearance")
            let preferences = AppPreferences(defaults: defaults)
            preferences.observeSystemAppearance()
            try record(
                try isDark(application.applicationIconImage, label: "restored-dark"),
                "Restored Dark selects the ink Dock icon")
            try checkDockCanvas(application.applicationIconImage, label: "Dark")
            try checkSealRepresentations("WeGitDark", dark: true)

            preferences.appearance = "light"
            try record(
                try !isDark(application.applicationIconImage, label: "explicit-light"),
                "Light switches the running Dock icon to ivory")
            try checkDockCanvas(application.applicationIconImage, label: "Light")
            try checkSealRepresentations("WeGitLight", dark: false)
            preferences.appearance = "dark"
            try record(
                try isDark(application.applicationIconImage, label: "explicit-dark"),
                "Dark switches the running Dock icon without rebuilding a window")
            try record(application.windows.isEmpty, "Theme updates work with no application windows")

            let darkAlert = NSAlert()
            AppPresentation.configure(darkAlert, appearance: AppPresentation.appearance(for: "dark"))
            try record(
                try isDark(darkAlert.icon, label: "dark-alert"),
                "Dark native panels use the same ink artwork")
            let lightAlert = NSAlert()
            AppPresentation.configure(lightAlert, appearance: AppPresentation.appearance(for: "light"))
            try record(
                try !isDark(lightAlert.icon, label: "light-alert"),
                "Light native panels use the ivory artwork")

            preferences.appearance = "system"
            try record(
                try !isDark(application.applicationIconImage, label: "system-light"),
                "Returning to System follows the current Light appearance")
            application.appearance = NSAppearance(named: .darkAqua)
            try await waitForSystem(preferences, dark: true)
            try record(
                try isDark(application.applicationIconImage, label: "system-dark"),
                "System Dark updates the Dock icon through the existing observer")
            application.appearance = NSAppearance(named: .aqua)
            try await waitForSystem(preferences, dark: false)
            try record(
                try !isDark(application.applicationIconImage, label: "system-light-again"),
                "System Light restores ivory in the same process")

            preferences.appearance = "dark"
            try record(
                try isDark(application.applicationIconImage, label: "dark-over-light-system"),
                "Explicit Dark wins over a Light system appearance")
            application.appearance = NSAppearance(named: .darkAqua)
            try await waitForSystem(preferences, dark: true)
            preferences.appearance = "light"
            try record(
                try !isDark(application.applicationIconImage, label: "light-over-dark-system"),
                "Explicit Light wins over a Dark system appearance")
            preferences.resetInterface()
            try record(preferences.appearance == "system", "Reset returns the icon policy to System")
            try record(
                try isDark(application.applicationIconImage, label: "reset-to-system-dark"),
                "Reset immediately selects the current system artwork")

            let result: [String: Any] = [
                "passed": true, "checks": checks, "samples": samples,
                "scope":
                    "Actual AppKit applicationIconImage pixels and preference lifecycle; system appearance changes are process-local",
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: report)
            print("\(checks.count) native appearance icon checks passed.")
        } catch {
            fputs("Appearance icon check failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
