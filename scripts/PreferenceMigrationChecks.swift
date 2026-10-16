import Foundation

/// Compiled with the application's actual Foundation-only migration source.
@main struct PreferenceMigrationChecks {
    static func main() throws {
        let prefix = "com.willxue.wegit.MigrationChecks." + UUID().uuidString
        let source = prefix + ".source"
        let fallback = prefix + ".fallback"
        let target = prefix + ".target"
        let missing = prefix + ".missing"
        let defaults = UserDefaults(suiteName: target)!
        defer {
            for domain in [source, fallback, target, missing] {
                defaults.removePersistentDomain(forName: domain)
            }
            defaults.synchronize()
        }
        var passed: [String] = []
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else {
                throw NSError(
                    domain: "WeGit.PreferenceMigration", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
            }
            passed.append(name)
        }
        let draft = Data("First line\n\t中文 draft\n".utf8)
        let workspace = Data("{\"route\":\"更改\",\"inspector\":true}".utf8)
        let original: [String: Any] = [
            "appearance": "dark", "restoreWindow": true, "draft:fixture": draft,
            "workspace:fixture": workspace, "lastRepositoryBookmark": Data([0, 1, 2, 255]),
            "NSWindow Frame WeGit.main": "70 60 1360 850 0 0 1512 949",
            "NSSplitView Subview Frames WeGit.columns.0": ["0, 0, 210, 850", "211, 0, 1149, 850"],
        ]
        defaults.setPersistentDomain(original, forName: source)
        try check(
            "Fresh destination migrates",
            PreferenceMigration.migrate(defaults: defaults, target: target, legacy: [source]))
        let migrated = defaults.persistentDomain(forName: target)!
        try check("Appearance migrates", migrated["appearance"] as? String == "dark")
        try check("Draft bytes remain exact", migrated["draft:fixture"] as? Data == draft)
        try check("Workspace bytes remain exact", migrated["workspace:fixture"] as? Data == workspace)
        try check(
            "Repository bookmark remains exact",
            migrated["lastRepositoryBookmark"] as? Data == Data([0, 1, 2, 255]))
        try check(
            "Window and split state migrate",
            migrated["NSWindow Frame WeGit.main"] as? String == original["NSWindow Frame WeGit.main"]
                as? String
                && migrated["NSSplitView Subview Frames WeGit.columns.0"] as? [String] == original[
                    "NSSplitView Subview Frames WeGit.columns.0"] as? [String]
        )
        try check(
            "Legacy domain is unchanged",
            NSDictionary(dictionary: defaults.persistentDomain(forName: source)!).isEqual(to: original))

        defaults.setPersistentDomain(
            ["appearance": "light", "restoreWindow": false, "ownValue": 42], forName: target)
        PreferenceMigration.migrate(defaults: defaults, target: target, legacy: [source])
        let existing = defaults.persistentDomain(forName: target)!
        try check(
            "Existing destination values win, including false",
            existing["appearance"] as? String == "light" && existing["restoreWindow"] as? Bool == false
                && existing["ownValue"] as? Int == 42)
        try check("Existing destination receives missing draft", existing["draft:fixture"] as? Data == draft)
        defaults.removeObject(forKey: "draft:fixture")
        try check(
            "Second launch skips migration",
            !PreferenceMigration.migrate(defaults: defaults, target: target, legacy: [source]))
        try check("Deleted destination setting stays deleted", defaults.data(forKey: "draft:fixture") == nil)

        defaults.removePersistentDomain(forName: target)
        defaults.setPersistentDomain(["appearance": "light", "fallbackOnly": "kept"], forName: fallback)
        PreferenceMigration.migrate(defaults: defaults, target: target, legacy: [source, fallback])
        try check(
            "Legacy priority is stable",
            defaults.string(forKey: "appearance") == "dark"
                && defaults.string(forKey: "fallbackOnly") == "kept")
        defaults.removePersistentDomain(forName: target)
        PreferenceMigration.migrate(defaults: defaults, target: target, legacy: [missing])
        try check(
            "Fresh install does not import unrelated preferences",
            defaults.persistentDomain(forName: target)?.count == 1
                && defaults.bool(forKey: PreferenceMigration.completionKey))
        try check(
            "Production domain mappings match the new identifiers",
            PreferenceMigration.legacyDomains(for: "com.willxue.wegit.development") == [
                "org.weopen.WeGit.development"
            ]
                && PreferenceMigration.legacyDomains(for: "com.willxue.wegit") == [
                    "com.willxue.WeGit", "org.weopen.WeGit",
                ])
        try check(
            "Test and performance domains stay isolated",
            ["com.willxue.wegit.UITests", "com.willxue.wegit.performanceHarness", "example.other"].allSatisfy
            { PreferenceMigration.legacyDomains(for: $0).isEmpty })
        let report: [String: Any] = [
            "passed": true, "checks": passed,
            "scope": "Actual migration source; private UUID preference domains only",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("\(passed.count) preference migration behavior checks passed.")
    }
}
