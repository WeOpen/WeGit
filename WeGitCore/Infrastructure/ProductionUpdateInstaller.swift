import CryptoKit
import Darwin
import Foundation
import Security

final class UpdateTransactionLease: @unchecked Sendable {
    let descriptor: Int32
    init(directory: URL) throws {
        descriptor = open(
            directory.appending(path: "lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UpdateFailure.changed }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            info.st_uid == getuid(), info.st_mode & 0o077 == 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            close(descriptor)
            throw UpdateFailure.busy
        }
    }
    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum ProductionUpdateInstaller {
    public static func loadTicket(at url: URL, token: String? = nil) throws -> UpdateHandoffTicket {
        let parent = try UpdateInstallationSandbox.canonical(url.deletingLastPathComponent())
        let path = parent.appending(path: "ticket.json")
        guard url.lastPathComponent == "ticket.json", try privateDirectory(parent),
            try UpdateNodeIdentity.read(path).permissions == 0o600
        else { throw UpdateFailure.changed }
        let ticket = try JSONDecoder().decode(
            UpdateHandoffTicket.self, from: UpdateInstaller.readSmall(path, limit: 16 * 1024))
        guard ticket.directory == parent.path, ticket.token.utf8.count == 64,
            UpdateManifestValidator.matches(ticket.token, #"^[0-9a-f]{64}$"#),
            UpdateManifestValidator.matches(ticket.documentSHA256, #"^[0-9a-f]{64}$"#),
            token == nil || token == ticket.token,
            parent.lastPathComponent == ".WeGit-update-" + ticket.id.uuidString
        else { throw UpdateFailure.changed }
        return ticket
    }

    /// Takes durable ownership of copied stage/archive/preferences. The original
    /// stage and Diff download may be released as soon as this call returns.
    public static func prepare(
        plan: UpdateInstallPlan, download: UpdateDownload,
        preferencesDomain: String = "com.willxue.wegit.v2", scope: UpdateHandoffScope = .production,
        originalProcess: UpdateProcessIdentity? = nil
    ) async throws -> UpdateHandoffTicket {
        try plan.activity.validate()
        try await download.validate()
        guard download.sha256 == plan.update.artifact.sha256,
            download.byteCount == plan.update.artifact.downloadBytes,
            Date() < plan.update.expiresAt
        else { throw UpdateFailure.changed }
        let source = try originalProcess ?? UpdateProcessIdentity.capture()
        guard source.executable == plan.currentApp.appending(path: "Contents/MacOS/WeGit").path,
            scope != .production || source.pid == getpid(),
            !preferencesDomain.isEmpty, preferencesDomain.utf8.count <= 256,
            scope != .production || preferencesDomain == "com.willxue.wegit.v2",
            scope != .isolatedControl || preferencesDomain.hasPrefix("com.willxue.wegit.UITests.")
        else { throw UpdateFailure.changed }
        return try await SnapshotIO.run { cancellation in
            let parent = plan.currentApp.deletingLastPathComponent()
            try validateScope(scope, target: plan.currentApp)
            if scope == .production {
                guard
                    let support = FileManager.default.urls(
                        for: .applicationSupportDirectory, in: .userDomainMask
                    ).first
                else {
                    throw UpdateFailure.configurationMissing
                }
                let configuration = try ApplicationDataMigration.Configuration.standard(
                    applicationSupportDirectory: support, applicationIdentifier: "com.willxue.wegit")
                let storeURL = configuration.stateDirectory.appending(path: "Repositories.store")
                if FileManager.default.fileExists(atPath: storeURL.path) {
                    guard let store = plan.backup.currentStoreBackup,
                        store.sourceStoreURL.path == storeURL.path
                    else {
                        throw UpdateFailure.configurationMissing
                    }
                }
            }
            guard try RepositoryNodeIdentity.read(parent, directory: true) == plan.parent,
                try UpdateAppTree.read(plan.currentApp, cancellation: cancellation) == plan.oldTree,
                try UpdateAppTree.read(plan.replacementApp, cancellation: cancellation) == plan.newTree
            else { throw UpdateFailure.changed }
            let helperPath = plan.currentApp.appending(path: "Contents/Helpers/WeGitUpdater")
            let resourcePath = plan.currentApp.appending(path: "Contents/Resources/WeGit_WeGitCore.bundle")
            guard let helperFile = plan.oldTree.files["Contents/Helpers/WeGitUpdater"],
                let helperBytes = helperFile.identity.markerSize
            else { throw UpdateFailure.configurationMissing }
            let originalResources = try fingerprint(resourcePath, cancellation)
            let required =
                plan.requiredBytes + download.byteCount + helperBytes + originalResources.bytes + 1024 * 1024
            try availableSpace(parent, required: required)
            try retainedCapacity(parent, proposed: required)
            let directory = parent.appending(path: ".WeGit-update-" + plan.id.uuidString)
            guard mkdir(directory.path, 0o700) == 0 else { throw UpdateFailure.changed }
            let lease = try UpdateTransactionLease(directory: directory)
            _ = lease
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw UpdateFailure.changed
            }
            let token = random.map { String(format: "%02x", $0) }.joined()
            let stage = directory.appending(path: "Replacement.app")
            try FileManager.default.copyItem(at: plan.replacementApp, to: stage)
            try cancellation.check()
            let newTree = try UpdateAppTree.read(stage, cancellation: cancellation)
            try UpdateInstaller.verifySignature(stage)
            // Source package metadata remains authenticated by the signed update.
            try UpdateInstaller.validatePackage(
                plan.packageManifest, tree: newTree, app: stage, update: plan.update)
            let old = try UpdateAppFingerprint.capture(plan.currentApp, cancellation: cancellation)
            let new = try UpdateAppFingerprint.capture(stage, cancellation: cancellation)
            let sourceNew = try UpdateAppFingerprint.capture(plan.replacementApp, cancellation: cancellation)
            guard new.contentSHA256 == sourceNew.contentSHA256, newTree.bytes == plan.newTree.bytes else {
                throw UpdateFailure.changed
            }
            let helperDirectory = directory.appending(path: "Installer/Helpers")
            let resourcesDirectory = directory.appending(path: "Installer/Resources")
            try FileManager.default.createDirectory(
                at: helperDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                at: resourcesDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let copiedHelper = helperDirectory.appending(path: "WeGitUpdater")
            try copyFile(
                helperPath, to: copiedHelper, bytes: helperBytes, checksum: helperFile.hash,
                cancellation: cancellation)
            guard chmod(copiedHelper.path, mode_t(helperFile.mode)) == 0 else { throw UpdateFailure.changed }
            try UpdateInstaller.verifySignature(copiedHelper)
            let copiedResources = resourcesDirectory.appending(path: "WeGit_WeGitCore.bundle")
            try FileManager.default.copyItem(at: resourcePath, to: copiedResources)
            let resources = try fingerprint(copiedResources, cancellation)
            guard resources.contentSHA256 == originalResources.contentSHA256 else {
                throw UpdateFailure.changed
            }
            try syncTree(copiedResources, cancellation: cancellation)
            try UpdateInstaller.sync(helperDirectory)
            try UpdateInstaller.sync(resourcesDirectory)
            try UpdateInstaller.sync(directory.appending(path: "Installer"))
            let archiveURL = directory.appending(path: "archive.dmg")
            try copyFile(
                download.url, to: archiveURL, bytes: download.byteCount, checksum: download.sha256,
                cancellation: cancellation)
            let original = directory.appending(path: "original-preferences.plist")
            let current = directory.appending(path: "current-preferences.plist")
            try UpdateInstaller.exclusiveWrite(plan.backup.originalPreferences, to: original)
            try UpdateInstaller.exclusiveWrite(plan.backup.currentPreferences, to: current)
            // Plan carries the exact package report used by preflight, rather than
            // asking a producer to reopen an untrusted external metadata path.
            let manifest = directory.appending(path: "package-manifest.json")
            try UpdateInstaller.exclusiveWrite(plan.packageManifest, to: manifest)
            let storeDescriptor: UpdateStoredFile?
            if let store = plan.backup.currentStoreBackup {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(store)
                guard data.count <= 64 * 1024 * 1024 + 64 * 1024 else { throw UpdateFailure.exceeded }
                let path = directory.appending(path: "current-store-backup.plist")
                try UpdateInstaller.exclusiveWrite(data, to: path)
                storeDescriptor = try storedFile(path, bytes: Int64(data.count), digest: hash(data))
            } else {
                storeDescriptor = nil
            }
            try syncTree(stage, cancellation: cancellation)
            guard try UpdateAppTree.read(plan.currentApp, cancellation: cancellation) == plan.oldTree else {
                throw UpdateFailure.changed
            }
            let request = UpdateHandoffRequest(
                format: 1, id: plan.id, created: Date(), scope: scope, source: source,
                target: plan.currentApp, directory: directory,
                parentIdentity: try UpdateNodeIdentity.read(parent, directory: true),
                storageIdentity: try UpdateNodeIdentity.read(directory, directory: true),
                authorizationSHA256: hash(Data(token.utf8)),
                preferencesDomain: preferencesDomain,
                windowIDs: plan.activity.windowIDs.sorted { $0.uuidString < $1.uuidString },
                persistenceGeneration: plan.activity.generation,
                installedVersion: plan.update.installed.version.rawValue,
                installedBuild: plan.update.installed.build, installedVariant: plan.update.installed.variant,
                signedManifest: plan.update.signedManifest, oldApp: old, newApp: new,
                archive: try storedFile(archiveURL, bytes: download.byteCount, digest: download.sha256),
                packageManifest: try storedFile(
                    manifest, bytes: Int64(plan.packageManifest.count), digest: hash(plan.packageManifest)),
                originalPreferences: try storedFile(
                    original, bytes: Int64(plan.backup.originalPreferences.count),
                    digest: hash(plan.backup.originalPreferences)),
                currentPreferences: try storedFile(
                    current, bytes: Int64(plan.backup.currentPreferences.count),
                    digest: hash(plan.backup.currentPreferences)),
                currentStoreBackup: storeDescriptor,
                helper: UpdateStoredFile(
                    name: "Installer/Helpers/WeGitUpdater", bytes: helperBytes, sha256: helperFile.hash,
                    identity: try UpdateNodeIdentity.read(copiedHelper)), helperResources: resources)
            let data = try encode(request)
            guard data.count <= 512 * 1024 else { throw UpdateFailure.exceeded }
            let ticket = UpdateHandoffTicket(
                id: plan.id, directory: directory.path, token: token, documentSHA256: hash(data))
            try UpdateInstaller.exclusiveWrite(data, to: directory.appending(path: "request.json"))
            try UpdateInstaller.exclusiveWrite(
                try encode(UpdateInstallJournal(id: plan.id, handoffSHA256: ticket.documentSHA256)),
                to: request.journal)
            try UpdateInstaller.exclusiveWrite(try encode(ticket), to: ticket.ticketURL)
            try UpdateInstaller.sync(directory)
            try UpdateInstaller.sync(parent)
            return ticket
        }
    }

    public static func readAndValidate(
        ticket: UpdateHandoffTicket, trustedKeyRing: UpdateKeyRing, requiredScope: UpdateHandoffScope? = nil
    )
        async throws -> VerifiedUpdateHandoff
    {
        try await verify(
            ticket: ticket, ring: trustedKeyRing, historical: false, requiredScope: requiredScope)
    }

    public static func readAndValidateForRecovery(
        ticket: UpdateHandoffTicket, trustedKeyRing: UpdateKeyRing, requiredScope: UpdateHandoffScope? = nil
    )
        async throws -> VerifiedUpdateHandoff
    {
        try await verify(ticket: ticket, ring: trustedKeyRing, historical: true, requiredScope: requiredScope)
    }

    public static func readJournalSnapshot(verified: VerifiedUpdateHandoff) async throws
        -> UpdateInstallJournal
    {
        try await SnapshotIO.run { _ in
            try validateDirectory(verified)
            return try readJournal(verified)
        }
    }

    public static func readReceiptSnapshot(verified: VerifiedUpdateHandoff) async throws
        -> PersistentUpdateReceipt
    {
        try await SnapshotIO.run { _ in
            try validateDirectory(verified)
            return try receipt(verified, readJournal(verified))
        }
    }

    public static func writeSourceAbort(ticket: UpdateHandoffTicket, reason: String) async throws {
        guard reason.utf8.count <= 1024 else { throw UpdateFailure.exceeded }
        let source = try UpdateProcessIdentity.capture()
        try await SnapshotIO.run { cancellation in
            guard try loadTicket(at: ticket.ticketURL, token: ticket.token) == ticket else {
                throw UpdateFailure.changed
            }
            let request = try readRequest(ticket)
            guard source == request.source, try fingerprint(request.target, cancellation) == request.oldApp,
                try fingerprint(request.stage, cancellation) == request.newApp
            else { throw UpdateFailure.changed }
            let journal = try decode(
                UpdateInstallJournal.self, data: UpdateInstaller.readSmall(request.journal, limit: 64 * 1024))
            guard journal.phase == .prepared || journal.phase == .sourceExited else {
                throw UpdateFailure.changed
            }
            let abort = UpdateSourceAbort(
                id: ticket.id, documentSHA256: ticket.documentSHA256,
                authorizationSHA256: request.authorizationSHA256, source: source, reason: reason)
            try UpdateInstaller.exclusiveWrite(
                try encode(abort), to: request.directory.appending(path: "source-abort.json"))
        }
    }

    public static func readSourceAbort(verified: VerifiedUpdateHandoff) async throws -> UpdateSourceAbort? {
        try await SnapshotIO.run { _ in try sourceAbort(verified) }
    }

    public static func markBlocked(verified: VerifiedUpdateHandoff, reason: String) async throws
        -> PersistentUpdateReceipt
    {
        guard reason.utf8.count <= 1024 else { throw UpdateFailure.exceeded }
        return try await SnapshotIO.run { _ in
            var journal = try readJournal(verified)
            journal.phase = .blocked
            journal.detail = reason
            try saveJournal(&journal, verified: verified)
            return try receipt(verified, journal)
        }
    }

    public static func writeHelperReady(verified: VerifiedUpdateHandoff, monitor: UpdateSourceProcessMonitor)
        async throws -> UpdateHelperReadiness
    {
        guard monitor.identity == verified.request.source else { throw UpdateFailure.changed }
        let helper = try UpdateProcessIdentity.capture()
        guard helper.executable == verified.request.helperExecutable.path,
            helper.executableIdentity == verified.request.helper.identity
        else { throw UpdateFailure.changed }
        let ready = UpdateHelperReadiness(
            id: verified.ticket.id, documentSHA256: verified.ticket.documentSHA256,
            authorizationSHA256: verified.request.authorizationSHA256, helper: try .capture(),
            source: monitor.identity)
        try await SnapshotIO.run { _ in
            try validateDirectory(verified)
            try UpdateInstaller.exclusiveWrite(try encode(ready), to: verified.request.helperReadyURL)
        }
        return ready
    }

    public static func readHelperReady(ticket: UpdateHandoffTicket) async throws -> UpdateHelperReadiness? {
        try await SnapshotIO.run { _ in
            let request = try readRequest(ticket)
            guard FileManager.default.fileExists(atPath: request.helperReadyURL.path) else { return nil }
            let ready = try decode(
                UpdateHelperReadiness.self,
                data: UpdateInstaller.readSmall(request.helperReadyURL, limit: 16 * 1024))
            guard ready.id == ticket.id, ready.documentSHA256 == ticket.documentSHA256,
                ready.authorizationSHA256 == request.authorizationSHA256, ready.source == request.source,
                ready.helper.stillRunning(),
                ready.helper.executable == request.helperExecutable.path,
                ready.helper.executableIdentity == request.helper.identity
            else { throw UpdateFailure.changed }
            return ready
        }
    }

    public static func abortPrepared(ticket: UpdateHandoffTicket, reason: String) async throws
        -> PersistentUpdateReceipt
    {
        try await SnapshotIO.run { cancellation in
            let checked = try loadTicket(at: ticket.ticketURL, token: ticket.token)
            guard checked == ticket else { throw UpdateFailure.changed }
            let request = try readRequest(ticket)
            let lease = try UpdateTransactionLease(directory: request.directory)
            _ = lease
            return try abortPrepared(
                ticket: ticket, request: request, reason: reason, cancellation: cancellation)
        }
    }

    public static func abortPrepared(verified: VerifiedUpdateHandoff, reason: String) async throws
        -> PersistentUpdateReceipt
    {
        try await SnapshotIO.run { cancellation in
            try validateDirectory(verified)
            return try abortPrepared(
                ticket: verified.ticket, request: verified.request, reason: reason, cancellation: cancellation
            )
        }
    }

    public static func readHelperAbort(ticket: UpdateHandoffTicket) async throws -> UpdateHelperAbort? {
        try await SnapshotIO.run { _ in
            let request = try readRequest(ticket)
            let path = request.directory.appending(path: "helper-aborted.json")
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            let result = try decode(
                UpdateHelperAbort.self, data: UpdateInstaller.readSmall(path, limit: 16 * 1024))
            guard result.id == ticket.id, result.documentSHA256 == ticket.documentSHA256,
                result.authorizationSHA256 == request.authorizationSHA256
            else { throw UpdateFailure.changed }
            return result
        }
    }

    public static func recordLaunchedProcess(
        verified: VerifiedUpdateHandoff, monitor: UpdateSourceProcessMonitor
    ) async throws -> PersistentUpdateReceipt {
        try await SnapshotIO.run { cancellation in
            try validateDirectory(verified)
            guard
                monitor.identity.executable
                    == verified.request.target.appending(path: "Contents/MacOS/WeGit").path,
                try fingerprint(verified.request.target, cancellation) == verified.request.newApp
            else { throw UpdateFailure.changed }
            var journal = try readJournal(verified)
            guard journal.phase == .awaitingLaunch,
                journal.launchedProcess == nil || journal.launchedProcess == monitor.identity
            else { throw UpdateFailure.changed }
            journal.launchedProcess = monitor.identity
            try saveJournal(&journal, verified: verified)
            return try receipt(verified, journal)
        }
    }

    public static func apply(verified: VerifiedUpdateHandoff, permit: UpdateNormalExitPermit) async throws
        -> PersistentUpdateReceipt
    {
        guard permit.source == verified.request.source, permit.exitStatus == 0, !permit.source.stillRunning(),
            Date() < verified.update.expiresAt
        else { throw UpdateFailure.busy }
        return try await SnapshotIO.run { cancellation in
            try validateDirectory(verified)
            guard try sourceAbort(verified) == nil else { throw UpdateFailure.busy }
            try stopped(verified.request)
            var journal = try readJournal(verified)
            guard journal.phase == .prepared else { throw UpdateFailure.changed }
            journal.sourceExitObservedAt = permit.observedAt
            journal.sourceExitStatus = permit.exitStatus
            journal.phase = .sourceExited
            try saveJournal(&journal, verified: verified)
            guard try fingerprint(verified.request.target, cancellation) == verified.request.oldApp,
                try fingerprint(verified.request.stage, cancellation) == verified.request.newApp
            else { throw UpdateFailure.changed }
            try UpdateInstaller.verifySignature(verified.request.target)
            try UpdateInstaller.verifySignature(verified.request.stage)
            try validateStoredFiles(verified.request)
            try cancellation.check()
            try stopped(verified.request)
            guard try sourceAbort(verified) == nil else { throw UpdateFailure.busy }
            guard Date() < verified.update.expiresAt else { throw UpdateFailure.expired }
            journal.phase = .swapIntent
            try saveJournal(&journal, verified: verified)
            try swap(verified.request.target, verified.request.stage)
            try UpdateInstaller.sync(verified.request.target.deletingLastPathComponent())
            try UpdateInstaller.sync(verified.request.directory)
            try completeSwap(verified, journal: &journal, cancellation: cancellation)
            return try receipt(verified, journal)
        }
    }

    public static func recover(
        ticket: UpdateHandoffTicket, trustedKeyRing: UpdateKeyRing, requiredScope: UpdateHandoffScope? = nil
    ) async throws
        -> UpdateRecoveryDecision
    {
        let verified = try await verify(
            ticket: ticket, ring: trustedKeyRing, historical: true, requiredScope: requiredScope)
        return try await SnapshotIO.run { cancellation in
            var journal = try readJournal(verified)
            try validateDirectory(verified)
            let target = try optionalFingerprint(verified.request.target, cancellation)
            let stage = try optionalFingerprint(verified.request.stage, cancellation)
            let previous = try optionalFingerprint(verified.request.previousApp, cancellation)
            if target == verified.request.oldApp {
                if stage != nil && stage != verified.request.newApp
                    || previous != nil && previous != verified.request.newApp
                {
                    return try block(verified, &journal, "Unknown retained path during recovery")
                }
                if journal.phase == .prepared { return .prepared(try receipt(verified, journal)) }
                if journal.phase == .rollbackIntent || previous == verified.request.newApp {
                    try finishRollback(verified, journal: &journal, cancellation: cancellation)
                } else {
                    journal.phase = .rolledBack
                    try saveJournal(&journal, verified: verified)
                }
                return .rolledBack(try receipt(verified, journal))
            }
            guard target == verified.request.newApp, journal.sourceExitStatus == 0,
                journal.sourceExitObservedAt != nil
            else {
                return try block(verified, &journal, "Target no longer matches the transaction")
            }
            if journal.phase == .rollbackIntent {
                return try block(
                    verified, &journal, "Rollback intent requires explicit stopped-process recovery")
            }
            if stage == verified.request.oldApp && previous == nil {
                try completeSwap(verified, journal: &journal, cancellation: cancellation)
            } else if stage != nil || previous != verified.request.oldApp {
                return try block(verified, &journal, "Previous package is missing or changed")
            }
            if journal.phase == .launchVerified { return .completed(try receipt(verified, journal)) }
            if journal.phase == .blocked {
                journal.phase = .awaitingLaunch
                journal.detail = nil
                try saveJournal(&journal, verified: verified)
            }
            return .awaitingLaunch(try receipt(verified, journal))
        }
    }

    public static func rollback(verified: VerifiedUpdateHandoff, observedExit: UpdateObservedExit? = nil)
        async throws -> PersistentUpdateReceipt
    {
        try await SnapshotIO.run { cancellation in
            try stopped(verified.request)
            try validateDirectory(verified)
            var journal = try readJournal(verified)
            if let launched = journal.launchedProcess {
                guard let observedExit, observedExit.source == launched, !launched.stillRunning() else {
                    throw UpdateFailure.busy
                }
                journal.launchedExitObservedAt = observedExit.observedAt
                journal.launchedExitStatus = observedExit.exitStatus
            }
            let current = try fingerprint(verified.request.target, cancellation)
            if current == verified.request.oldApp {
                journal.phase = .rolledBack
                try saveJournal(&journal, verified: verified)
                return try receipt(verified, journal)
            }
            guard current == verified.request.newApp, journal.sourceExitStatus == 0,
                journal.sourceExitObservedAt != nil
            else { throw UpdateFailure.changed }
            let oldURL: URL
            if try optionalFingerprint(verified.request.previousApp, cancellation) == verified.request.oldApp
            {
                oldURL = verified.request.previousApp
            } else if try optionalFingerprint(verified.request.stage, cancellation) == verified.request.oldApp
            {
                oldURL = verified.request.stage
            } else {
                throw UpdateFailure.changed
            }
            try validateStoredFiles(verified.request)
            journal.phase = .rollbackIntent
            journal.preferencesRestoreRequired = true
            journal.storeRestoreRequired = verified.request.currentStoreBackup != nil
            try saveJournal(&journal, verified: verified)
            try stopped(verified.request)
            try swap(verified.request.target, oldURL)
            try UpdateInstaller.sync(verified.request.target.deletingLastPathComponent())
            try UpdateInstaller.sync(verified.request.directory)
            try finishRollback(verified, journal: &journal, cancellation: cancellation)
            return try receipt(verified, journal)
        }
    }

    public static func writeReadiness(
        ticket: UpdateHandoffTicket, trustedKeyRing: UpdateKeyRing, migrationCompleted: Bool,
        windowsRestored: Bool, preferencesFlushed: Bool
    ) async throws -> UpdateLaunchReadiness {
        guard migrationCompleted, windowsRestored, preferencesFlushed else { throw UpdateFailure.busy }
        try await validateLaunchTicket(ticket: ticket, trustedKeyRing: trustedKeyRing)
        let process = try UpdateProcessIdentity.capture()
        return try await writeReadiness(
            ticket: ticket, process: process, migrationCompleted: migrationCompleted,
            windowsRestored: windowsRestored, preferencesFlushed: preferencesFlushed, isolated: false)
    }

    public static func validateLaunchTicket(ticket: UpdateHandoffTicket, trustedKeyRing: UpdateKeyRing)
        async throws
    {
        try await SnapshotIO.run { cancellation in
            guard try loadTicket(at: ticket.ticketURL, token: ticket.token) == ticket else {
                throw UpdateFailure.changed
            }
            let request = try readRequest(ticket)
            guard request.scope == .production else { throw UpdateFailure.changed }
            let envelope = try JSONDecoder().decode(SignedUpdateManifest.self, from: request.signedManifest)
            let metadata = try JSONDecoder().decode(UpdateManifest.self, from: envelope.payload)
            let installed = try InstalledUpdateVersion(
                version: request.installedVersion, build: request.installedBuild,
                variant: request.installedVariant)
            guard
                case .available(let update) = try UpdateManifestValidator.validate(
                    request.signedManifest, ring: trustedKeyRing,
                    channel: metadata.channel, installed: installed, now: request.created)
            else { throw UpdateFailure.changed }
            guard try UpdateNodeIdentity.read(request.directory, directory: true) == request.storageIdentity,
                try UpdateNodeIdentity.read(request.target.deletingLastPathComponent(), directory: true)
                    == request.parentIdentity,
                try fingerprint(request.target, cancellation) == request.newApp
            else { throw UpdateFailure.changed }
            let journal = try decode(
                UpdateInstallJournal.self, data: UpdateInstaller.readSmall(request.journal, limit: 64 * 1024))
            guard journal.id == ticket.id, journal.handoffSHA256 == ticket.documentSHA256,
                journal.phase == .awaitingLaunch || journal.phase == .launchVerified,
                journal.sourceExitStatus == 0, journal.sourceExitObservedAt != nil,
                journal.sourceExitObservedAt! < update.expiresAt
            else { throw UpdateFailure.changed }
            try validateStoredFiles(request)
            try UpdateInstaller.verifySignature(request.target)
            try UpdateInstaller.validatePackage(
                try bytes(request.packageManifest, in: request),
                tree: UpdateAppTree.read(request.target, cancellation: cancellation), app: request.target,
                update: update)
            let process = try UpdateProcessIdentity.capture()
            guard process.executable == request.target.appending(path: "Contents/MacOS/WeGit").path else {
                throw UpdateFailure.changed
            }
        }
    }

    static func writeReadiness(
        ticket: UpdateHandoffTicket, process: UpdateProcessIdentity,
        migrationCompleted: Bool, windowsRestored: Bool, preferencesFlushed: Bool, isolated: Bool
    ) async throws -> UpdateLaunchReadiness {
        try await SnapshotIO.run { cancellation in
            let request = try readRequest(ticket)
            guard !isolated || request.scope == .isolatedControl else { throw UpdateFailure.changed }
            let manifest = try JSONDecoder().decode(SignedUpdateManifest.self, from: request.signedManifest)
            let update = try JSONDecoder().decode(UpdateManifest.self, from: manifest.payload)
            let ready = UpdateLaunchReadiness(
                id: ticket.id, documentSHA256: ticket.documentSHA256,
                authorizationSHA256: request.authorizationSHA256, process: process, version: update.version,
                build: update.build, variant: request.installedVariant,
                migrationCompleted: migrationCompleted,
                windowsRestored: windowsRestored, preferencesFlushed: preferencesFlushed)
            try validateReadiness(ready, request: request, ticket: ticket, cancellation: cancellation)
            try UpdateInstaller.exclusiveWrite(try encode(ready), to: request.readyURL)
            return ready
        }
    }

    public static func readReadiness(verified: VerifiedUpdateHandoff) async throws -> UpdateLaunchReadiness? {
        try await SnapshotIO.run { cancellation in
            guard FileManager.default.fileExists(atPath: verified.request.readyURL.path) else { return nil }
            let ready = try decode(
                UpdateLaunchReadiness.self,
                data: UpdateInstaller.readSmall(verified.request.readyURL, limit: 16 * 1024))
            try validateReadiness(
                ready, request: verified.request, ticket: verified.ticket, cancellation: cancellation)
            return ready
        }
    }

    public static func confirmLaunch(verified: VerifiedUpdateHandoff, readiness: UpdateLaunchReadiness)
        async throws -> PersistentUpdateReceipt
    {
        try await SnapshotIO.run { cancellation in
            try validateDirectory(verified)
            try validateReadiness(
                readiness, request: verified.request, ticket: verified.ticket, cancellation: cancellation)
            var journal = try readJournal(verified)
            guard journal.phase == .awaitingLaunch, journal.launchedProcess == readiness.process else {
                throw UpdateFailure.changed
            }
            journal.phase = .launchVerified
            journal.readiness = readiness
            try saveJournal(&journal, verified: verified)
            return try receipt(verified, journal)
        }
    }

    /// Called only after the independent helper has restored the returned current
    /// preferences into the stopped application's domain and verified exact bytes.
    public static func confirmPreferencesRestored(verified: VerifiedUpdateHandoff, restoredSHA256: String)
        async throws -> PersistentUpdateReceipt
    {
        guard restoredSHA256 == verified.request.currentPreferences.sha256 else {
            throw UpdateFailure.changed
        }
        return try await SnapshotIO.run { _ in
            try stopped(verified.request)
            var journal = try readJournal(verified)
            guard journal.phase == .rolledBack else { throw UpdateFailure.changed }
            journal.preferencesRestoreRequired = false
            try saveJournal(&journal, verified: verified)
            return try receipt(verified, journal)
        }
    }

    public static func confirmStoreRestored(verified: VerifiedUpdateHandoff, restoredSHA256: String)
        async throws -> PersistentUpdateReceipt
    {
        guard let stored = verified.request.currentStoreBackup else { throw UpdateFailure.changed }
        let backup = try PropertyListDecoder().decode(
            ApplicationStoreBackup.self, from: bytes(stored, in: verified.request))
        guard restoredSHA256 == backup.sha256 else { throw UpdateFailure.changed }
        return try await SnapshotIO.run { _ in
            try stopped(verified.request)
            var journal = try readJournal(verified)
            guard journal.phase == .rolledBack else { throw UpdateFailure.changed }
            journal.storeRestoreRequired = false
            try saveJournal(&journal, verified: verified)
            return try receipt(verified, journal)
        }
    }

    public static func recordedRollbackExit(verified: VerifiedUpdateHandoff) async throws
        -> UpdateObservedExit?
    {
        try await SnapshotIO.run { _ in
            try validateDirectory(verified)
            let journal = try readJournal(verified)
            guard journal.phase == .rolledBack || journal.phase == .rollbackIntent else {
                throw UpdateFailure.changed
            }
            guard let process = journal.launchedProcess else { return nil }
            guard let date = journal.launchedExitObservedAt, let status = journal.launchedExitStatus,
                !process.stillRunning()
            else { throw UpdateFailure.busy }
            return UpdateObservedExit(source: process, observedAt: date, exitStatus: status)
        }
    }

    private static func verify(
        ticket: UpdateHandoffTicket, ring: UpdateKeyRing, historical: Bool,
        requiredScope: UpdateHandoffScope? = nil
    )
        async throws -> VerifiedUpdateHandoff
    {
        try await SnapshotIO.run { cancellation in
            let checked = try loadTicket(at: ticket.ticketURL, token: ticket.token)
            guard checked == ticket else { throw UpdateFailure.changed }
            let lease = try UpdateTransactionLease(directory: URL(fileURLWithPath: ticket.directory))
            let request = try readRequest(ticket)
            guard requiredScope == nil || request.scope == requiredScope else { throw UpdateFailure.changed }
            let installed = try InstalledUpdateVersion(
                version: request.installedVersion, build: request.installedBuild,
                variant: request.installedVariant)
            let envelope = try JSONDecoder().decode(SignedUpdateManifest.self, from: request.signedManifest)
            let metadata = try JSONDecoder().decode(UpdateManifest.self, from: envelope.payload)
            let result = try UpdateManifestValidator.validate(
                request.signedManifest, ring: ring, channel: metadata.channel,
                installed: installed, now: historical ? request.created : Date())
            guard case .available(let update) = result, request.archive.sha256 == update.artifact.sha256,
                request.archive.bytes == update.artifact.downloadBytes,
                request.packageManifest.sha256 == update.artifact.manifestSHA256
            else { throw UpdateFailure.changed }
            let verified = VerifiedUpdateHandoff(
                ticket: ticket, request: request, update: update, lease: lease)
            try validateDirectory(verified)
            try validateStoredFiles(request)
            var newLocation: URL?
            for path in [
                request.stage, request.target, request.previousApp,
                request.directory.appending(path: "FailedReplacement.app"),
            ] {
                if try optionalFingerprint(path, cancellation) == request.newApp {
                    newLocation = path
                    break
                }
            }
            if let newLocation {
                try UpdateInstaller.verifySignature(newLocation)
                try UpdateInstaller.validatePackage(
                    try bytes(request.packageManifest, in: request),
                    tree: UpdateAppTree.read(newLocation, cancellation: cancellation), app: newLocation,
                    update: update)
            }
            _ = try readJournal(verified)
            return verified
        }
    }

    private static func readRequest(_ ticket: UpdateHandoffTicket) throws -> UpdateHandoffRequest {
        let directory = URL(fileURLWithPath: ticket.directory)
        guard try privateDirectory(directory) else { throw UpdateFailure.changed }
        let data = try UpdateInstaller.readSmall(directory.appending(path: "request.json"), limit: 512 * 1024)
        guard hash(data) == ticket.documentSHA256 else { throw UpdateFailure.changed }
        let request = try decode(UpdateHandoffRequest.self, data: data)
        guard request.format == 1, request.id == ticket.id, request.directory.path == ticket.directory,
            request.authorizationSHA256 == hash(Data(ticket.token.utf8)),
            request.target.deletingLastPathComponent().path == directory.deletingLastPathComponent().path,
            request.source.owner == getuid(), request.windowIDs.count <= 32,
            Set(request.windowIDs).count == request.windowIDs.count,
            request.signedManifest.count <= UpdateManifestValidator.metadataBytes
        else { throw UpdateFailure.changed }
        try validateScope(request.scope, target: request.target)
        guard request.scope != .production || request.preferencesDomain == "com.willxue.wegit.v2",
            request.scope != .isolatedControl
                || request.preferencesDomain.hasPrefix("com.willxue.wegit.UITests.")
        else {
            throw UpdateFailure.changed
        }
        return request
    }

    private static func sourceAbort(_ verified: VerifiedUpdateHandoff) throws -> UpdateSourceAbort? {
        try validateDirectory(verified)
        let path = verified.request.directory.appending(path: "source-abort.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard try UpdateNodeIdentity.read(path).permissions == 0o600 else { throw UpdateFailure.changed }
        let abort = try decode(
            UpdateSourceAbort.self, data: UpdateInstaller.readSmall(path, limit: 16 * 1024))
        guard abort.id == verified.ticket.id, abort.documentSHA256 == verified.ticket.documentSHA256,
            abort.authorizationSHA256 == verified.request.authorizationSHA256,
            abort.source == verified.request.source, abort.reason.utf8.count <= 1024
        else { throw UpdateFailure.changed }
        return abort
    }

    private static func abortPrepared(
        ticket: UpdateHandoffTicket, request: UpdateHandoffRequest,
        reason: String, cancellation: IOCancellation
    ) throws -> PersistentUpdateReceipt {
        guard reason.utf8.count <= 1024,
            try fingerprint(request.target, cancellation) == request.oldApp,
            try fingerprint(request.stage, cancellation) == request.newApp
        else { throw UpdateFailure.changed }
        var journal = try decode(
            UpdateInstallJournal.self, data: UpdateInstaller.readSmall(request.journal, limit: 64 * 1024))
        guard journal.id == ticket.id, journal.handoffSHA256 == ticket.documentSHA256,
            journal.phase == .prepared || journal.phase == .sourceExited,
            journal.revision < UInt64.max
        else { throw UpdateFailure.changed }
        journal.revision += 1
        journal.phase = .blocked
        journal.detail = reason
        let temporary = request.directory.appending(path: "abort-journal-" + UUID().uuidString)
        try UpdateInstaller.exclusiveWrite(try encode(journal), to: temporary)
        guard rename(temporary.path, request.journal.path) == 0 else { throw UpdateFailure.changed }
        let abort = UpdateHelperAbort(
            id: ticket.id, documentSHA256: ticket.documentSHA256,
            authorizationSHA256: request.authorizationSHA256, reason: reason)
        try UpdateInstaller.exclusiveWrite(
            try encode(abort), to: request.directory.appending(path: "helper-aborted.json"))
        try UpdateInstaller.sync(request.directory)
        return PersistentUpdateReceipt(
            ticket: ticket, phase: .blocked, installedApp: request.target,
            previousApp: request.previousApp, preferencesRestoration: nil, storeRestoration: nil)
    }

    private static func validateScope(_ scope: UpdateHandoffScope, target: URL) throws {
        try UpdateInstaller.validateParents(target)
        guard target.lastPathComponent.hasSuffix(".app"),
            access(target.deletingLastPathComponent().path, W_OK | X_OK) == 0
        else { throw UpdateFailure.changed }
        if scope == .isolatedControl {
            let base =
                try UpdateInstallationSandbox.canonical(FileManager.default.temporaryDirectory)
                .appending(path: "com.willxue.wegit.update-tests").path + "/update-test-"
            guard target.deletingLastPathComponent().path.hasPrefix(base) else { throw UpdateFailure.changed }
        }
    }

    private static func validateDirectory(_ verified: VerifiedUpdateHandoff) throws {
        let request = verified.request
        guard try UpdateNodeIdentity.read(request.directory, directory: true) == request.storageIdentity,
            try UpdateNodeIdentity.read(request.target.deletingLastPathComponent(), directory: true)
                == request.parentIdentity,
            try privateDirectory(request.directory)
        else { throw UpdateFailure.changed }
    }

    private static func privateDirectory(_ directory: URL) throws -> Bool {
        let node = try UpdateNodeIdentity.read(directory, directory: true)
        return node.owner == getuid() && node.permissions == 0o700
    }

    private static func storedFile(_ path: URL, bytes: Int64, digest: String) throws -> UpdateStoredFile {
        UpdateStoredFile(
            name: path.lastPathComponent, bytes: bytes, sha256: digest,
            identity: try UpdateNodeIdentity.read(path))
    }

    private static func bytes(_ file: UpdateStoredFile, in request: UpdateHandoffRequest) throws -> Data {
        let limit = file.name == "current-store-backup.plist" ? 64 * 1024 * 1024 + 64 * 1024 : 8 * 1024 * 1024
        guard
            [
                "package-manifest.json", "original-preferences.plist", "current-preferences.plist",
                "current-store-backup.plist",
            ].contains(file.name),
            file.bytes >= 0, file.bytes <= limit
        else { throw UpdateFailure.changed }
        let path = request.directory.appending(path: file.name)
        guard try UpdateNodeIdentity.read(path) == file.identity else { throw UpdateFailure.changed }
        let data = try UpdateInstaller.readSmall(path, limit: Int(file.bytes))
        guard data.count == file.bytes, hash(data) == file.sha256 else { throw UpdateFailure.changed }
        return data
    }

    private static func validateStoredFiles(_ request: UpdateHandoffRequest) throws {
        _ = try bytes(request.packageManifest, in: request)
        let original = try bytes(request.originalPreferences, in: request)
        let current = try bytes(request.currentPreferences, in: request)
        _ = try UpdateDataBackup(originalPreferences: original, currentPreferences: current)
        if let store = request.currentStoreBackup {
            let backup = try PropertyListDecoder().decode(
                ApplicationStoreBackup.self, from: bytes(store, in: request))
            guard backup.bytes <= 64 * 1024 * 1024, hash(backup.data) == backup.sha256 else {
                throw UpdateFailure.changed
            }
        }
        guard request.helper.name == "Installer/Helpers/WeGitUpdater",
            try UpdateNodeIdentity.read(request.helperExecutable) == request.helper.identity,
            request.helper.bytes <= UpdateManifestValidator.installedBytes
        else { throw UpdateFailure.changed }
        try checkFile(request.helperExecutable, bytes: request.helper.bytes, checksum: request.helper.sha256)
        guard try fingerprint(request.helperResourcesURL, IOCancellation()) == request.helperResources else {
            throw UpdateFailure.changed
        }
        guard request.archive.name == "archive.dmg", request.archive.bytes > 0,
            request.archive.bytes <= UpdateManifestValidator.downloadBytes,
            try UpdateNodeIdentity.read(request.directory.appending(path: "archive.dmg"))
                == request.archive.identity
        else { throw UpdateFailure.changed }
        try checkFile(
            request.directory.appending(path: "archive.dmg"), bytes: request.archive.bytes,
            checksum: request.archive.sha256)
    }

    private static func readJournal(_ verified: VerifiedUpdateHandoff) throws -> UpdateInstallJournal {
        let journal = try decode(
            UpdateInstallJournal.self,
            data: UpdateInstaller.readSmall(verified.request.journal, limit: 64 * 1024))
        guard journal.format == 1, journal.id == verified.ticket.id,
            journal.handoffSHA256 == verified.ticket.documentSHA256, journal.revision < UInt64.max
        else { throw UpdateFailure.changed }
        return journal
    }

    private static func saveJournal(_ journal: inout UpdateInstallJournal, verified: VerifiedUpdateHandoff)
        throws
    {
        try validateDirectory(verified)
        let current = try readJournal(verified)
        guard current.revision == journal.revision else { throw UpdateFailure.changed }
        journal.revision += 1
        let temporary = verified.request.directory.appending(path: "journal-" + UUID().uuidString + ".tmp")
        try UpdateInstaller.exclusiveWrite(try encode(journal), to: temporary)
        guard rename(temporary.path, verified.request.journal.path) == 0 else { throw UpdateFailure.changed }
        try UpdateInstaller.sync(verified.request.directory)
    }

    private static func completeSwap(
        _ verified: VerifiedUpdateHandoff, journal: inout UpdateInstallJournal, cancellation: IOCancellation
    ) throws {
        guard try fingerprint(verified.request.target, cancellation) == verified.request.newApp,
            try fingerprint(verified.request.stage, cancellation) == verified.request.oldApp
        else { throw UpdateFailure.changed }
        try UpdateInstaller.moveExclusive(verified.request.stage, verified.request.previousApp)
        try UpdateInstaller.sync(verified.request.directory)
        journal.phase = .awaitingLaunch
        try saveJournal(&journal, verified: verified)
    }

    private static func finishRollback(
        _ verified: VerifiedUpdateHandoff, journal: inout UpdateInstallJournal, cancellation: IOCancellation
    ) throws {
        guard try fingerprint(verified.request.target, cancellation) == verified.request.oldApp else {
            throw UpdateFailure.changed
        }
        for path in [verified.request.previousApp, verified.request.stage] {
            if try optionalFingerprint(path, cancellation) == verified.request.newApp {
                try UpdateInstaller.moveExclusive(
                    path, verified.request.directory.appending(path: "FailedReplacement.app"))
            }
        }
        try UpdateInstaller.sync(verified.request.directory)
        journal.phase = .rolledBack
        try saveJournal(&journal, verified: verified)
    }

    private static func validateReadiness(
        _ ready: UpdateLaunchReadiness, request: UpdateHandoffRequest, ticket: UpdateHandoffTicket,
        cancellation: IOCancellation
    ) throws {
        let envelope = try JSONDecoder().decode(SignedUpdateManifest.self, from: request.signedManifest)
        let expected = try JSONDecoder().decode(UpdateManifest.self, from: envelope.payload)
        guard ready.id == ticket.id, ready.documentSHA256 == ticket.documentSHA256,
            ready.authorizationSHA256 == request.authorizationSHA256, ready.migrationCompleted,
            ready.windowsRestored,
            ready.preferencesFlushed, ready.process.stillRunning(),
            ready.version == expected.version, ready.build == expected.build,
            ready.process.executable == request.target.appending(path: "Contents/MacOS/WeGit").path,
            try fingerprint(request.target, cancellation) == request.newApp
        else { throw UpdateFailure.changed }
        let info =
            try PropertyListSerialization.propertyList(
                from: UpdateInstaller.readSmall(
                    request.target.appending(path: "Contents/Info.plist"), limit: 64 * 1024), format: nil)
            as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == "com.willxue.wegit",
            info?["CFBundleShortVersionString"] as? String == String(ready.version.split(separator: "-")[0]),
            info?["CFBundleVersion"] as? String == String(ready.build),
            info?["WeGitDistributionVariant"] as? String == ready.variant.rawValue,
            ready.variant == request.installedVariant
        else { throw UpdateFailure.changed }
        guard let info else { throw UpdateFailure.changed }
        try UpdateInstaller.validateReleaseVersion(info: info, expected: ready.version)
    }

    private static func stopped(_ request: UpdateHandoffRequest) throws {
        guard !request.source.stillRunning() else { throw UpdateFailure.busy }
        var pids = [Int32](repeating: 0, count: 65536)
        let used = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard used > 0, used < pids.count * MemoryLayout<Int32>.size else { throw UpdateFailure.busy }
        for pid in pids.prefix(Int(used) / MemoryLayout<Int32>.size) where pid > 0 {
            guard let process = try? UpdateProcessIdentity.capture(pid: pid) else { continue }
            if process.executable == request.target.appending(path: "Contents/MacOS/WeGit").path {
                throw UpdateFailure.busy
            }
            if request.scope == .production && process.executable.hasSuffix(".app/Contents/MacOS/WeGit") {
                let app = URL(fileURLWithPath: process.executable).deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                let data = try UpdateInstaller.readSmall(
                    app.appending(path: "Contents/Info.plist"), limit: 64 * 1024)
                let info =
                    try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                if info?["CFBundleIdentifier"] as? String == "com.willxue.wegit" { throw UpdateFailure.busy }
            }
        }
    }

    private static func receipt(_ verified: VerifiedUpdateHandoff, _ journal: UpdateInstallJournal) throws
        -> PersistentUpdateReceipt
    {
        let restore =
            journal.preferencesRestoreRequired
            ? UpdatePreferencesRestoration(
                transactionID: verified.ticket.id,
                domainName: verified.request.preferencesDomain,
                bytes: try bytes(verified.request.currentPreferences, in: verified.request),
                sha256: verified.request.currentPreferences.sha256) : nil
        return PersistentUpdateReceipt(
            ticket: verified.ticket, phase: journal.phase, installedApp: verified.request.target,
            previousApp: verified.request.previousApp, preferencesRestoration: restore,
            storeRestoration: journal.storeRestoreRequired
                ? try verified.request.currentStoreBackup.map {
                    try PropertyListDecoder().decode(
                        ApplicationStoreBackup.self, from: bytes($0, in: verified.request))
                } : nil)
    }
    private static func block(
        _ verified: VerifiedUpdateHandoff, _ journal: inout UpdateInstallJournal, _ detail: String
    ) throws -> UpdateRecoveryDecision {
        journal.phase = .blocked
        journal.detail = detail
        try saveJournal(&journal, verified: verified)
        return .blocked(try receipt(verified, journal))
    }
    private static func fingerprint(_ url: URL, _ cancellation: IOCancellation) throws -> UpdateAppFingerprint
    { try .capture(url, cancellation: cancellation) }
    private static func optionalFingerprint(_ url: URL, _ cancellation: IOCancellation) throws
        -> UpdateAppFingerprint?
    {
        guard try RepositoryNodeIdentity.readIfPresent(url) != nil else { return nil }
        return try fingerprint(url, cancellation)
    }
    private static func swap(_ first: URL, _ second: URL) throws {
        guard renameatx_np(AT_FDCWD, first.path, AT_FDCWD, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateFailure.changed
        }
    }
    private static func availableSpace(_ root: URL, required: Int64) throws {
        var volume = statfs()
        guard statfs(root.path, &volume) == 0, volume.f_bavail <= UInt64(Int64.max) / UInt64(volume.f_bsize),
            Int64(volume.f_bavail * UInt64(volume.f_bsize)) >= required
        else { throw UpdateFailure.insufficientSpace }
    }
    private static func retainedCapacity(_ parent: URL, proposed: Int64) throws {
        var count = 1
        var total = proposed
        guard proposed <= 1024 * 1024 * 1024 else { throw UpdateFailure.exceeded }
        let directories = try FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil)
        guard directories.count <= 10000 else { throw UpdateFailure.exceeded }
        for directory in directories where directory.lastPathComponent.hasPrefix(".WeGit-update-") {
            count += 1
            guard count <= 20 else { throw UpdateFailure.exceeded }
            let ticket = try loadTicket(at: directory.appending(path: "ticket.json"))
            let request = try readRequest(ticket)
            guard request.directory.path == directory.path else { throw UpdateFailure.changed }
            let journal = try decode(
                UpdateInstallJournal.self, data: UpdateInstaller.readSmall(request.journal, limit: 64 * 1024))
            guard journal.format == 1, journal.id == ticket.id, journal.handoffSHA256 == ticket.documentSHA256
            else {
                throw UpdateFailure.changed
            }
            guard
                let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            else { throw UpdateFailure.changed }
            var entries = 0
            for case let file as URL in iterator {
                entries += 1
                guard entries <= 10000 else { throw UpdateFailure.exceeded }
                var info = stat()
                guard lstat(file.path, &info) == 0, info.st_uid == getuid() else {
                    throw UpdateFailure.changed
                }
                let kind = info.st_mode & UInt16(S_IFMT)
                if kind == UInt16(S_IFDIR) { continue }
                guard kind == UInt16(S_IFREG), info.st_size >= 0, info.st_size <= 1024 * 1024 * 1024 - total
                else {
                    throw UpdateFailure.exceeded
                }
                total += info.st_size
            }
        }
    }
    private static func copyFile(
        _ source: URL, to destination: URL, bytes: Int64, checksum: String, cancellation: IOCancellation
    ) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw UpdateFailure.changed }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw UpdateFailure.changed }
        defer { close(output) }
        var hash = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellation.check()
            let count = read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw UpdateFailure.changed }
            if count == 0 { break }
            total += Int64(count)
            guard total <= bytes else { throw UpdateFailure.exceeded }
            hash.update(data: Data(buffer.prefix(count)))
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    write(output, $0.baseAddress!.advanced(by: offset), count - offset)
                }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw UpdateFailure.changed }
                offset += written
            }
        }
        guard total == bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == checksum,
            fsync(output) == 0
        else { throw UpdateFailure.changed }
    }
    private static func checkFile(_ source: URL, bytes: Int64, checksum: String) throws {
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UpdateFailure.changed }
        defer { close(descriptor) }
        var hash = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw UpdateFailure.changed }
            if count == 0 { break }
            total += Int64(count)
            guard total <= bytes else { throw UpdateFailure.changed }
            hash.update(data: Data(buffer.prefix(count)))
        }
        guard total == bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == checksum else {
            throw UpdateFailure.changed
        }
    }
    private static func syncTree(_ root: URL, cancellation: IOCancellation) throws {
        let tree = try UpdateAppTree.read(root, cancellation: cancellation)
        for path in tree.files.keys {
            try cancellation.check()
            let descriptor = open(root.appending(path: path).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw UpdateFailure.changed }
            let result = fsync(descriptor)
            close(descriptor)
            guard result == 0 else { throw UpdateFailure.changed }
        }
        for path in tree.directories.keys.sorted(by: { $0.count > $1.count }) {
            try UpdateInstaller.sync(root.appending(path: path))
        }
        try UpdateInstaller.sync(root)
    }
    private static func hash(_ bytes: Data) -> String { UpdateManifestValidator.digest(bytes) }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
