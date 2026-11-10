import AppKit
import CryptoKit
import Darwin
import Foundation
import WeGitCore

/// The application stages and saves data. The independent installer owns replacement.
@MainActor final class UpdateApplicationBridge {
    private weak var app: AppState?
    private var helper: Process?
    private var ticket: UpdateHandoffTicket?
    private var generation: UInt64?
    private var preferenceFingerprint: String?
    private var storeFingerprint: String?

    init(app: AppState) { self.app = app }

    func permitsNormalExit() -> Bool {
        guard let app, app.runtime.updateExitAuthorized,
            generation == app.runtime.persistenceGeneration,
            let preferenceFingerprint, !app.runtime.hasOperations,
            (try? app.migrationState?.storage.currentPreferencesFingerprint()) == preferenceFingerprint,
            let storeFingerprint, (try? app.migrationState?.currentStoreFingerprint()) == storeFingerprint
        else { return false }
        return true
    }

    func install(_ request: UpdateInstallRequest) async throws {
        guard let app, !app.runtime.updateHandoffInProgress, !app.runtime.hasOperations,
            app.runtime.liveStates.allSatisfy(\.readyForUpdate),
            let migration = app.migrationState, migration.canUseVersion2,
            Bundle.main.bundleIdentifier == "com.willxue.wegit",
            UpdateTrustConfiguration.isConfigured,
            !NSApp.windows.contains(where: {
                $0.isVisible
                    && ($0.sheetParent != nil || $0.attachedSheet != nil
                        || $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window")
            }),
            !NSWorkspace.shared.runningApplications.contains(where: {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != getpid()
            })
        else { throw UpdateFailure.busy }
        try app.flushPersistentState()
        guard app.runtime.windowCoordinator?.saveAllWindows(forceForUpdate: true) == true else {
            throw UpdateFailure.busy
        }
        let stage = try TransientUpdateStage(target: Bundle.main.bundleURL)
        app.runtime.updateHandoffInProgress = true
        app.runtime.updateExitAuthorized = false
        for session in app.runtime.sessions.values { session.suspendForUpdate(true) }
        var transferred = false
        do {
            try await request.download.validate()
            try await stage.mount(request.download.url)
            try await stage.copyApplication()
            let snapshotGeneration = app.runtime.persistenceGeneration
            let snapshotFingerprint = try migration.storage.currentPreferencesFingerprint()
            let snapshotStoreFingerprint = try migration.currentStoreFingerprint()
            let currentStore = try await stage.captureStoreBackup(using: migration.storage)
            let currentPreferences = try migration.currentPreferencesSnapshot()
            guard snapshotGeneration == app.runtime.persistenceGeneration,
                snapshotFingerprint == (try migration.storage.currentPreferencesFingerprint()),
                snapshotStoreFingerprint == (try migration.currentStoreFingerprint()),
                try migration.storage.matchesCurrentPreferencesSnapshot(currentPreferences)
            else { throw UpdateFailure.changed }
            let backup = try UpdateDataBackup(
                originalPreferences: migration.originalPreferencesSnapshot(),
                currentPreferences: currentPreferences,
                currentStoreBackup: currentStore)
            let windows = Set(app.runtime.liveStates.filter(\.mainWorkspaceMounted).map(\.windowID))
            let persisted = Set(
                (app.runtime.persistence?.windows ?? []).filter { windows.contains($0.id) }.map(\.id))
            let activity = UpdateInstallationActivity(
                busyTasks: 0, windowIDs: windows, persistedWindowIDs: persisted,
                persistenceFlushed: app.defaults.synchronize(), generation: app.runtime.persistenceGeneration)
            try await stage.captureCleanupCandidate()
            let plan = try await UpdateInstaller.preflight(
                currentApp: Bundle.main.bundleURL,
                replacementApp: stage.replacement, update: request.update,
                packageManifest: request.packageManifest,
                dataBackup: backup, activity: activity)
            try stage.authorizeCleanup()
            let prepared = try await ProductionUpdateInstaller.prepare(
                plan: plan, download: request.download,
                preferencesDomain: migration.storage.configuration.currentDomain)
            ticket = prepared
            try await stage.authorizeStoreCleanup(afterTransferring: currentStore)
            generation = snapshotGeneration
            preferenceFingerprint = snapshotFingerprint
            storeFingerprint = snapshotStoreFingerprint
            guard generation == app.runtime.persistenceGeneration,
                preferenceFingerprint == (try migration.storage.currentPreferencesFingerprint()),
                storeFingerprint == (try migration.currentStoreFingerprint())
            else { throw UpdateFailure.changed }
            try await stage.finishAndRemove()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: prepared.directory).appending(
                path: "Installer/Helpers/WeGitUpdater")
            process.arguments = ["--ticket", prepared.ticketURL.path]
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            helper = process
            try input.fileHandleForWriting.write(contentsOf: Data((prepared.token + "\n").utf8))
            try input.fileHandleForWriting.close()
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let ready = try await ProductionUpdateInstaller.readHelperReady(ticket: prepared) {
                    guard ready.helper.pid == process.processIdentifier,
                        ready.source == (try UpdateProcessIdentity.capture()),
                        generation == app.runtime.persistenceGeneration,
                        preferenceFingerprint == (try migration.storage.currentPreferencesFingerprint()),
                        storeFingerprint == (try migration.currentStoreFingerprint())
                    else { throw UpdateFailure.changed }
                    transferred = true
                    app.runtime.updateExitAuthorized = true
                    DispatchQueue.main.async { [weak self] in
                        NSApp.terminate(nil)
                        guard let self, self.app?.runtime.updateTerminationApproved != true else { return }
                        Task { @MainActor in
                            _ = await self.abortAndResume(reason: UpdateFailure.busy.localizedDescription)
                            self.app?.runtime.services.updates?.installerHandoffFailed(
                                UpdateFailure.busy.localizedDescription)
                        }
                    }
                    return
                }
                guard process.isRunning else { throw UpdateFailure.installation }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw UpdateFailure.busy
        } catch {
            try? await stage.finishAndRemove()
            if !transferred { _ = await abortAndResume(reason: error.localizedDescription) }
            throw error
        }
    }

    private func abortAndResume(reason: String) async -> Bool {
        var safeToResume = helper?.isRunning != true
        if let ticket {
            if safeToResume {
                _ = try? await ProductionUpdateInstaller.abortPrepared(ticket: ticket, reason: reason)
            } else {
                try? await ProductionUpdateInstaller.writeSourceAbort(ticket: ticket, reason: reason)
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while ProcessInfo.processInfo.systemUptime < deadline {
                    let aborted = try? await ProductionUpdateInstaller.readHelperAbort(ticket: ticket)
                    if helper?.isRunning != true || aborted != nil {
                        safeToResume = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        if safeToResume { releaseFreeze() }
        return safeToResume
    }

    private func releaseFreeze() {
        guard let app else { return }
        app.runtime.updateExitAuthorized = false
        app.runtime.updateTerminationApproved = false
        app.runtime.updateHandoffInProgress = false
        for session in app.runtime.sessions.values { session.suspendForUpdate(false) }
        ticket = nil
        generation = nil
        preferenceFingerprint = nil
        storeFingerprint = nil
        helper = nil
    }

    func reportStartupReadiness(ticketURL: URL) async throws {
        guard let app, let migration = app.migrationState, migration.canUseVersion2 else {
            throw UpdateFailure.busy
        }
        let ticket = try ProductionUpdateInstaller.loadTicket(at: ticketURL)
        try await ProductionUpdateInstaller.validateLaunchTicket(
            ticket: ticket,
            trustedKeyRing: UpdateTrustConfiguration.productionRing())
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !app.runtime.liveStates.allSatisfy(\.readyForUpdate),
            ProcessInfo.processInfo.systemUptime < deadline
        {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard app.runtime.liveStates.allSatisfy(\.readyForUpdate) else { throw UpdateFailure.busy }
        try app.flushPersistentState()
        guard app.runtime.windowCoordinator?.saveAllWindows(forceForUpdate: true) == true else {
            throw UpdateFailure.busy
        }
        _ = try await ProductionUpdateInstaller.writeReadiness(
            ticket: ticket,
            trustedKeyRing: UpdateTrustConfiguration.productionRing(), migrationCompleted: true,
            windowsRestored: true, preferencesFlushed: app.defaults.synchronize())
    }
}

/// A fresh transient directory is removed only after its complete byte map is sealed.
@MainActor private final class TransientUpdateStage {
    let root: URL
    var replacement: URL { root.appending(path: "Replacement.app") }
    var storeSnapshotDirectory: URL { root.appending(path: "StoreSnapshot") }
    private var mounted = false
    private var ownedBytes: [String: String]?
    private var cleanupCandidate: [String: String]?
    private var storeCapture: TransientStoreCapture?
    private var storeCleanupAuthorized = false
    private let inode: UInt64
    private let device: Int32
    init(target: URL) throws {
        let parent = target.resolvingSymlinksInPath().deletingLastPathComponent()
        let retained = try FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix(".WeGit-stage-") }
        guard retained.count < 10 else { throw UpdateFailure.exceeded }
        root = parent.appending(path: ".WeGit-stage-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var value = stat()
        guard lstat(root.path, &value) == 0, value.st_uid == getuid(), value.st_mode & 0o077 == 0 else {
            throw UpdateFailure.changed
        }
        inode = value.st_ino
        device = value.st_dev
    }
    func mount(_ download: URL) async throws {
        let mount = root.appending(path: "Mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        _ = try await Self.command(
            "/usr/bin/hdiutil",
            ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, download.path])
        mounted = true
    }
    func copyApplication() async throws {
        let source = root.appending(path: "Mount/WeGit.app")
        _ = try await Self.command("/usr/bin/ditto", [source.path, replacement.path])
    }
    func finishAndRemove() async throws {
        if mounted {
            _ = try await Self.command("/usr/bin/hdiutil", ["detach", root.appending(path: "Mount").path])
            mounted = false
        }
        var value = stat()
        guard lstat(root.path, &value) == 0, value.st_ino == inode, value.st_dev == device,
            value.st_uid == getuid(), value.st_mode & 0o077 == 0
        else { return }
        guard let ownedBytes, try byteMap() == ownedBytes else { return }
        if let storeCapture, storeCleanupAuthorized {
            try await TransientStoreCapture.perform { try storeCapture.validate() }
        }
        guard lstat(root.path, &value) == 0, value.st_ino == inode, value.st_dev == device,
            value.st_mode & S_IFMT == S_IFDIR
        else { throw UpdateFailure.changed }
        if FileManager.default.fileExists(atPath: replacement.path) {
            try FileManager.default.removeItem(at: replacement)
        }
        let mount = root.appending(path: "Mount")
        if FileManager.default.fileExists(atPath: mount.path) {
            try FileManager.default.removeItem(at: mount)
        }
        if let storeCapture, storeCleanupAuthorized {
            try await TransientStoreCapture.perform { try storeCapture.remove() }
        }
        // Failed captures and snapshots not durably transferred remain here.
        if try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty {
            guard lstat(root.path, &value) == 0, value.st_ino == inode, value.st_dev == device,
                value.st_mode & S_IFMT == S_IFDIR, rmdir(root.path) == 0
            else { throw UpdateFailure.changed }
        }
    }
    func captureStoreBackup(using migration: ApplicationDataMigration) async throws -> ApplicationStoreBackup?
    {
        var value = stat()
        guard lstat(root.path, &value) == 0, value.st_ino == inode, value.st_dev == device,
            value.st_mode & S_IFMT == S_IFDIR, storeCapture == nil,
            lstat(storeSnapshotDirectory.path, &value) != 0, errno == ENOENT
        else { throw UpdateFailure.changed }
        let backup = try migration.currentStoreBackup(in: storeSnapshotDirectory)
        if let backup {
            let root = root
            let inode = inode
            let device = device
            storeCapture = try await TransientStoreCapture.perform {
                try TransientStoreCapture(root: root, inode: inode, device: device, backup: backup)
            }
        }
        return backup
    }
    /// Called only after prepare has fsynced the independent installer's copy.
    /// App preflight alone never grants ownership of database capture files.
    func authorizeStoreCleanup(afterTransferring backup: ApplicationStoreBackup?) async throws {
        guard let storeCapture else {
            guard backup == nil else { throw UpdateFailure.changed }
            return
        }
        guard let backup, backup.sha256 == storeCapture.backupSHA256,
            backup.bytes == storeCapture.backupBytes
        else { throw UpdateFailure.changed }
        try await TransientStoreCapture.perform { try storeCapture.validate() }
        storeCleanupAuthorized = true
    }
    func captureCleanupCandidate() async throws {
        if mounted {
            _ = try await Self.command("/usr/bin/hdiutil", ["detach", root.appending(path: "Mount").path])
            mounted = false
        }
        cleanupCandidate = try byteMap()
    }
    func authorizeCleanup() throws {
        guard let cleanupCandidate, try byteMap() == cleanupCandidate else { throw UpdateFailure.changed }
        ownedBytes = cleanupCandidate
    }
    private func byteMap() throws -> [String: String] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { throw UpdateFailure.changed }
        var values: [String: String] = [:]
        var bytes = 0
        for case let url as URL in enumerator {
            let path = String(url.path.dropFirst(root.path.count + 1))
            if path == "StoreSnapshot" {
                enumerator.skipDescendants()
                continue
            }
            guard values.count < 20_000,
                path == "Mount" || path == "Replacement.app" || path.hasPrefix("Replacement.app/")
            else { throw UpdateFailure.changed }
            let attributes = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if attributes.isSymbolicLink == true {
                values[path] = "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            } else if attributes.isDirectory == true {
                values[path] = "directory"
            } else {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
                guard size >= 0, size <= 64 * 1024 * 1024, bytes <= 256 * 1024 * 1024 - size else {
                    throw UpdateFailure.exceeded
                }
                bytes += size
                values[path] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }
                    .joined()
            }
        }
        return values
    }
    private static func command(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
        let request = ProcessRequest(
            executable: URL(fileURLWithPath: executable), arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin"], timeout: 15, outputLimit: 256 * 1024)
        let result = try await ProcessRunner().run(request)
        guard result.exitCode == 0 else { throw UpdateFailure.installation }
        return result
    }
}

/// Owns only the bounded files produced by one successful database capture.
/// Pinned descriptors and exact file versions prevent following replaced paths;
/// cleanup unlinks known leaves and empty directories, never a recursive tree.
private final class TransientStoreCapture: @unchecked Sendable {
    private struct Version: Equatable {
        let device: Int32
        let inode: UInt64
        let mode: UInt16
        let owner: uid_t
        let bytes: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let bornSeconds: Int64
        let bornNanoseconds: Int64
        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            mode = value.st_mode
            owner = value.st_uid
            bytes = value.st_size
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
            bornSeconds = Int64(value.st_birthtimespec.tv_sec)
            bornNanoseconds = Int64(value.st_birthtimespec.tv_nsec)
        }
        func sameDirectory(_ other: Self) -> Bool {
            device == other.device && inode == other.inode && mode == other.mode && owner == other.owner
                && bornSeconds == other.bornSeconds && bornNanoseconds == other.bornNanoseconds
        }
    }
    private struct File: Equatable {
        let version: Version
        let sha256: String
    }
    let backupSHA256: String
    let backupBytes: Int
    private let root: URL
    private let rootFD: Int32
    private let storeFD: Int32
    private let rawFD: Int32
    private let rootVersion: Version
    private let storeVersion: Version
    private let rawVersion: Version
    private let rawFiles: [String: File]
    private let normalized: File

    init(root: URL, inode: UInt64, device: Int32, backup: ApplicationStoreBackup) throws {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let rootFD = open(root.path, flags)
        guard rootFD >= 0 else { throw UpdateFailure.changed }
        let storeFD = openat(rootFD, "StoreSnapshot", flags)
        guard storeFD >= 0 else {
            close(rootFD)
            throw UpdateFailure.changed
        }
        let rawFD = openat(storeFD, "raw-current", flags)
        guard rawFD >= 0 else {
            close(storeFD)
            close(rootFD)
            throw UpdateFailure.changed
        }
        do {
            let rootVersion = try Self.version(rootFD)
            guard rootVersion.inode == inode, rootVersion.device == device else {
                throw UpdateFailure.changed
            }
            let storeVersion = try Self.version(storeFD)
            let rawVersion = try Self.version(rawFD)
            for directory in [rootVersion, storeVersion, rawVersion] {
                guard directory.mode & S_IFMT == S_IFDIR, directory.owner == getuid(),
                    directory.mode & 0o077 == 0
                else { throw UpdateFailure.changed }
            }
            guard try Self.names(storeFD) == ["Repositories.store", "raw-current"] else {
                throw UpdateFailure.changed
            }
            let names = try Self.names(rawFD)
            guard names.contains("Repositories.store"),
                names.isSubset(of: ["Repositories.store", "Repositories.store-wal", "Repositories.store-shm"])
            else { throw UpdateFailure.changed }
            var files: [String: File] = [:]
            var total: Int64 = 0
            for name in names {
                let file = try Self.read(rawFD, name)
                total += file.version.bytes
                guard total <= 64 * 1024 * 1024 else { throw UpdateFailure.exceeded }
                files[name] = file
            }
            let normalized = try Self.read(storeFD, "Repositories.store")
            guard normalized.sha256 == backup.sha256, normalized.version.bytes == backup.bytes else {
                throw UpdateFailure.changed
            }
            guard try Self.at(AT_FDCWD, root.path).sameDirectory(rootVersion),
                try Self.at(rootFD, "StoreSnapshot").sameDirectory(storeVersion),
                try Self.at(storeFD, "raw-current").sameDirectory(rawVersion)
            else { throw UpdateFailure.changed }
            backupSHA256 = backup.sha256
            backupBytes = backup.bytes
            self.root = root
            self.rootFD = rootFD
            self.storeFD = storeFD
            self.rawFD = rawFD
            self.rootVersion = rootVersion
            self.storeVersion = storeVersion
            self.rawVersion = rawVersion
            rawFiles = files
            self.normalized = normalized
        } catch {
            close(rawFD)
            close(storeFD)
            close(rootFD)
            throw error
        }
    }
    deinit {
        close(rawFD)
        close(storeFD)
        close(rootFD)
    }

    static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    func validate() throws {
        try Task.checkCancellation()
        guard try Self.at(AT_FDCWD, root.path).sameDirectory(rootVersion),
            try Self.at(rootFD, "StoreSnapshot").sameDirectory(storeVersion),
            try Self.at(storeFD, "raw-current").sameDirectory(rawVersion),
            try Self.names(storeFD) == ["Repositories.store", "raw-current"],
            try Self.names(rawFD) == Set(rawFiles.keys),
            try Self.read(storeFD, "Repositories.store") == normalized
        else { throw UpdateFailure.changed }
        for (name, expected) in rawFiles {
            guard try Self.read(rawFD, name) == expected else { throw UpdateFailure.changed }
        }
        guard try Self.at(AT_FDCWD, root.path).sameDirectory(rootVersion),
            try Self.at(rootFD, "StoreSnapshot").sameDirectory(storeVersion),
            try Self.at(storeFD, "raw-current").sameDirectory(rawVersion)
        else { throw UpdateFailure.changed }
    }
    func remove() throws {
        try validate()
        for (name, file) in rawFiles {
            try Task.checkCancellation()
            guard try Self.at(rawFD, name) == file.version, unlinkat(rawFD, name, 0) == 0 else {
                throw UpdateFailure.changed
            }
        }
        guard try Self.at(storeFD, "Repositories.store") == normalized.version,
            unlinkat(storeFD, "Repositories.store", 0) == 0,
            try Self.at(storeFD, "raw-current").sameDirectory(rawVersion),
            unlinkat(storeFD, "raw-current", AT_REMOVEDIR) == 0,
            try Self.at(rootFD, "StoreSnapshot").sameDirectory(storeVersion),
            unlinkat(rootFD, "StoreSnapshot", AT_REMOVEDIR) == 0
        else { throw UpdateFailure.changed }
    }
    private static func version(_ descriptor: Int32) throws -> Version {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw UpdateFailure.changed }
        return Version(value)
    }
    private static func at(_ descriptor: Int32, _ name: String) throws -> Version {
        var value = stat()
        guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw UpdateFailure.changed }
        return Version(value)
    }
    private static func names(_ descriptor: Int32) throws -> Set<String> {
        // dup shares the directory offset; rewind before every bounded scan.
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw UpdateFailure.changed }
        guard let directory = fdopendir(duplicate) else {
            close(duplicate)
            throw UpdateFailure.changed
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: Set<String> = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw UpdateFailure.changed }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < 3 else { throw UpdateFailure.changed }
            result.insert(name)
        }
        return result
    }
    private static func read(_ descriptor: Int32, _ name: String) throws -> File {
        let expected = try at(descriptor, name)
        guard expected.mode & S_IFMT == S_IFREG, expected.owner == getuid(),
            expected.bytes >= 0, expected.bytes <= 64 * 1024 * 1024
        else { throw UpdateFailure.changed }
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw UpdateFailure.changed }
        defer { close(file) }
        guard try version(file) == expected else { throw UpdateFailure.changed }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw UpdateFailure.changed }
            if count == 0 { break }
            total += Int64(count)
            guard total <= expected.bytes else { throw UpdateFailure.changed }
            hash.update(data: Data(buffer.prefix(count)))
        }
        guard total == expected.bytes, try version(file) == expected, try at(descriptor, name) == expected
        else {
            throw UpdateFailure.changed
        }
        return File(version: expected, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
