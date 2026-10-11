import Foundation
import Observation
import WeGitCore

@Observable @MainActor
final class AppPreferences {
    private let defaults: UserDefaults
    var configurationWriteInProgress = false
    var onDiffChange: (@MainActor () -> Void)?
    var onActivityChange: (@MainActor () -> Void)?
    var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
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
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        appearance =
            ["system", "light", "dark"].contains(defaults.string(forKey: "appearance") ?? "")
            ? defaults.string(forKey: "appearance")! : "system"
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
    }

    func resetInterface() {
        appearance = "system"
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
}
