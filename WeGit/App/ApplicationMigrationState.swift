import Foundation
import Observation
import WeGitCore

/// Created before the application opens preferences, windows or SwiftData. Tests
/// and injected defaults retain their existing explicit isolation contract.
@Observable @MainActor final class ApplicationMigrationState {
    let storage: ApplicationDataMigration
    private(set) var phase: ApplicationDataMigration.Phase
    var currentDefaults: UserDefaults { storage.currentDefaults }
    var currentStoreURL: URL { storage.currentStoreURL }
    var originalBackupURL: URL { storage.originalBackupURL }
    var preparationMilliseconds: Double { storage.preparationMilliseconds }
    var canUseVersion2: Bool { phase == .active }

    private init(_ storage: ApplicationDataMigration) {
        self.storage = storage
        phase = storage.phase
    }

    static func prepare(
        defaults: UserDefaults, legacyDomains: [String], currentDomain: String,
        legacyStoreURL: URL?, stateDirectory: URL
    ) throws -> ApplicationMigrationState {
        let configuration = ApplicationDataMigration.Configuration(
            legacyDomains: legacyDomains, currentDomain: currentDomain,
            legacyStoreURL: legacyStoreURL, stateDirectory: stateDirectory)
        return ApplicationMigrationState(
            try ApplicationDataMigration(
                defaults: defaults, configuration: configuration,
                validate: validateApplicationValues))
    }

    static func prepareStandard(
        defaults: UserDefaults, applicationSupportDirectory: URL, applicationIdentifier: String
    ) throws -> ApplicationMigrationState {
        let configuration = try ApplicationDataMigration.Configuration.standard(
            applicationSupportDirectory: applicationSupportDirectory,
            applicationIdentifier: applicationIdentifier)
        return ApplicationMigrationState(
            try ApplicationDataMigration(
                defaults: defaults, configuration: configuration,
                validate: validateApplicationValues))
    }

    func originalPreferencesSnapshot() throws -> Data { try storage.originalPreferencesSnapshot() }
    func currentPreferencesSnapshot() throws -> Data { try storage.currentPreferencesSnapshot() }
    func currentPreferencesFingerprint() throws -> String { try storage.currentPreferencesFingerprint() }
    func matchesCurrentPreferencesSnapshot(_ data: Data) throws -> Bool {
        try storage.matchesCurrentPreferencesSnapshot(data)
    }
    func currentStoreBackup(in directory: URL) throws -> ApplicationStoreBackup? {
        try storage.currentStoreBackup(in: directory)
    }
    func currentStoreFingerprint() throws -> String { try storage.currentStoreFingerprint() }
    func matchesCurrentStoreBackup(_ backup: ApplicationStoreBackup) throws -> Bool {
        try storage.matchesCurrentStoreBackup(backup)
    }
    func prepareOriginalRestore() throws -> ApplicationDataMigration.OriginalRestorePlan {
        try storage.prepareOriginalRestore()
    }
    func restoreOriginalData(_ plan: ApplicationDataMigration.OriginalRestorePlan) throws {
        try storage.restoreOriginalData(plan)
        phase = storage.phase
    }
    func resumeVersion2() throws {
        try storage.resumeVersion2()
        phase = storage.phase
    }

    func nativeWindowStateName(_ id: UUID) -> String { "WeGit.v2." + id.uuidString }
    func nativeSplitStatePrefix(_ id: UUID) -> String { nativeWindowStateName(id) + ".columns" }
    var legacyPrimaryFrame: String? { currentDefaults.string(forKey: "NSWindow Frame WeGit.main") }

    private static func validateApplicationValues(_ values: [String: Any]) throws {
        if let stored = values["customTheme"] {
            guard let data = stored as? Data else { throw ApplicationMigrationFailure.invalid }
            _ = try CustomTheme.decode(data)
        }
        if let stored = values[CustomThemeLibrary.key] {
            guard let data = stored as? Data else { throw ApplicationMigrationFailure.invalid }
            _ = try CustomThemeLibrary.decode(data)
        }
        for (key, value) in values {
            if key.hasPrefix("draft-v2:") || key.hasPrefix("draft:") {
                guard let text = value as? String, text.utf8.count <= 1024 * 1024 else {
                    throw ApplicationMigrationFailure.invalid
                }
            } else if key.hasPrefix("workspace:") {
                guard let data = value as? Data, data.count <= 64 * 1024,
                    let page = try? JSONDecoder().decode(RepositoryViewPreferences.self, from: data),
                    WorkspaceRoute(rawValue: page.route) != nil,
                    page.filter.utf8.count <= 4096, page.branchFilter.utf8.count <= 4096,
                    page.selectedFile?.contains("\0") != true
                else { throw ApplicationMigrationFailure.invalid }
            }
        }
    }
}
