import AppKit

/// Native panels sit outside SwiftUI's preferredColorScheme environment.
@MainActor
enum AppPresentation {
    private static let appearanceIcons: [String: NSImage] = {
        var images: [String: NSImage] = [:]
        for name in ["WeGitLight", "WeGitDark"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "icns"),
                let image = NSImage(contentsOf: url)
            {
                images[name] = image
            }
        }
        return images
    }()
    private static var appliedDockIcon: String?

    static func appearance(for preference: String) -> NSAppearance {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        switch preference {
        case "light":
            return NSAppearance(named: contrast ? .accessibilityHighContrastAqua : .aqua)!
        case "dark":
            return NSAppearance(named: contrast ? .accessibilityHighContrastDarkAqua : .darkAqua)!
        default:
            return NSApp.effectiveAppearance
        }
    }

    private static func iconName(for appearance: NSAppearance) -> String {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "WeGitDark" : "WeGitLight"
    }

    /// Dock icon style is otherwise independent of the application's content theme.
    static func updateDockIcon(for preference: String) {
        guard let application = NSApp else { return }
        let name = iconName(for: appearance(for: preference))
        guard name != appliedDockIcon else { return }
        application.applicationIconImage = appearanceIcons[name]
        appliedDockIcon = appearanceIcons[name] == nil ? nil : name
    }

    static func configure(_ alert: NSAlert, appearance: NSAppearance) {
        alert.window.appearance = appearance
        // Loading from the bundle also works for direct Debug launches, before
        // Launch Services has registered an application icon for this build.
        let bundle = Bundle.main
        let name = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String ?? "AppIcon"
        let file = bundle.url(forResource: name, withExtension: "icns")
        alert.icon =
            appearanceIcons[iconName(for: appearance)]
            ?? bundle.image(forResource: NSImage.Name(name))
            ?? file.flatMap { NSImage(contentsOf: $0) }
            ?? NSApp.applicationIconImage
    }
}
