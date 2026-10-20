import AppKit
import Foundation
import Observation
import WeGitCore

@Observable @MainActor
final class AppPreferences {
    private let defaults: UserDefaults
    @ObservationIgnored private var systemAppearanceObservation: NSKeyValueObservation?
    private(set) var systemUsesDarkAppearance = false
    var configurationWriteInProgress = false
    var onDiffChange: (@MainActor () -> Void)?
    var onActivityChange: (@MainActor () -> Void)?
    private(set) var customTheme: CustomTheme {
        didSet {
            if let data = try? customTheme.encoded() { defaults.set(data, forKey: "customTheme") }
            customThemeLoadFailed = false
            AppPresentation.updateDockIcon(for: resolvedAppearance)
        }
    }
    private(set) var customThemeLoadFailed = false
    private(set) var previewTheme: CustomTheme? {
        didSet { AppPresentation.updateDockIcon(for: resolvedAppearance) }
    }

    var resolvedAppearance: String {
        if let previewTheme { return previewTheme.controls.rawValue }
        return appearance == "custom" ? customTheme.controls.rawValue : appearance
    }

    var themeColors: AppColors {
        AppColors(
            custom: previewTheme ?? (appearance == "custom" ? customTheme : nil),
            dark: resolvedAppearance == "dark" || (resolvedAppearance == "system" && systemUsesDarkAppearance)
        )
    }

    func applyCustomTheme(_ theme: CustomTheme) throws {
        customTheme = try theme.validated()
        previewTheme = nil
        appearance = "custom"
    }

    func previewCustomTheme(_ theme: CustomTheme?) {
        if let theme {
            if let valid = try? theme.validated() { previewTheme = valid }
        } else {
            previewTheme = nil
        }
    }
    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: "language")
            if language == .system {
                defaults.removeObject(forKey: "AppleLanguages")
                let preferred =
                    UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[
                        "AppleLanguages"] as? [String] ?? Locale.preferredLanguages
                L10n.language = language.resolved(preferredLanguages: preferred)
            } else {
                defaults.set([language.rawValue], forKey: "AppleLanguages")
                L10n.language = language
            }
        }
    }
    var appearance: String {
        didSet {
            defaults.set(appearance, forKey: "appearance")
            AppPresentation.updateDockIcon(for: resolvedAppearance)
        }
    }
    var interfaceMotion: Bool { didSet { defaults.set(interfaceMotion, forKey: "interfaceMotion") } }
    var showMenuBar: Bool { didSet { defaults.set(showMenuBar, forKey: "showMenuBar") } }
    var codeSize: Double { didSet { defaults.set(codeSize, forKey: "codeSize") } }
    var codeFont: String { didSet { defaults.set(codeFont, forKey: "codeFont") } }
    var density: String { didSet { defaults.set(density, forKey: "density") } }
    var showFileIcons: Bool { didSet { defaults.set(showFileIcons, forKey: "showFileIcons") } }
    var defaultDirectory: String { didSet { defaults.set(defaultDirectory, forKey: "defaultDirectory") } }
    var restoreRepository: Bool { didSet { defaults.set(restoreRepository, forKey: "restoreRepository") } }
    var restoreWindow: Bool { didSet { defaults.set(restoreWindow, forKey: "restoreWindow") } }
    var confirmRepositorySwitch: Bool {
        didSet { defaults.set(confirmRepositorySwitch, forKey: "confirmRepositorySwitch") }
    }
    var saveDrafts: Bool { didSet { defaults.set(saveDrafts, forKey: "saveDrafts") } }
    var splitDiff: Bool {
        didSet {
            defaults.set(splitDiff, forKey: "defaultSplitDiff")
            onDiffChange?()
        }
    }
    var ignoreWhitespace: Bool {
        didSet {
            defaults.set(ignoreWhitespace, forKey: "defaultIgnoreWhitespace")
            onDiffChange?()
        }
    }
    var contextLines: Int {
        didSet {
            defaults.set(contextLines, forKey: "defaultContextLines")
            onDiffChange?()
        }
    }
    var wordDiff: Bool {
        didSet {
            defaults.set(wordDiff, forKey: "defaultWordDiff")
            onDiffChange?()
        }
    }
    var showLineNumbers: Bool { didSet { defaults.set(showLineNumbers, forKey: "showLineNumbers") } }
    var showWhitespace: Bool { didSet { defaults.set(showWhitespace, forKey: "showWhitespace") } }
    var activityLimit: Int {
        didSet {
            defaults.set(activityLimit, forKey: "activityLimit")
            onActivityChange?()
        }
    }
    var activityHours: Int {
        didSet {
            defaults.set(activityHours, forKey: "activityHours")
            onActivityChange?()
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let storedTheme = defaults.data(forKey: "customTheme")
        let decodedTheme = storedTheme.flatMap { try? CustomTheme.decode($0) }
        customTheme = decodedTheme ?? .starter
        customThemeLoadFailed = storedTheme != nil && decodedTheme == nil
        language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        appearance =
            ["system", "light", "dark", "custom"].contains(defaults.string(forKey: "appearance") ?? "")
            ? defaults.string(forKey: "appearance")! : "system"
        interfaceMotion = flag("interfaceMotion", true)
        showMenuBar = flag("showMenuBar", true)
        codeSize = min(
            24, max(11, defaults.object(forKey: "codeSize") == nil ? 13 : defaults.double(forKey: "codeSize"))
        )
        codeFont =
            ["system", "Menlo", "Monaco"].contains(defaults.string(forKey: "codeFont") ?? "")
            ? defaults.string(forKey: "codeFont")! : "system"
        density = defaults.string(forKey: "density") == "compact" ? "compact" : "comfortable"
        showFileIcons = flag("showFileIcons", true)
        defaultDirectory =
            defaults.string(forKey: "defaultDirectory")
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        restoreRepository = flag("restoreRepository", true)
        restoreWindow = flag("restoreWindow", true)
        confirmRepositorySwitch = flag("confirmRepositorySwitch", false)
        saveDrafts = flag("saveDrafts", true)
        splitDiff = flag("defaultSplitDiff", false)
        ignoreWhitespace = flag("defaultIgnoreWhitespace", false)
        let context = defaults.integer(forKey: "defaultContextLines")
        contextLines = [3, 20, 80, 200].contains(context) ? context : 3
        wordDiff = flag("defaultWordDiff", false)
        showLineNumbers = flag("showLineNumbers", true)
        showWhitespace = flag("showWhitespace", false)
        let limit = defaults.integer(forKey: "activityLimit")
        activityLimit = [100, 500, 1000].contains(limit) ? limit : 100
        let hours = defaults.integer(forKey: "activityHours")
        activityHours = [1, 24, 168].contains(hours) ? hours : 24
        L10n.language = language
        if language != .system { defaults.set([language.rawValue], forKey: "AppleLanguages") }
    }

    /// Observe the unmodified application appearance, not an already themed window.
    /// The status item also inherits this system appearance; windows set their own preference.
    func observeSystemAppearance() {
        guard systemAppearanceObservation == nil else { return }
        updateSystemAppearance()
        systemAppearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) {
            [weak self] _, _ in
            Task { @MainActor [weak self] in self?.updateSystemAppearance() }
        }
    }

    private func updateSystemAppearance() {
        systemUsesDarkAppearance =
            NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        AppPresentation.updateDockIcon(for: resolvedAppearance)
    }

    func resetInterface() {
        previewTheme = nil
        appearance = "system"
        interfaceMotion = true
        showMenuBar = true
        codeSize = 13
        codeFont = "system"
        density = "comfortable"
        showFileIcons = true
        splitDiff = false
        ignoreWhitespace = false
        contextLines = 3
        wordDiff = false
        showLineNumbers = true
        showWhitespace = false
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("workspace:") {
            defaults.removeObject(forKey: key)
        }
    }
}

struct PendingPushRecord: Codable {
    let commit: String
    let localBranch: String
    let remote: String
    let branch: String
    let pushIndex: Int
    var verification: PushReceipt? = nil
}

struct RepositoryViewPreferences: Codable, Equatable {
    let route: String
    let selectedFile: String?
    let inspector: Bool
    let filter: String
    let branchFilter: String
    let splitDiff: Bool
    let wordDiff: Bool
    let contextLines: Int
    let ignoreWhitespace: Bool
    let changeFilter: String?
    let changesByFolder: Bool?
}
