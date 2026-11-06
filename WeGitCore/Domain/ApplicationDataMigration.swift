import CoreFoundation
import Darwin
import Foundation

/// Owns a separate v2 preference suite and database. The original source remains
/// readable by v1.2; rollback changes only its known legacy values after a new CAS.
@MainActor public final class ApplicationDataMigration {
    public enum Phase: String, Codable, Sendable { case prepared, active, rolledBack }
    public struct Configuration: Codable, Equatable, Sendable {
        public let legacyDomains: [String]
        public let currentDomain: String
        public let legacyStoreURL: URL?
        public let stateDirectory: URL
        public init(legacyDomains: [String], currentDomain: String, legacyStoreURL: URL?, stateDirectory: URL)
        {
            self.legacyDomains = legacyDomains
            self.currentDomain = currentDomain
            self.legacyStoreURL = legacyStoreURL.map {
                guard $0.isFileURL else { return $0 }
                return URL(
                    fileURLWithPath: MigrationFileSnapshot.canonicalPath($0.deletingLastPathComponent()),
                    isDirectory: true
                )
                .appending(path: $0.lastPathComponent)
            }
            self.stateDirectory =
                stateDirectory.isFileURL
                ? URL(fileURLWithPath: MigrationFileSnapshot.canonicalPath(stateDirectory), isDirectory: true)
                : stateDirectory
        }
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.legacyDomains == rhs.legacyDomains && lhs.currentDomain == rhs.currentDomain
                && lhs.legacyStoreURL.map(MigrationFileSnapshot.canonicalPath)
                    == rhs.legacyStoreURL.map(MigrationFileSnapshot.canonicalPath)
                && MigrationFileSnapshot.canonicalPath(lhs.stateDirectory)
                    == MigrationFileSnapshot.canonicalPath(rhs.stateDirectory)
        }
        public static func standard(applicationSupportDirectory: URL, applicationIdentifier: String) throws
            -> Self
        {
            let legacy: [String]
            let folder: String
            switch applicationIdentifier {
            case "com.willxue.wegit":
                legacy = [applicationIdentifier, "com.willxue.WeGit", "org.weopen.WeGit"]
                folder = "v2"
            case "com.willxue.wegit.development":
                legacy = [applicationIdentifier, "org.weopen.WeGit.development"]
                folder = "development-v2"
            default: throw ApplicationMigrationFailure.invalid
            }
            let base = applicationSupportDirectory.appending(path: "WeGit", directoryHint: .isDirectory)
            return Self(
                legacyDomains: legacy, currentDomain: applicationIdentifier + ".v2",
                legacyStoreURL: base.appending(path: "Repositories.store"),
                stateDirectory: base.appending(path: folder, directoryHint: .isDirectory))
        }
    }
    public struct OriginalRestorePlan: Sendable {
        let id: UUID
        let currentFingerprint: String
        let legacyFingerprints: [String: String]
    }
    private struct PreferenceImage: Codable {
        let domain: String
        let name: String
        let sha256: String
        let fingerprint: String
    }
    private struct Manifest: Codable {
        let format: Int
        let id: UUID
        let configuration: Configuration
        let preferences: [PreferenceImage]
        let originalStore: MigrationStoreImage
        let normalizedStoreSHA256: String?
        let normalizedStoreBytes: Int?
    }
    private struct Marker: Codable {
        var format = 2
        let id: UUID
        let manifestSHA256: String
        var phase: Phase
        var currentDirectory: MigrationDirectoryIdentity? = nil
    }
    private static let markerKey = "v2.data-migration"
    public let configuration: Configuration
    public let currentDefaults: UserDefaults
    public var currentStoreURL: URL {
        configuration.stateDirectory.appending(path: "Repositories.store")
    }
    public var originalBackupURL: URL { configuration.stateDirectory.appending(path: "archive-v1") }
    public private(set) var phase = Phase.prepared
    public private(set) var preparationMilliseconds: Double = 0
    private let defaults: UserDefaults
    private let manifest: Manifest
    private let manifestSHA256: String
    private let dataLock: MigrationDataLock
    private var currentDirectoryIdentity: MigrationDirectoryIdentity?

    public init(
        defaults: UserDefaults, configuration: Configuration,
        validate: ([String: Any]) throws -> Void = { _ in }
    ) throws {
        let started = ProcessInfo.processInfo.systemUptime
        try Self.validate(configuration)
        self.defaults = defaults
        self.configuration = configuration
        guard let current = UserDefaults(suiteName: configuration.currentDomain) else {
            throw ApplicationMigrationFailure.invalid
        }
        currentDefaults = current
        try MigrationFileSnapshot.makeDirectory(configuration.stateDirectory)
        let currentDirectory = configuration.stateDirectory
        try MigrationFileSnapshot.makeDirectory(currentDirectory)
        let lock = open(
            currentDirectory.appending(path: ".application-data.lock").path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_SH | LOCK_NB) == 0 else {
            if lock >= 0 { Darwin.close(lock) }
            throw ApplicationMigrationFailure.changed
        }
        dataLock = MigrationDataLock(lock)
        let archive = configuration.stateDirectory.appending(path: "archive-v1")
        let manifestURL = archive.appending(path: "manifest.json")
        if FileManager.default.fileExists(atPath: archive.path) {
            let data = try MigrationFileSnapshot.read(manifestURL, limit: 256 * 1024)
            guard let decoded = try? JSONDecoder().decode(Manifest.self, from: data), decoded.format == 2,
                decoded.configuration == configuration,
                decoded.preferences.count == configuration.legacyDomains.count,
                Set(decoded.preferences.map(\.domain)) == Set(configuration.legacyDomains),
                decoded.preferences.enumerated().allSatisfy({
                    $0.element.name == "preferences-\($0.offset).plist"
                }),
                decoded.originalStore.source.map(MigrationFileSnapshot.canonicalPath)
                    == configuration.legacyStoreURL.map(MigrationFileSnapshot.canonicalPath)
            else { throw ApplicationMigrationFailure.invalid }
            manifest = decoded
            manifestSHA256 = MigrationFileSnapshot.digest(data)
        } else {
            guard defaults.persistentDomain(forName: configuration.currentDomain)?.isEmpty != false,
                try MigrationFileSnapshot.version(
                    configuration.stateDirectory.appending(path: "Repositories.store")) == nil
            else { throw ApplicationMigrationFailure.changed }
            let sourceValues = try Self.readDomains(defaults, names: configuration.legacyDomains)
            let merged = Self.merge(sourceValues, order: configuration.legacyDomains)
            try validate(merged)
            let prepared = try Self.createArchive(
                configuration, values: sourceValues, defaults: defaults, started: started)
            guard try Self.domainsEqual(defaults, expected: sourceValues) else {
                throw ApplicationMigrationFailure.changed
            }
            try MigrationFileSnapshot.verifySource(prepared.originalStore, started: started)
            manifest = prepared
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(prepared)
            manifestSHA256 = MigrationFileSnapshot.digest(data)
        }
        if let marker = try Self.readMarker(current, domain: configuration.currentDomain) {
            guard marker.id == manifest.id, marker.manifestSHA256 == manifestSHA256, marker.format == 2 else {
                throw ApplicationMigrationFailure.changed
            }
            phase = marker.phase
            currentDirectoryIdentity = marker.currentDirectory
            if phase != .prepared {
                guard marker.currentDirectory != nil,
                    try MigrationDirectoryIdentity.read(currentStoreURL.deletingLastPathComponent())
                        == marker.currentDirectory
                else { throw ApplicationMigrationFailure.changed }
            }
        } else {
            guard current.persistentDomain(forName: configuration.currentDomain)?.isEmpty != false else {
                throw ApplicationMigrationFailure.changed
            }
            phase = .prepared
        }
        if phase == .prepared {
            let original = try originalDomainValues()
            guard try Self.domainsEqual(defaults, expected: original) else {
                throw ApplicationMigrationFailure.changed
            }
            try MigrationFileSnapshot.verifySource(manifest.originalStore, started: started)
            var seed = Self.merge(original, order: configuration.legacyDomains)
            try validate(seed)
            seed[Self.markerKey] = try JSONEncoder().encode(
                Marker(id: manifest.id, manifestSHA256: manifestSHA256, phase: .prepared))
            let existing = current.persistentDomain(forName: configuration.currentDomain) ?? [:]
            let matchesSeed = try Self.fingerprint(existing) == Self.fingerprint(seed)
            guard existing.isEmpty || matchesSeed else {
                throw ApplicationMigrationFailure.changed
            }
            current.setPersistentDomain(seed, forName: configuration.currentDomain)
            guard current.synchronize(),
                try Self.fingerprint(current.persistentDomain(forName: configuration.currentDomain) ?? [:])
                    == Self.fingerprint(seed)
            else {
                throw ApplicationMigrationFailure.changed
            }
            try MigrationFileSnapshot.makeDirectory(currentStoreURL.deletingLastPathComponent())
            if let expected = manifest.normalizedStoreSHA256 {
                let source = originalBackupURL.appending(path: "normalized.store")
                let bytes = try MigrationFileSnapshot.read(
                    source, limit: MigrationFileSnapshot.maximumStoreBytes)
                guard MigrationFileSnapshot.digest(bytes) == expected else {
                    throw ApplicationMigrationFailure.changed
                }
                if try MigrationFileSnapshot.version(currentStoreURL) == nil {
                    try MigrationFileSnapshot.writeExclusive(bytes, to: currentStoreURL)
                } else {
                    let existingBytes = try MigrationFileSnapshot.read(
                        currentStoreURL, limit: MigrationFileSnapshot.maximumStoreBytes)
                    guard MigrationFileSnapshot.digest(existingBytes) == expected else {
                        throw ApplicationMigrationFailure.changed
                    }
                }
            }
            guard try Self.domainsEqual(defaults, expected: original) else {
                throw ApplicationMigrationFailure.changed
            }
            try MigrationFileSnapshot.verifySource(manifest.originalStore, started: started)
            try MigrationFileSnapshot.check(started)
            try writePhase(.active)
        }
        preparationMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        _ = try MigrationFileSnapshot.version(currentStoreURL)
    }

    public func originalPreferencesSnapshot() throws -> Data {
        let values = try originalDomainValues(restorable: true)
        return try Self.envelope(Self.merge(values, order: configuration.legacyDomains))
    }
    public func currentPreferencesSnapshot() throws -> Data {
        try Self.envelope(currentDefaults.persistentDomain(forName: configuration.currentDomain) ?? [:])
    }
    public func currentPreferencesFingerprint() throws -> String {
        try Self.fingerprint(currentDefaults.persistentDomain(forName: configuration.currentDomain) ?? [:])
    }
    public func matchesCurrentPreferencesSnapshot(_ data: Data) throws -> Bool {
        guard data.count <= MigrationFileSnapshot.maximumPreferencesBytes,
            let envelope = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            envelope["format"] as? Int == 1, let values = envelope["values"] as? [String: Any]
        else { throw ApplicationMigrationFailure.invalid }
        return try Self.fingerprint(values) == currentPreferencesFingerprint()
    }
    public static func matchesCurrentPreferencesSnapshot(_ data: Data, configuration: Configuration) throws
        -> Bool
    {
        try validate(configuration)
        let values = try snapshotValues(data)
        guard let current = UserDefaults(suiteName: configuration.currentDomain), current.synchronize() else {
            throw ApplicationMigrationFailure.changed
        }
        return try fingerprint(values)
            == fingerprint(current.persistentDomain(forName: configuration.currentDomain) ?? [:])
    }
    /// Returns the SHA of the supplied immutable backup only after full typed-value
    /// readback. Dictionary serialization order is not a restoration receipt.
    public static func restoreCurrentPreferencesSnapshot(
        _ data: Data, configuration: Configuration, stoppedWriterPID: Int32
    ) throws -> String {
        try validate(configuration)
        let values = try snapshotValues(data)
        guard stoppedWriterPID > 0, stoppedWriterPID != getpid(), kill(stoppedWriterPID, 0) == -1,
            errno == ESRCH,
            let markerData = values[markerKey] as? Data,
            let marker = try? JSONDecoder().decode(Marker.self, from: markerData), marker.format == 2,
            let identity = marker.currentDirectory,
            try MigrationDirectoryIdentity.read(configuration.stateDirectory) == identity,
            let current = UserDefaults(suiteName: configuration.currentDomain)
        else { throw ApplicationMigrationFailure.changed }
        let lock = open(
            configuration.stateDirectory.appending(path: ".application-data.lock").path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { throw ApplicationMigrationFailure.changed }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0, current.synchronize() else {
            throw ApplicationMigrationFailure.changed
        }
        let before = current.persistentDomain(forName: configuration.currentDomain) ?? [:]
        let beforeFingerprint = try fingerprint(before)
        let retained = configuration.stateDirectory.appending(
            path: "retained-current-preferences-" + UUID().uuidString + ".plist")
        try MigrationFileSnapshot.writeExclusive(try envelope(before), to: retained)
        guard
            try fingerprint(current.persistentDomain(forName: configuration.currentDomain) ?? [:])
                == beforeFingerprint
        else {
            throw ApplicationMigrationFailure.changed
        }
        current.setPersistentDomain(values, forName: configuration.currentDomain)
        guard current.synchronize(), try matchesCurrentPreferencesSnapshot(data, configuration: configuration)
        else {
            throw ApplicationMigrationFailure.changed
        }
        return MigrationFileSnapshot.digest(data)
    }

    public func checkpointSnapshot(in directory: URL) throws -> ApplicationStoreSnapshot? {
        let started = ProcessInfo.processInfo.systemUptime
        guard
            try MigrationDirectoryIdentity.read(currentStoreURL.deletingLastPathComponent())
                == currentDirectoryIdentity
        else {
            throw ApplicationMigrationFailure.changed
        }
        guard try MigrationFileSnapshot.version(currentStoreURL) != nil else { return nil }
        try MigrationFileSnapshot.makeDirectory(directory)
        let raw = directory.appending(path: "raw-current")
        let image = try MigrationFileSnapshot.capture(currentStoreURL, into: raw, started: started)
        let output = directory.appending(path: "Repositories.store")
        try MigrationFileSnapshot.databaseBackup(
            from: raw.appending(path: "Repositories.store"), to: output, started: started)
        try MigrationFileSnapshot.verifySource(image, started: started)
        let bytes = try MigrationFileSnapshot.read(output, limit: MigrationFileSnapshot.maximumStoreBytes)
        return ApplicationStoreSnapshot(
            sourceStoreURL: currentStoreURL, storeURL: output,
            sha256: MigrationFileSnapshot.digest(bytes), bytes: bytes.count)
    }

    public func currentStoreBackup(in directory: URL) throws -> ApplicationStoreBackup? {
        let before = try currentStoreFingerprint()
        guard let snapshot = try checkpointSnapshot(in: directory),
            let identity = try MigrationDirectoryIdentity.read(currentStoreURL.deletingLastPathComponent())
        else { return nil }
        let data = try MigrationFileSnapshot.read(
            snapshot.storeURL, limit: MigrationFileSnapshot.maximumStoreBytes)
        guard MigrationFileSnapshot.digest(data) == snapshot.sha256 else {
            throw ApplicationMigrationFailure.changed
        }
        guard try currentStoreFingerprint() == before else { throw ApplicationMigrationFailure.changed }
        return ApplicationStoreBackup(
            sourceStoreURL: currentStoreURL, data: data,
            sha256: snapshot.sha256, directoryIdentity: identity, sourceFingerprint: before)
    }
    public func currentStoreFingerprint() throws -> String {
        try MigrationFileSnapshot.storeFingerprint(currentStoreURL)
    }
    public func matchesCurrentStoreBackup(_ backup: ApplicationStoreBackup) throws -> Bool {
        guard let expected = backup.sourceFingerprint,
            backup.sourceStoreURL.lastPathComponent == currentStoreURL.lastPathComponent,
            MigrationFileSnapshot.canonicalPath(backup.sourceStoreURL.deletingLastPathComponent())
                == MigrationFileSnapshot.canonicalPath(currentStoreURL.deletingLastPathComponent())
        else { return false }
        return try currentStoreFingerprint() == expected
    }

    public static func restoreCurrentStoreBackup(
        _ backup: ApplicationStoreBackup, configuration: Configuration, stoppedWriterPID: Int32
    ) throws -> ApplicationStoreRestoreReceipt {
        try validate(configuration)
        let target = configuration.stateDirectory.appending(path: "Repositories.store")
        let parent = target.deletingLastPathComponent()
        guard backup.sourceStoreURL.lastPathComponent == target.lastPathComponent,
            MigrationFileSnapshot.canonicalPath(backup.sourceStoreURL.deletingLastPathComponent())
                == MigrationFileSnapshot.canonicalPath(parent),
            backup.data.count <= MigrationFileSnapshot.maximumStoreBytes,
            backup.data.prefix(16) == Data("SQLite format 3\0".utf8),
            MigrationFileSnapshot.digest(backup.data) == backup.sha256,
            try MigrationDirectoryIdentity.read(parent) == backup.directoryIdentity,
            stoppedWriterPID > 0, stoppedWriterPID != getpid(), kill(stoppedWriterPID, 0) == -1,
            errno == ESRCH
        else { throw ApplicationMigrationFailure.changed }
        let lock = open(
            parent.appending(path: ".application-data.lock").path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw ApplicationMigrationFailure.changed }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ApplicationMigrationFailure.changed }
        let started = ProcessInfo.processInfo.systemUptime
        let retained = configuration.stateDirectory.appending(path: "retained-current-" + UUID().uuidString)
        let image = try MigrationFileSnapshot.capture(target, into: retained, started: started)
        try MigrationFileSnapshot.verifySource(image, started: started)
        let staged = parent.appending(path: ".restore-" + UUID().uuidString)
        try MigrationFileSnapshot.writeExclusive(backup.data, to: staged)
        var movedSidecars: [(URL, URL)] = []
        let expectedMain = image.files.first { $0.name == "Repositories.store" }
        var installedMain = false
        do {
            for name in ["Repositories.store-wal", "Repositories.store-shm"] {
                if let expected = image.files.first(where: { $0.name == name }) {
                    let source = parent.appending(path: name)
                    guard try MigrationFileSnapshot.version(source) == expected.sourceVersion else {
                        throw ApplicationMigrationFailure.changed
                    }
                    let moved = retained.appending(path: name + ".original-inode")
                    guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, moved.path, UInt32(RENAME_EXCL)) == 0
                    else {
                        throw ApplicationMigrationFailure.changed
                    }
                    movedSidecars.append((source, moved))
                }
            }
            guard try MigrationFileSnapshot.version(target) == expectedMain?.sourceVersion else {
                throw ApplicationMigrationFailure.changed
            }
            let flags = expectedMain == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
            guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, target.path, flags) == 0 else {
                throw ApplicationMigrationFailure.changed
            }
            installedMain = true
            try MigrationFileSnapshot.syncDirectory(parent)
            let installed = try MigrationFileSnapshot.read(
                target, limit: MigrationFileSnapshot.maximumStoreBytes)
            guard MigrationFileSnapshot.digest(installed) == backup.sha256 else {
                throw ApplicationMigrationFailure.changed
            }
            return ApplicationStoreRestoreReceipt(
                retainedStoreDirectory: retained, restoredSHA256: backup.sha256)
        } catch {
            var mainReturned = !installedMain
            if installedMain,
                let data = try? MigrationFileSnapshot.read(
                    target, limit: MigrationFileSnapshot.maximumStoreBytes),
                MigrationFileSnapshot.digest(data) == backup.sha256
            {
                if expectedMain != nil {
                    mainReturned =
                        renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, target.path, UInt32(RENAME_SWAP)) == 0
                } else {
                    mainReturned = unlink(target.path) == 0
                }
            }
            if mainReturned {
                for (source, moved) in movedSidecars.reversed()
                where try MigrationFileSnapshot.version(source) == nil {
                    _ = renameatx_np(AT_FDCWD, moved.path, AT_FDCWD, source.path, UInt32(RENAME_EXCL))
                }
            }
            throw error
        }
    }

    public func prepareOriginalRestore() throws -> OriginalRestorePlan {
        let started = ProcessInfo.processInfo.systemUptime
        try verifyOriginalArchive()
        try MigrationFileSnapshot.verifySource(manifest.originalStore, started: started)
        let original = try originalDomainValues()
        let currentLegacy = try Self.readDomains(defaults, names: configuration.legacyDomains)
        var fingerprints: [String: String] = [:]
        for name in configuration.legacyDomains {
            let before = Self.legacyBusinessValues(original[name] ?? [:])
            let actual = Self.legacyBusinessValues(currentLegacy[name] ?? [:])
            guard try Self.fingerprint(before) == Self.fingerprint(actual) else {
                throw ApplicationMigrationFailure.changed
            }
            fingerprints[name] = try Self.fingerprint(currentLegacy[name] ?? [:])
        }
        return OriginalRestorePlan(
            id: manifest.id,
            currentFingerprint: try Self.fingerprint(
                currentDefaults.persistentDomain(forName: configuration.currentDomain) ?? [:]),
            legacyFingerprints: fingerprints)
    }

    public func restoreOriginalData(_ plan: OriginalRestorePlan) throws {
        guard plan.id == manifest.id,
            try Self.fingerprint(
                currentDefaults.persistentDomain(forName: configuration.currentDomain) ?? [:])
                == plan.currentFingerprint
        else { throw ApplicationMigrationFailure.changed }
        let started = ProcessInfo.processInfo.systemUptime
        try verifyOriginalArchive()
        try MigrationFileSnapshot.verifySource(manifest.originalStore, started: started)
        let original = try originalDomainValues(restorable: true)
        for name in configuration.legacyDomains {
            let actual = defaults.persistentDomain(forName: name) ?? [:]
            guard try Self.fingerprint(actual) == plan.legacyFingerprints[name] else {
                throw ApplicationMigrationFailure.changed
            }
        }
        // DB/WAL/SHM already remain the verified original bytes. Do not replace live
        // SQLite inodes merely to write identical bytes during an explicit downgrade.
        for name in configuration.legacyDomains {
            var restored = defaults.persistentDomain(forName: name) ?? [:]
            for key in restored.keys where Self.isLegacyBusinessKey(key) { restored.removeValue(forKey: key) }
            for (key, value) in original[name] ?? [:] where Self.isLegacyBusinessKey(key) {
                restored[key] = value
            }
            defaults.setPersistentDomain(restored, forName: name)
        }
        guard defaults.synchronize() else { throw ApplicationMigrationFailure.changed }
        try writePhase(.rolledBack)
    }

    public func resumeVersion2() throws {
        guard phase == .rolledBack else { return }
        try verifyOriginalArchive()
        try writePhase(.active)
    }

    private func verifyOriginalArchive() throws {
        let manifestData = try MigrationFileSnapshot.read(
            originalBackupURL.appending(path: "manifest.json"), limit: 256 * 1024)
        guard MigrationFileSnapshot.digest(manifestData) == manifestSHA256 else {
            throw ApplicationMigrationFailure.changed
        }
        _ = try originalDomainValues()
        try MigrationFileSnapshot.verifyArchive(
            manifest.originalStore, directory: originalBackupURL.appending(path: "legacy-store"))
    }
    private func originalDomainValues(restorable: Bool = false) throws -> [String: [String: Any]] {
        var values: [String: [String: Any]] = [:]
        for image in manifest.preferences {
            let data = try MigrationFileSnapshot.read(
                originalBackupURL.appending(path: image.name),
                limit: MigrationFileSnapshot.maximumPreferencesBytes)
            guard MigrationFileSnapshot.digest(data) == image.sha256,
                let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                try Self.fingerprint(dictionary) == image.fingerprint
            else { throw ApplicationMigrationFailure.changed }
            values[image.domain] = restorable ? try Self.restorableValues(dictionary) : dictionary
        }
        return values
    }
    private func writePhase(_ next: Phase) throws {
        var values = currentDefaults.persistentDomain(forName: configuration.currentDomain) ?? [:]
        if let marker = try Self.readMarker(currentDefaults, domain: configuration.currentDomain) {
            guard marker.id == manifest.id, marker.manifestSHA256 == manifestSHA256 else {
                throw ApplicationMigrationFailure.changed
            }
        }
        let directory = try MigrationDirectoryIdentity.read(currentStoreURL.deletingLastPathComponent())
        guard directory != nil else { throw ApplicationMigrationFailure.changed }
        values[Self.markerKey] = try JSONEncoder().encode(
            Marker(id: manifest.id, manifestSHA256: manifestSHA256, phase: next, currentDirectory: directory))
        currentDefaults.setPersistentDomain(values, forName: configuration.currentDomain)
        guard currentDefaults.synchronize(),
            try Self.readMarker(currentDefaults, domain: configuration.currentDomain)?.phase == next
        else {
            throw ApplicationMigrationFailure.changed
        }
        phase = next
        currentDirectoryIdentity = directory
    }

    private static func createArchive(
        _ configuration: Configuration, values: [String: [String: Any]], defaults: UserDefaults,
        started: TimeInterval
    ) throws -> Manifest {
        let finalArchive = configuration.stateDirectory.appending(path: "archive-v1")
        var template = Array(configuration.stateDirectory.appending(path: ".prepare-XXXXXX").path.utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw ApplicationMigrationFailure.changed
        }
        let archive = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        var images: [PreferenceImage] = []
        var total = 0
        for (index, name) in configuration.legacyDomains.enumerated() {
            let dictionary = values[name] ?? [:]
            let data = try PropertyListSerialization.data(
                fromPropertyList: dictionary, format: .binary, options: 0)
            total += data.count
            guard total <= MigrationFileSnapshot.maximumPreferencesBytes else {
                throw ApplicationMigrationFailure.exceeded
            }
            let filename = "preferences-\(index).plist"
            try MigrationFileSnapshot.writeExclusive(data, to: archive.appending(path: filename))
            images.append(
                PreferenceImage(
                    domain: name, name: filename, sha256: MigrationFileSnapshot.digest(data),
                    fingerprint: try fingerprint(dictionary)))
        }
        let raw = archive.appending(path: "legacy-store")
        let image = try MigrationFileSnapshot.capture(
            configuration.legacyStoreURL, into: raw, started: started)
        var normalizedHash: String?
        var normalizedBytes: Int?
        if let source = image.source, !image.files.isEmpty {
            let input = archive.appending(path: "sqlite-input")
            try MigrationFileSnapshot.makeDirectory(input)
            for file in image.files {
                let bytes = try MigrationFileSnapshot.read(
                    raw.appending(path: file.name), limit: MigrationFileSnapshot.maximumStoreBytes)
                try MigrationFileSnapshot.writeExclusive(bytes, to: input.appending(path: file.name))
            }
            let output = archive.appending(path: "normalized.store")
            try MigrationFileSnapshot.databaseBackup(
                from: input.appending(path: source.lastPathComponent), to: output, started: started)
            let bytes = try MigrationFileSnapshot.read(output, limit: MigrationFileSnapshot.maximumStoreBytes)
            normalizedHash = MigrationFileSnapshot.digest(bytes)
            normalizedBytes = bytes.count
        }
        try MigrationFileSnapshot.check(started)
        guard try domainsEqual(defaults, expected: values) else { throw ApplicationMigrationFailure.changed }
        try MigrationFileSnapshot.verifySource(image, started: started)
        let result = Manifest(
            format: 2, id: UUID(), configuration: configuration, preferences: images,
            originalStore: image, normalizedStoreSHA256: normalizedHash, normalizedStoreBytes: normalizedBytes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try MigrationFileSnapshot.writeExclusive(
            try encoder.encode(result), to: archive.appending(path: "manifest.json"))
        guard renameatx_np(AT_FDCWD, archive.path, AT_FDCWD, finalArchive.path, UInt32(RENAME_EXCL)) == 0
        else {
            throw ApplicationMigrationFailure.changed
        }
        try MigrationFileSnapshot.syncDirectory(configuration.stateDirectory)
        return result
    }
    private static func readDomains(_ defaults: UserDefaults, names: [String]) throws -> [String: [String:
        Any]]
    {
        guard defaults.synchronize() else { throw ApplicationMigrationFailure.changed }
        var result: [String: [String: Any]] = [:]
        var bytes = 0
        for name in names {
            let values = defaults.persistentDomain(forName: name) ?? [:]
            bytes += try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
                .count
            guard bytes <= MigrationFileSnapshot.maximumPreferencesBytes else {
                throw ApplicationMigrationFailure.exceeded
            }
            result[name] = values
        }
        return result
    }
    private static func domainsEqual(_ defaults: UserDefaults, expected: [String: [String: Any]]) throws
        -> Bool
    {
        let current = try readDomains(defaults, names: Array(expected.keys))
        return try expected.allSatisfy { try fingerprint($0.value) == fingerprint(current[$0.key] ?? [:]) }
    }
    private static func merge(_ values: [String: [String: Any]], order: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        for domain in order {
            for (key, value) in values[domain] ?? [:] where result[key] == nil { result[key] = value }
        }
        return result
    }
    private static func readMarker(_ defaults: UserDefaults, domain: String) throws -> Marker? {
        guard let value = defaults.persistentDomain(forName: domain)?[markerKey] else { return nil }
        guard let data = value as? Data, data.count <= 4096,
            let marker = try? JSONDecoder().decode(Marker.self, from: data), marker.format == 2
        else { throw ApplicationMigrationFailure.invalid }
        return marker
    }
    private static func validate(_ configuration: Configuration) throws {
        let names = configuration.legacyDomains + [configuration.currentDomain]
        guard (1...4).contains(configuration.legacyDomains.count), Set(names).count == names.count,
            names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 && !$0.contains("\0") }),
            !names.contains(UserDefaults.globalDomain), !names.contains(UserDefaults.argumentDomain),
            !names.contains(UserDefaults.registrationDomain),
            configuration.stateDirectory.isFileURL, configuration.stateDirectory.path.utf8.count <= 4096,
            !configuration.stateDirectory.path.contains("\0"),
            configuration.legacyStoreURL?.isFileURL != false,
            configuration.legacyStoreURL?.lastPathComponent.contains("/") != true,
            configuration.legacyStoreURL?.path.contains("\0") != true,
            configuration.legacyStoreURL?.path
                != configuration.stateDirectory.appending(path: "Repositories.store").path
        else { throw ApplicationMigrationFailure.invalid }
    }
    private static func envelope(_ values: [String: Any]) throws -> Data {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["format": 1, "values": values], format: .binary, options: 0)
        guard data.count <= MigrationFileSnapshot.maximumPreferencesBytes else {
            throw ApplicationMigrationFailure.exceeded
        }
        return data
    }
    private static func snapshotValues(_ data: Data) throws -> [String: Any] {
        guard data.count <= MigrationFileSnapshot.maximumPreferencesBytes,
            let image = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            image["format"] as? Int == 1, let values = image["values"] as? [String: Any]
        else { throw ApplicationMigrationFailure.invalid }
        return values
    }
    private static func restorableValues(_ values: [String: Any]) throws -> [String: Any] {
        guard let raw = values["v2.original-preferences"] else { return values }
        guard let data = raw as? Data, let expected = values["v2.original-preferences.sha256"] as? String,
            MigrationFileSnapshot.digest(data) == expected,
            let backup = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            backup["format"] as? Int == 1, let original = backup["values"] as? [String: Any]
        else { throw ApplicationMigrationFailure.invalid }
        return original
    }
    private static func legacyBusinessValues(_ values: [String: Any]) -> [String: Any] {
        values.filter { isLegacyBusinessKey($0.key) }
    }
    private static func isLegacyBusinessKey(_ key: String) -> Bool {
        [
            "language", "AppleLanguages", "appearance", "customTheme", "interfaceMotion", "showMenuBar",
            "codeSize", "codeFont",
            "density", "showFileIcons", "defaultDirectory", "restoreRepository", "restoreWindow",
            "confirmRepositorySwitch", "saveDrafts",
            "defaultSplitDiff", "defaultIgnoreWhitespace", "defaultContextLines", "defaultWordDiff",
            "showLineNumbers", "showWhitespace",
            "activityLimit", "activityHours", "gitExecutable", "lastRepository", "lastRepositoryBookmark",
            "settingsTab",
            "bundleNamespaceMigration.v1",
        ].contains(key)
            || key.hasPrefix("draft:") || key.hasPrefix("draft-v2:") || key.hasPrefix("workspace:")
            || key == "NSWindow Frame WeGit.main"
            || key.hasPrefix("NSSplitView Subview Frames WeGit.columns.")
    }

    private struct CanonicalValue: Encodable {
        let kind: String
        let value: String?
        let entries: [CanonicalEntry]?
        let items: [CanonicalValue]?
    }
    private struct CanonicalEntry: Encodable {
        let key: String
        let value: CanonicalValue
    }
    private static func fingerprint(_ values: [String: Any]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return MigrationFileSnapshot.digest(try encoder.encode(canonical(values, depth: 0)))
    }
    private static func canonical(_ value: Any, depth: Int) throws -> CanonicalValue {
        guard depth <= 32 else { throw ApplicationMigrationFailure.exceeded }
        if let data = value as? Data {
            return CanonicalValue(kind: "data", value: data.base64EncodedString(), entries: nil, items: nil)
        }
        if let date = value as? Date {
            return CanonicalValue(
                kind: "date", value: String(date.timeIntervalSince1970.bitPattern), entries: nil, items: nil)
        }
        if let number = value as? NSNumber {
            let kind: String
            let encoded: String
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                kind = "bool"
                encoded = number.boolValue ? "1" : "0"
            } else if ["d", "f"].contains(String(cString: number.objCType)) {
                kind = "real"
                encoded = String(number.doubleValue.bitPattern)
            } else {
                kind = "integer"
                encoded = number.stringValue
            }
            return CanonicalValue(kind: kind, value: encoded, entries: nil, items: nil)
        }
        if let string = value as? String {
            return CanonicalValue(kind: "string", value: string, entries: nil, items: nil)
        }
        if let values = value as? [String: Any] {
            return CanonicalValue(
                kind: "dictionary", value: nil,
                entries: try values.keys.sorted().map {
                    CanonicalEntry(key: $0, value: try canonical(values[$0]!, depth: depth + 1))
                }, items: nil)
        }
        if let values = value as? [Any] {
            return CanonicalValue(
                kind: "array", value: nil, entries: nil,
                items: try values.map { try canonical($0, depth: depth + 1) })
        }
        throw ApplicationMigrationFailure.invalid
    }
}

private final class MigrationDataLock: @unchecked Sendable {
    let descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }
}
