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
            let currentStore = try migration.currentStoreBackup(in: stage.storeSnapshotDirectory)
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
        if FileManager.default.fileExists(atPath: replacement.path) {
            try FileManager.default.removeItem(at: replacement)
        }
        let mount = root.appending(path: "Mount")
        if FileManager.default.fileExists(atPath: mount.path) {
            try FileManager.default.removeItem(at: mount)
        }
        // Database capture files are retained independently; unknown inputs in
        // this namespace never acquire cleanup ownership from app preflight.
        if try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty {
            try FileManager.default.removeItem(at: root)
        }
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
