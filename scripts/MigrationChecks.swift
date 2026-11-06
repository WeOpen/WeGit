import AppKit
import CryptoKit
import Darwin
import Foundation
import SQLite3
import SwiftData
import WeGitCore

private struct RecentImage: Equatable {
    let path: String
    let name: String
    let opened: UInt64
    let pinned: Bool
    let identity: Data
    init(_ item: RecentRepository) throws {
        path = item.path
        name = item.name
        opened = item.openedAt.timeIntervalSince1970.bitPattern
        pinned = item.pinned
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        identity = try encoder.encode(item.persistentModelID)
    }
}
private enum MigrationCheckFailure: Error { case failed(String) }
private func require(_ value: Bool, _ name: String) throws {
    if !value { throw MigrationCheckFailure.failed(name) }
}
private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func sqlite(_ path: String, _ body: (OpaquePointer) throws -> Void) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(path, &connection) == SQLITE_OK, let connection else {
        throw MigrationCheckFailure.failed("SQLite open")
    }
    defer { sqlite3_close_v2(connection) }
    try body(connection)
}
private func execute(_ connection: OpaquePointer, _ command: String) throws {
    guard sqlite3_exec(connection, command, nil, nil, nil) == SQLITE_OK else {
        throw MigrationCheckFailure.failed("SQLite command")
    }
}

@main struct MigrationChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--candidate-write" {
            let path = CommandLine.arguments[2]
            guard path.contains("WeGitMigrationControl-"), path.hasSuffix("/Repositories.store") else {
                throw MigrationCheckFailure.failed("Candidate fixture path")
            }
            let lock = open(
                URL(fileURLWithPath: path).deletingLastPathComponent().appending(
                    path: ".application-data.lock"
                ).path,
                O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard lock >= 0, flock(lock, LOCK_SH) == 0 else {
                throw MigrationCheckFailure.failed("Candidate fixture lock")
            }
            defer { Darwin.close(lock) }
            try sqlite(path) { try execute($0, "UPDATE ZRECENTREPOSITORY SET ZNAME='failed candidate';") }
            return
        }
        let parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var template = Array(parent.appending(path: "WeGitMigrationControl-XXXXXX").path.utf8CString)
        guard let directory = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw MigrationCheckFailure.failed("Temporary fixture")
        }
        let root = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        print("Fixture: " + root.path)
        let prefix = "com.willxue.wegit.UITests.MigrationControl." + UUID().uuidString
        let legacyDomain = prefix + ".legacy"
        let fallbackDomain = prefix + ".fallback"
        let legacyDomains = [legacyDomain, fallbackDomain]
        let currentDomain = prefix + ".v2"
        let defaults = UserDefaults(suiteName: legacyDomain)!
        defer {
            defaults.removePersistentDomain(forName: legacyDomain)
            defaults.removePersistentDomain(forName: fallbackDomain)
            defaults.removePersistentDomain(forName: currentDomain)
        }
        var checks: [String] = []
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let engine = GitEngine(environment: environment)
        let repo = root.appending(path: "FirstWorktree")
        let second = root.appending(path: "SecondWorktree")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await engine.run(["init", "-b", "main"], in: repo)
        for (name, value) in [
            ("user.name", "Migration Fixture"), ("user.email", "migration@example.invalid"),
            ("commit.gpgsign", "false"),
        ] {
            _ = try await engine.run(["config", name, value], in: repo)
        }
        try Data("fixture\n".utf8).write(to: repo.appending(path: "file.txt"))
        _ = try await engine.run(["add", "."], in: repo)
        _ = try await engine.run(["commit", "-m", "Initial"], in: repo)
        _ = try await engine.run(["worktree", "add", "-b", "second", second.path, "HEAD"], in: repo)
        let firstLocation = try await RepositoryService.discover(repo, engine: engine)
        let secondLocation = try await RepositoryService.discover(second, engine: engine)
        let firstDraft = "中文 draft 🧩\r\nlast"
        let secondDraft = "Second draft without final LF"
        let firstPage = RepositoryViewPreferences(
            route: WorkspaceRoute.history.rawValue, selectedFile: nil,
            inspector: true, filter: "中文", branchFilter: "main", splitDiff: true, wordDiff: true,
            contextLines: 80, ignoreWhitespace: true, changeFilter: nil, changesByFolder: false)
        let secondPage = RepositoryViewPreferences(
            route: WorkspaceRoute.changes.rawValue, selectedFile: "unstaged|file.txt",
            inspector: false, filter: "file", branchFilter: "second", splitDiff: false, wordDiff: false,
            contextLines: 20, ignoreWhitespace: false, changeFilter: "all", changesByFolder: true)
        var theme = CustomTheme.starter
        theme.name = "迁移主题 🧩"
        theme.controls = .light
        for (index, role) in ThemeColorRole.allCases.enumerated() {
            theme[role] = String(format: "#%06X", 0x123456 + index * 7919)
        }
        let original: [String: Any] = [
            "language": AppLanguage.english.rawValue, "appearance": "custom", "restoreWindow": false,
            "restoreRepository": true, "saveDrafts": true, "showMenuBar": false, "codeSize": 17.0,
            "codeFont": "Monaco", "density": "compact", "activityLimit": 500, "activityHours": 168,
            "customTheme": try theme.encoded(), "lastRepository": repo.path,
            "lastRepositoryBookmark": Data([0, 1, 2, 255]),
            "draft-v2:" + firstLocation.persistenceID: firstDraft,
            "draft-v2:" + secondLocation.persistenceID: secondDraft,
            "workspace:" + firstLocation.persistenceID: try JSONEncoder().encode(firstPage),
            "workspace:" + secondLocation.persistenceID: try JSONEncoder().encode(secondPage),
            "NSWindow Frame WeGit.main": "70 60 1360 880 0 0 1512 982",
            "NSSplitView Subview Frames WeGit.columns.0": ["0, 0, 220, 880", "221, 0, 1139, 880"],
        ]
        defaults.setPersistentDomain(original, forName: legacyDomain)
        let fallback: [String: Any] = [
            "appearance": "light", "restoreWindow": true, "fallbackOnly": Data([4, 3, 2, 1]),
        ]
        defaults.setPersistentDomain(fallback, forName: fallbackDomain)
        try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
            .write(to: root.appending(path: "original-preferences-input.plist"))
        let legacyDirectory = root.appending(path: "legacy")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyStore = legacyDirectory.appending(path: "Repositories.store")
        var legacyContainer: ModelContainer? = try ModelContainer(
            for: RecentRepository.self,
            configurations: ModelConfiguration(url: legacyStore, cloudKitDatabase: .none))
        var expectedRecents: [RecentImage] = []
        for (index, item) in [
            (repo.path, "First 中文"), (second.path, "Second 🧩"), (root.appending(path: "third").path, "Third"),
        ].enumerated() {
            let row = RecentRepository(path: item.0, name: item.1)
            row.openedAt = Date(timeIntervalSince1970: 123456789.125 + Double(index))
            row.pinned = index != 1
            legacyContainer!.mainContext.insert(row)
        }
        try legacyContainer!.mainContext.save()
        legacyContainer = nil
        legacyContainer = try ModelContainer(
            for: RecentRepository.self,
            configurations: ModelConfiguration(url: legacyStore, cloudKitDatabase: .none))
        expectedRecents = try legacyContainer!.mainContext.fetch(FetchDescriptor<RecentRepository>()).map(
            RecentImage.init
        ).sorted { $0.path < $1.path }
        legacyContainer = nil
        var walConnection: OpaquePointer?
        guard sqlite3_open(legacyStore.path, &walConnection) == SQLITE_OK, let walConnection else {
            throw MigrationCheckFailure.failed("Legacy WAL source")
        }
        defer { sqlite3_close_v2(walConnection) }
        try execute(walConnection, "PRAGMA journal_mode=WAL; UPDATE ZRECENTREPOSITORY SET ZNAME=ZNAME;")
        let originalFiles = try storeBytes(legacyStore)
        try require(originalFiles.keys.contains("Repositories.store-wal"), "Legacy WAL fixture")
        var migration: ApplicationMigrationState? = try ApplicationMigrationState.prepare(
            defaults: defaults,
            legacyDomains: legacyDomains, currentDomain: currentDomain, legacyStoreURL: legacyStore,
            stateDirectory: root.appending(path: "v2"))
        let initialMilliseconds = migration!.preparationMilliseconds
        try require(
            NSDictionary(dictionary: defaults.persistentDomain(forName: legacyDomain)!).isEqual(to: original),
            "Original preference values")
        try require(try storeBytes(legacyStore) == originalFiles, "Original DB/WAL/SHM bytes")
        checks.append("v1.2 raw preference values and DB/WAL/SHM bytes remain unchanged")
        let currentDefaults = migration!.currentDefaults
        try require(
            currentDefaults.data(forKey: "fallbackOnly") == Data([4, 3, 2, 1])
                && NSDictionary(dictionary: defaults.persistentDomain(forName: fallbackDomain)!).isEqual(
                    to: fallback),
            "Multiple legacy domains retain source and priority")
        checks.append("all legacy domains retain raw values and primary-domain values take priority")
        let preferences = AppPreferences(defaults: currentDefaults)
        try require(
            preferences.customTheme == theme && preferences.customTheme.colors.count == 17
                && preferences.customTheme.controls == .light, "Theme17 colors/controls")
        try require(
            preferences.codeSize == 17 && preferences.codeFont == "Monaco" && !preferences.restoreWindow
                && !preferences.showMenuBar, "Settings false and scalar values")
        try require(
            NSDictionary(dictionary: defaults.persistentDomain(forName: legacyDomain)!).isEqual(to: original),
            "Theme migration doesn't overwrite source")
        checks.append(
            "settings and custom theme migrate all seventeen colors, controls and current selection")
        let windows = try WindowSessionPersistence(defaults: currentDefaults, domainName: currentDomain)
        let first = try windows.readDraft(
            workspaceID: firstLocation.persistenceID, legacyKey: "draft-v2:" + firstLocation.persistenceID)
        let secondSaved = try windows.readDraft(
            workspaceID: secondLocation.persistenceID, legacyKey: "draft-v2:" + secondLocation.persistenceID)
        try require(first?.text == firstDraft && secondSaved?.text == secondDraft, "Two worktree drafts")
        let decodedFirst = try JSONDecoder().decode(
            RepositoryViewPreferences.self,
            from: currentDefaults.data(forKey: "workspace:" + firstLocation.persistenceID)!)
        let decodedSecond = try JSONDecoder().decode(
            RepositoryViewPreferences.self,
            from: currentDefaults.data(forKey: "workspace:" + secondLocation.persistenceID)!)
        try require(decodedFirst == firstPage && decodedSecond == secondPage, "Two worktree pages")
        try windows.saveDraft(
            SharedDraftSnapshot(revision: 1, text: "new v2 draft"), workspaceID: firstLocation.persistenceID)
        try require(
            defaults.string(forKey: "draft-v2:" + firstLocation.persistenceID) == firstDraft,
            "New v2 draft doesn't overwrite original")
        checks.append(
            "linked worktree drafts/page values remain distinct and v2 writes leave legacy values intact")
        let configuration = migration!.storage.configuration
        let currentStore = migration!.currentStoreURL
        var currentContainer: ModelContainer? = try ModelContainer(
            for: RecentRepository.self,
            configurations: ModelConfiguration(url: currentStore, cloudKitDatabase: .none))
        let migratedRecents = try currentContainer!.mainContext.fetch(FetchDescriptor<RecentRepository>())
            .map(RecentImage.init).sorted { $0.path < $1.path }
        let rowObservation: [String: Any] = [
            "expected": expectedRecents.map {
                [
                    "path": $0.path, "name": $0.name, "opened": String($0.opened),
                    "pinned": String($0.pinned), "identity": String(describing: $0.identity),
                ]
            },
            "migrated": migratedRecents.map {
                [
                    "path": $0.path, "name": $0.name, "opened": String($0.opened),
                    "pinned": String($0.pinned), "identity": String(describing: $0.identity),
                ]
            },
        ]
        try JSONSerialization.data(withJSONObject: rowObservation, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: "row-observation.json"))
        try require(migratedRecents == expectedRecents, "SwiftData rows/favorites/persistent identity")
        checks.append(
            "actual SwiftData recent/favorite rows keep paths, names, date bits and persistent identities")
        var expectedCurrentRecents = expectedRecents
        #if MIGRATION_APP_INTEGRATION
            do {
                let integrated = AppState(defaultsOverride: currentDefaults, migrationOverride: migration!)
                try require(
                    integrated.defaults === currentDefaults && integrated.preferences.customTheme == theme,
                    "Actual AppState uses v2 preferences/theme")
                let initialRows = try integrated.recents.map(RecentImage.init).sorted { $0.path < $1.path }
                try require(
                    initialRows == expectedRecents, "Actual AppState uses migrated recent/favorite store")
                integrated.preferences.restoreWindow = true
                await integrated.open(repo)
                try require(
                    integrated.session?.message == "new v2 draft" && integrated.workspace.route == .history
                        && integrated.workspace.filter == firstPage.filter,
                    "Actual first worktree v2 draft/page")
                await integrated.open(second)
                try require(
                    integrated.session?.message == secondDraft && integrated.workspace.route == .changes
                        && integrated.workspace.filter == secondPage.filter,
                    "Actual second worktree migrated draft/page")
                integrated.session?.deactivate(owner: integrated.windowID)
                try require(
                    NSDictionary(dictionary: defaults.persistentDomain(forName: legacyDomain)!).isEqual(
                        to: original)
                        && storeBytes(legacyStore) == originalFiles,
                    "Actual AppState leaves original business/store unchanged")
            }
            currentContainer = nil
            currentContainer = try ModelContainer(
                for: RecentRepository.self,
                configurations: ModelConfiguration(url: currentStore, cloudKitDatabase: .none))
            expectedCurrentRecents = try currentContainer!.mainContext.fetch(
                FetchDescriptor<RecentRepository>()
            )
            .map(RecentImage.init).sorted { $0.path < $1.path }
            checks.append(
                "actual AppState migration injection opens v2 suite/database and distinct worktree drafts/pages without changing originals"
            )
        #endif
        currentDefaults.set("dark", forKey: "appearance")
        var warm: [Double] = []
        for _ in 0..<30 {
            let reopen = try ApplicationMigrationState.prepare(
                defaults: defaults, legacyDomains: legacyDomains,
                currentDomain: currentDomain, legacyStoreURL: legacyStore,
                stateDirectory: root.appending(path: "v2"))
            warm.append(reopen.preparationMilliseconds)
            try require(
                reopen.currentDefaults.string(forKey: "appearance") == "dark",
                "Reopen retains current preference")
        }
        checks.append("thirty repeated opens preserve current v2 values rather than reseeding old settings")
        let preferencesBackup = try migration!.currentPreferencesSnapshot()
        let originalPreferences = try migration!.originalPreferencesSnapshot()
        currentContainer = nil
        let storeBackup = try migration!.currentStoreBackup(in: root.appending(path: "update-snapshot"))!
        try require(
            storeBackup.bytes > 0 && digest(storeBackup.data) == storeBackup.sha256,
            "Current self-contained store backup")
        let beforeCandidateFingerprint = try migration!.currentStoreFingerprint()
        try require(
            try migration!.matchesCurrentStoreBackup(storeBackup),
            "Snapshot source fingerprint matches before late writer")
        do {
            _ = try ApplicationDataMigration.restoreCurrentStoreBackup(
                storeBackup, configuration: configuration, stoppedWriterPID: getpid())
            throw MigrationCheckFailure.failed("Live writer restored")
        } catch is ApplicationMigrationFailure {}
        let candidate = Process()
        candidate.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        candidate.arguments = ["--candidate-write", currentStore.path]
        try candidate.run()
        candidate.waitUntilExit()
        try require(candidate.terminationStatus == 0, "Candidate writes then exits")
        let afterCandidateFingerprint = try migration!.currentStoreFingerprint()
        try require(
            beforeCandidateFingerprint != afterCandidateFingerprint
                && !migration!.matchesCurrentStoreBackup(storeBackup),
            "Late database writer invalidates snapshot source CAS")
        checks.append("database/WAL source fingerprint rejects writes arriving after snapshot capture")
        migration = nil
        let restoration = try ApplicationDataMigration.restoreCurrentStoreBackup(
            storeBackup, configuration: configuration, stoppedWriterPID: candidate.processIdentifier)
        try require(restoration.restoredSHA256 == storeBackup.sha256, "Fixed-path current store restores")
        currentDefaults.set("failed candidate setting", forKey: "appearance")
        let restoredPreferencesSHA = try ApplicationDataMigration.restoreCurrentPreferencesSnapshot(
            preferencesBackup, configuration: configuration, stoppedWriterPID: candidate.processIdentifier)
        let restoredPreferencesMatch = try ApplicationDataMigration.matchesCurrentPreferencesSnapshot(
            preferencesBackup, configuration: configuration)
        try require(
            restoredPreferencesSHA == digest(preferencesBackup) && restoredPreferencesMatch,
            "Current preference semantic restore and immutable raw receipt")
        currentContainer = try ModelContainer(
            for: RecentRepository.self,
            configurations: ModelConfiguration(url: currentStore, cloudKitDatabase: .none))
        let restoredRecents = try currentContainer!.mainContext.fetch(FetchDescriptor<RecentRepository>())
            .map(RecentImage.init).sorted { $0.path < $1.path }
        try require(
            restoredRecents == expectedCurrentRecents,
            "Current recents/favorites restored after failed candidate")
        try require(
            try storeBytes(legacyStore) == originalFiles, "Ordinary v2 rollback doesn't restore legacy DB")
        checks.append(
            "current v2 backup rejects live writers and restores failed-candidate recent/favorite changes through fixed path"
        )
        checks.append(
            "ordinary v2 preference restore verifies typed values and returns the immutable backup checksum")
        migration = try ApplicationMigrationState.prepare(
            defaults: defaults, legacyDomains: legacyDomains, currentDomain: currentDomain,
            legacyStoreURL: legacyStore, stateDirectory: root.appending(path: "v2"))
        let stalePlan = try migration!.prepareOriginalRestore()
        currentDefaults.set("new value", forKey: "defaultDirectory")
        do {
            try migration!.restoreOriginalData(stalePlan)
            throw MigrationCheckFailure.failed("Stale restore plan accepted")
        } catch is ApplicationMigrationFailure {}
        let restorePlan = try migration!.prepareOriginalRestore()
        try migration!.restoreOriginalData(restorePlan)
        try require(
            migration!.phase == .rolledBack && !migration!.canUseVersion2,
            "Explicit old-data restore pauses v2 access")
        try require(
            currentDefaults.string(forKey: "defaultDirectory") == "new value",
            "New v2 values retained on downgrade")
        try require(
            try storeBytes(legacyStore) == originalFiles, "Explicit restore keeps original store bytes")
        try migration!.resumeVersion2()
        try require(migration!.canUseVersion2, "Explicit resume")
        checks.append(
            "explicit legacy restore checks fresh plan, preserves new v2 data and requires explicit resume")
        let originalEnvelope =
            try PropertyListSerialization.propertyList(from: originalPreferences, format: nil)
            as! [String: Any]
        let currentEnvelope =
            try PropertyListSerialization.propertyList(from: preferencesBackup, format: nil) as! [String: Any]
        try require(
            originalEnvelope["format"] as? Int == 1 && currentEnvelope["format"] as? Int == 1,
            "UpdateDataBackup envelope format")
        checks.append("original/current preferences use the bounded UpdateDataBackup format-one envelope")
        for (index, broken) in [
            ["customTheme": Data("{\"version\":99}".utf8)],
            ["workspace:broken": Data("{\"route\":\"unknown\"}".utf8)],
            ["draft-v2:broken": Data("wrong stored kind".utf8)],
        ].enumerated() {
            let old = prefix + ".invalid-\(index)"
            let new = old + ".v2"
            defaults.setPersistentDomain(broken, forName: old)
            defer {
                defaults.removePersistentDomain(forName: old)
                defaults.removePersistentDomain(forName: new)
            }
            var rejected = false
            do {
                _ = try ApplicationMigrationState.prepare(
                    defaults: defaults, legacyDomains: [old], currentDomain: new,
                    legacyStoreURL: nil, stateDirectory: root.appending(path: "invalid-\(index)"))
            } catch { rejected = true }
            try require(
                rejected
                    && NSDictionary(dictionary: defaults.persistentDomain(forName: old)!).isEqual(to: broken)
                    && defaults.persistentDomain(forName: new)?.isEmpty != false,
                "Bad legacy format preserved")
        }
        checks.append("malformed theme/page/draft formats block activation and keep original values")
        let healthyCurrent = currentDefaults.persistentDomain(forName: currentDomain)!
        let damagedMarker = Data("{\"format\":99}".utf8)
        currentDefaults.set(damagedMarker, forKey: "v2.data-migration")
        var badReopenRejected = false
        do {
            _ = try ApplicationMigrationState.prepare(
                defaults: defaults, legacyDomains: legacyDomains, currentDomain: currentDomain,
                legacyStoreURL: legacyStore, stateDirectory: root.appending(path: "v2"))
        } catch { badReopenRejected = true }
        try require(
            badReopenRejected && currentDefaults.data(forKey: "v2.data-migration") == damagedMarker,
            "Bad current marker preserved on reopen")
        currentDefaults.setPersistentDomain(healthyCurrent, forName: currentDomain)
        checks.append("damaged migration marker stops reopen without overwriting input")
        let archivedPreferences = migration!.originalBackupURL.appending(path: "preferences-0.plist")
        let archivedBytes = try Data(contentsOf: archivedPreferences)
        try (archivedBytes + Data([255])).write(to: archivedPreferences)
        var archiveRejected = false
        do { _ = try migration!.prepareOriginalRestore() } catch { archiveRejected = true }
        try require(
            archiveRejected
                && NSDictionary(dictionary: defaults.persistentDomain(forName: legacyDomain)!).isEqual(
                    to: original),
            "Damaged original archive refuses rollback without changing legacy values")
        try archivedBytes.write(to: archivedPreferences)
        checks.append(
            "damaged original archive blocks rollback and leaves original application data unchanged")
        let sorted = warm.sorted()
        let repeatedSnapshots = try (0..<30).map { _ in try migration!.currentPreferencesSnapshot() }
        let repeatedSnapshotHashes = repeatedSnapshots.map(digest)
        let snapshotFingerprints = try (0..<30).map { _ in try migration!.currentPreferencesFingerprint() }
        let snapshotsMatch = try repeatedSnapshots.allSatisfy {
            try migration!.matchesCurrentPreferencesSnapshot($0)
        }
        try require(
            Set(snapshotFingerprints).count == 1 && snapshotsMatch,
            "Typed preference value fingerprint is stable")
        let report: [String: Any] = [
            "allPassed": true, "xctestExecuted": false, "checks": checks, "checkCount": checks.count,
            "initialMigrationMilliseconds": initialMilliseconds, "warmPreparationMilliseconds": warm,
            "warmPreparationP95Milliseconds": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
            "currentStoreBackupBytes": storeBackup.bytes,
            "repeatedSnapshotSHA256Count": Set(repeatedSnapshotHashes).count,
            "repeatedSnapshotSHA256": repeatedSnapshotHashes,
            "repeatedSnapshotValueFingerprintCount": Set(snapshotFingerprints).count,
            "scope":
                "Private domains/SwiftData/WAL/linked worktrees; Debug diagnostic, not Release startup acceptance",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: root.appending(path: "result.json"))
        print(root.path)
        print(
            String(
                decoding: try JSONSerialization.data(
                    withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }

    private static func storeBytes(_ store: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in [
            store.lastPathComponent, store.lastPathComponent + "-wal", store.lastPathComponent + "-shm",
        ] {
            let url = store.deletingLastPathComponent().appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { result[name] = try Data(contentsOf: url) }
        }
        return result
    }
}
