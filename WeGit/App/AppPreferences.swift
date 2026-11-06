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
    private(set) var themeLibrary: CustomThemeLibrary
    var customThemes: [CustomThemeEntry] { themeLibrary.entries }
    var activeCustomThemeID: UUID? { themeLibrary.activeThemeID }
    var customTheme: CustomTheme { themeLibrary.activeTheme ?? .starter }
    private(set) var customThemeLoadFailed = false
    private(set) var themeLibraryLoadFailed = false
    @ObservationIgnored private var previewOwner: UUID?
    @ObservationIgnored private var previewSourceID: UUID?
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
        _ = try saveCustomTheme(theme, id: activeCustomThemeID, activate: true)
    }

    @discardableResult func previewCustomTheme(
        _ theme: CustomTheme?, owner: UUID? = nil, sourceID: UUID? = nil
    ) -> Bool {
        guard previewTheme == nil || previewOwner == owner else { return false }
        if let theme {
            if let valid = try? theme.validated() {
                previewOwner = owner
                previewSourceID = sourceID
                previewTheme = valid
            }
        } else {
            previewOwner = nil
            previewSourceID = nil
            previewTheme = nil
        }
        return true
    }

    @discardableResult func saveCustomTheme(
        _ theme: CustomTheme, id: UUID?, expected: CustomTheme? = nil, activate: Bool, owner: UUID? = nil
    ) throws -> UUID {
        guard !themeLibraryLoadFailed else { throw CustomThemeLibrary.Failure.invalid }
        guard !activate || previewTheme == nil || previewOwner == owner else {
            throw CustomThemeLibrary.Failure.previewInUse
        }
        let valid = try theme.validated()
        var library = themeLibrary
        let savedID: UUID
        if let id {
            guard let index = library.entries.firstIndex(where: { $0.id == id }),
                expected == nil || library.entries[index].theme == expected
            else { throw CustomThemeLibrary.Failure.changed }
            library.entries[index].theme = valid
            savedID = id
        } else {
            guard library.entries.count < CustomThemeLibrary.maximumEntries else {
                throw CustomThemeLibrary.Failure.full
            }
            let entry = CustomThemeEntry(theme: valid)
            library.entries.append(entry)
            savedID = entry.id
        }
        if activate {
            library.activeThemeID = savedID
            library.selectedAppearance = "custom"
        }
        try persistThemeLibrary(library)
        if activate {
            previewTheme = nil
            previewOwner = nil
            previewSourceID = nil
            appearance = "custom"
        }
        return savedID
    }

    func activateCustomTheme(_ id: UUID) throws {
        guard !themeLibraryLoadFailed, themeLibrary.entries.contains(where: { $0.id == id }) else {
            throw CustomThemeLibrary.Failure.changed
        }
        guard previewTheme == nil else { throw CustomThemeLibrary.Failure.previewInUse }
        var library = themeLibrary
        library.activeThemeID = id
        library.selectedAppearance = "custom"
        try persistThemeLibrary(library)
        appearance = "custom"
    }

    @discardableResult func importCustomTheme(_ theme: CustomTheme) throws -> UUID {
        let valid = try theme.validated()
        if let existing = customThemes.first(where: { $0.theme.contentDigest == valid.contentDigest }) {
            return existing.id
        }
        return try saveCustomTheme(valid, id: nil, activate: false)
    }

    @discardableResult func duplicateCustomTheme(_ id: UUID) throws -> UUID {
        guard let theme = customThemes.first(where: { $0.id == id })?.theme else {
            throw CustomThemeLibrary.Failure.changed
        }
        return try saveCustomTheme(theme, id: nil, activate: false)
    }

    func deleteCustomTheme(_ id: UUID) throws {
        guard !themeLibraryLoadFailed, customThemes.contains(where: { $0.id == id }) else {
            throw CustomThemeLibrary.Failure.changed
        }
        guard previewSourceID != id else { throw CustomThemeLibrary.Failure.previewInUse }
        var library = themeLibrary
        library.entries.removeAll { $0.id == id }
        let wasActive = library.activeThemeID == id
        if wasActive {
            library.activeThemeID = nil
            library.selectedAppearance = "system"
        }
        try persistThemeLibrary(library)
        if wasActive { appearance = "system" }
    }

    func restoreDeletedCustomTheme(_ entry: CustomThemeEntry) throws {
        guard !themeLibraryLoadFailed, !customThemes.contains(where: { $0.id == entry.id }) else {
            throw CustomThemeLibrary.Failure.changed
        }
        guard customThemes.count < CustomThemeLibrary.maximumEntries else {
            throw CustomThemeLibrary.Failure.full
        }
        var library = themeLibrary
        library.entries.append(entry)
        try persistThemeLibrary(library)
    }

    func rebuildThemeLibraryFromLegacy() throws {
        guard themeLibraryLoadFailed, let damaged = defaults.data(forKey: CustomThemeLibrary.key),
            damaged.count <= CustomThemeLibrary.maximumBytes
        else { throw CustomThemeLibrary.Failure.invalid }
        var library = CustomThemeLibrary()
        if let data = defaults.data(forKey: "customTheme"), let theme = try? CustomTheme.decode(data) {
            let entry = CustomThemeEntry(theme: theme)
            library.entries = [entry]
            library.activeThemeID = entry.id
        }
        library.selectedAppearance = "system"
        let valid = try library.validated()
        let encoded = try valid.encoded()
        defaults.set(damaged, forKey: "customThemes.recovery." + UUID().uuidString)
        defaults.set(encoded, forKey: CustomThemeLibrary.key)
        themeLibrary = valid
        themeLibraryLoadFailed = false
        customThemeLoadFailed = false
        appearance = "system"
    }

    private func persistThemeLibrary(_ library: CustomThemeLibrary) throws {
        let valid = try library.validated()
        let data = try valid.encoded()
        defaults.set(data, forKey: CustomThemeLibrary.key)
        themeLibrary = valid
        customThemeLoadFailed = false
        AppPresentation.updateDockIcon(for: resolvedAppearance)
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
            if !themeLibraryLoadFailed, ["system", "light", "dark", "custom"].contains(appearance),
                themeLibrary.selectedAppearance != appearance
            {
                var library = themeLibrary
                library.selectedAppearance = appearance
                try? persistThemeLibrary(library)
            }
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
        let storedLibrary = defaults.data(forKey: CustomThemeLibrary.key)
        let decodedLibrary = storedLibrary.flatMap { try? CustomThemeLibrary.decode($0) }
        var library = decodedLibrary ?? CustomThemeLibrary()
        if storedLibrary == nil, let decodedTheme {
            let entry = CustomThemeEntry(theme: decodedTheme)
            library.entries = [entry]
            library.activeThemeID = entry.id
            let legacyAppearance = defaults.string(forKey: "appearance") ?? "system"
            library.selectedAppearance =
                ["system", "light", "dark", "custom"].contains(legacyAppearance) ? legacyAppearance : "system"
            if let data = try? library.encoded() { defaults.set(data, forKey: CustomThemeLibrary.key) }
        }
        themeLibrary = library
        let libraryFailed = storedLibrary != nil && decodedLibrary == nil
        themeLibraryLoadFailed = libraryFailed
        customThemeLoadFailed =
            libraryFailed || (storedLibrary == nil && storedTheme != nil && decodedTheme == nil)
        language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        let selectedAppearance =
            decodedLibrary?.selectedAppearance ?? defaults.string(forKey: "appearance") ?? "system"
        appearance =
            ["system", "light", "dark", "custom"].contains(selectedAppearance) ? selectedAppearance : "system"
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
        previewOwner = nil
        previewSourceID = nil
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
