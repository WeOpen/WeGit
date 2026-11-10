import Foundation
import SQLite3
import Testing

@testable import WeGitCore

@MainActor private struct MigrationFixture {
    let root: URL
    let legacy: String
    let current: String
    let defaults: UserDefaults
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitMigrationTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        legacy = "WeGit.MigrationTests." + UUID().uuidString
        current = legacy + ".v2"
        defaults = UserDefaults(suiteName: legacy)!
    }
    func remove() {
        defaults.removePersistentDomain(forName: legacy)
        defaults.removePersistentDomain(forName: current)
        try? FileManager.default.removeItem(at: root)
    }
    func configuration(store: URL? = nil) -> ApplicationDataMigration.Configuration {
        .init(
            legacyDomains: [legacy], currentDomain: current, legacyStoreURL: store,
            stateDirectory: root.appending(path: "v2"))
    }
    func database(_ url: URL, statements: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else {
            throw ApplicationMigrationFailure.database
        }
        defer { sqlite3_close_v2(connection) }
        guard sqlite3_exec(connection, statements, nil, nil, nil) == SQLITE_OK else {
            throw ApplicationMigrationFailure.database
        }
    }
}

struct ApplicationDataMigrationTests {
    @Test @MainActor func sourceValuesStayExactAndReopenNeverSeedsDeletedCurrentValues() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let source: [String: Any] = [
            "appearance": "dark", "restoreWindow": false, "codeSize": 17.0,
            "bookmark": Data([0, 1, 2, 255]), "draft-v2:first": "中文\r\nlast",
            "workspace:first": Data("opaque source page".utf8),
            "date": Date(timeIntervalSince1970: 123_456_789),
        ]
        fixture.defaults.setPersistentDomain(source, forName: fixture.legacy)
        let migration = try ApplicationDataMigration(
            defaults: fixture.defaults, configuration: fixture.configuration())
        #expect(
            NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.legacy)!).isEqual(
                to: source))
        #expect(migration.currentDefaults.bool(forKey: "restoreWindow") == false)
        migration.currentDefaults.removeObject(forKey: "draft-v2:first")
        migration.currentDefaults.set("light", forKey: "appearance")
        let reopened = try ApplicationDataMigration(
            defaults: fixture.defaults, configuration: fixture.configuration())
        #expect(reopened.phase == .active)
        #expect(reopened.currentDefaults.object(forKey: "draft-v2:first") == nil)
        #expect(reopened.currentDefaults.string(forKey: "appearance") == "light")
        let envelope = try #require(
            PropertyListSerialization.propertyList(from: reopened.originalPreferencesSnapshot(), format: nil)
                as? [String: Any])
        #expect(envelope["format"] as? Int == 1)
        let values = try #require(envelope["values"] as? [String: Any])
        #expect(NSDictionary(dictionary: values).isEqual(to: source))
    }

    @Test @MainActor func originalRollbackRequiresFreshPlanAndExplicitResumeKeepsCurrentData() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        fixture.defaults.setPersistentDomain(
            ["appearance": "dark", "saveDrafts": true], forName: fixture.legacy)
        let migration = try ApplicationDataMigration(
            defaults: fixture.defaults, configuration: fixture.configuration())
        migration.currentDefaults.set("light", forKey: "appearance")
        let stale = try migration.prepareOriginalRestore()
        migration.currentDefaults.set("new draft", forKey: "draft-v2:current")
        #expect(throws: ApplicationMigrationFailure.self) { try migration.restoreOriginalData(stale) }
        let plan = try migration.prepareOriginalRestore()
        try migration.restoreOriginalData(plan)
        #expect(migration.phase == .rolledBack)
        #expect(migration.currentDefaults.string(forKey: "draft-v2:current") == "new draft")
        #expect(fixture.defaults.string(forKey: "appearance") == "dark")
        let reopened = try ApplicationDataMigration(
            defaults: fixture.defaults, configuration: fixture.configuration())
        #expect(reopened.phase == .rolledBack)
        try reopened.resumeVersion2()
        #expect(reopened.currentDefaults.string(forKey: "appearance") == "light")
        #expect(reopened.currentDefaults.string(forKey: "draft-v2:current") == "new draft")
    }

    @Test @MainActor func malformedDatabaseAndUnknownCurrentDomainRemainUntouched() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let malformed = fixture.root.appending(path: "Repositories.store")
        let bytes = Data("not a SQLite store".utf8)
        try bytes.write(to: malformed)
        #expect(throws: ApplicationMigrationFailure.self) {
            _ = try ApplicationDataMigration(
                defaults: fixture.defaults, configuration: fixture.configuration(store: malformed))
        }
        #expect(try Data(contentsOf: malformed) == bytes)
        #expect(fixture.defaults.persistentDomain(forName: fixture.current)?.isEmpty != false)
        fixture.defaults.setPersistentDomain(["unknown": "keep"], forName: fixture.current)
        #expect(throws: ApplicationMigrationFailure.self) {
            _ = try ApplicationDataMigration(
                defaults: fixture.defaults, configuration: fixture.configuration())
        }
        #expect(fixture.defaults.persistentDomain(forName: fixture.current)?["unknown"] as? String == "keep")
    }

    @Test @MainActor func databaseSnapshotPreservesOriginalAndChangedOriginalRejectsDowngrade() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let database = fixture.root.appending(path: "Repositories.store")
        try fixture.database(
            database,
            statements:
                "CREATE TABLE recents(path TEXT, pinned INTEGER); INSERT INTO recents VALUES('first',1);")
        let original = try Data(contentsOf: database)
        let migration = try ApplicationDataMigration(
            defaults: fixture.defaults, configuration: fixture.configuration(store: database))
        #expect(try Data(contentsOf: database) == original)
        let backup = try #require(
            try migration.currentStoreBackup(in: fixture.root.appending(path: "update-backup")))
        #expect(backup.sourceStoreURL == migration.currentStoreURL)
        #expect(backup.bytes > 0)
        #expect(try migration.matchesCurrentStoreBackup(backup))
        try fixture.database(
            migration.currentStoreURL, statements: "INSERT INTO recents VALUES('late v2 write',0);")
        #expect(try !migration.matchesCurrentStoreBackup(backup))
        try fixture.database(database, statements: "INSERT INTO recents VALUES('external',0);")
        #expect(throws: ApplicationMigrationFailure.self) { _ = try migration.prepareOriginalRestore() }
    }

    @Test @MainActor func globalDomainsAndMixedNamespacesAreRejected() throws {
        let fixture = try MigrationFixture()
        defer { fixture.remove() }
        let configuration = ApplicationDataMigration.Configuration(
            legacyDomains: [UserDefaults.globalDomain], currentDomain: fixture.current,
            legacyStoreURL: nil, stateDirectory: fixture.root.appending(path: "v2"))
        #expect(throws: ApplicationMigrationFailure.self) {
            _ = try ApplicationDataMigration(defaults: fixture.defaults, configuration: configuration)
        }
        let production = try ApplicationDataMigration.Configuration.standard(
            applicationSupportDirectory: fixture.root, applicationIdentifier: "com.willxue.wegit")
        let development = try ApplicationDataMigration.Configuration.standard(
            applicationSupportDirectory: fixture.root, applicationIdentifier: "com.willxue.wegit.development")
        #expect(production.currentDomain == "com.willxue.wegit.v2")
        #expect(development.currentDomain == "com.willxue.wegit.development.v2")
        #expect(!production.legacyDomains.contains("org.weopen.WeGit.development"))
        #expect(production.stateDirectory != development.stateDirectory)
    }
}
