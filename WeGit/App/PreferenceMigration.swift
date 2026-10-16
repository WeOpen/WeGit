import Foundation

/// Changing the bundle identifier must not discard settings, drafts or window state.
enum PreferenceMigration {
    static let completionKey = "bundleNamespaceMigration.v1"

    static func legacyDomains(for identifier: String) -> [String] {
        switch identifier {
        case "com.willxue.wegit.development": ["org.weopen.WeGit.development"]
        case "com.willxue.wegit": ["com.willxue.WeGit", "org.weopen.WeGit"]
        default: []
        }
    }

    static func migrateStandardPreferences() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let legacy = legacyDomains(for: identifier)
        guard !legacy.isEmpty else { return }
        migrate(defaults: .standard, target: identifier, legacy: legacy)
    }

    /// Existing destination values win. The marker also prevents deleted settings
    /// from being copied back from an old installation on a later launch.
    @discardableResult
    static func migrate(defaults: UserDefaults, target: String, legacy: [String]) -> Bool {
        var destination = defaults.persistentDomain(forName: target) ?? [:]
        guard destination[completionKey] as? Bool != true else { return false }
        for source in legacy {
            for (key, value) in defaults.persistentDomain(forName: source) ?? [:]
            where destination[key] == nil {
                destination[key] = value
            }
        }
        destination[completionKey] = true
        defaults.setPersistentDomain(destination, forName: target)
        return true
    }
}
