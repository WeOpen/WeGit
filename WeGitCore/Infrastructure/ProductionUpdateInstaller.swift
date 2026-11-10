import CryptoKit
import Darwin
import Foundation
import Security

final class UpdateTransactionLease: @unchecked Sendable {
    let descriptor: Int32
    init(directory: URL, create: Bool = true, name: String = "lock") throws {
        descriptor = open(
            directory.appending(path: name).path, O_RDWR | (create ? O_CREAT : 0) | O_NOFOLLOW | O_CLOEXEC,
            0o600)
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
                plan.requiredBytes + download.byteCount + helperBytes + originalResources.bytes + 2 * 1024
                * 1024
            try availableSpace(parent, required: required)
            let retentionLease = try UpdateTransactionLease(directory: parent, name: ".WeGit-retention.lock")
            defer { withExtendedLifetime(retentionLease) {} }
            try retainedCapacity(parent, proposed: required)
            let directory = parent.appending(path: ".WeGit-update-" + plan.id.uuidString)
            guard mkdir(directory.path, 0o700) == 0 else { throw UpdateFailure.changed }
            let lease = try UpdateTransactionLease(directory: directory)
            defer { withExtendedLifetime(lease) {} }
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw UpdateFailure.changed
            }
            let token = random.map { String(format: "%02x", $0) }.joined()
            var preparation = try preparationRecord(
                plan: plan, source: source, scope: scope, directory: directory,
                helperPath: helperPath, resourcePath: resourcePath, download: download,
                cancellation: cancellation)
            try savePreparation(preparation, directory: directory)
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
            let journalData = try encode(
                UpdateInstallJournal(id: plan.id, handoffSHA256: ticket.documentSHA256))
            preparation.files["request.json"] = .init(bytes: Int64(data.count), sha256: hash(data))
            preparation.files["journal.json"] = .init(
                bytes: Int64(journalData.count), sha256: hash(journalData))
            try savePreparation(preparation, directory: directory)
            try UpdateInstaller.exclusiveWrite(data, to: directory.appending(path: "request.json"))
            try UpdateInstaller.exclusiveWrite(journalData, to: request.journal)
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
            let lease = try UpdateTransactionLease(
                directory: URL(fileURLWithPath: ticket.directory), create: false)
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
        var total = proposed
        guard proposed <= 1024 * 1024 * 1024 else { throw UpdateFailure.exceeded }
        let directories = try retentionDirectories(parent)
        guard directories.count < 20 else { throw UpdateFailure.exceeded }
        for directory in directories {
            try recognizeRetention(directory)
            let bytes = try retainedBytes(directory, cancellation: IOCancellation())
            guard bytes <= 1024 * 1024 * 1024 - total else { throw UpdateFailure.exceeded }
            total += bytes
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

extension ProductionUpdateInstaller {
    public static func inventory(
        target: URL, trustedKeyRing: UpdateKeyRing, requiredScope: UpdateHandoffScope = .production
    ) async throws -> UpdateRetentionInventory {
        let target = try UpdateInstallationSandbox.canonical(target)
        try validateScope(requiredScope, target: target)
        let directories = try retentionDirectories(target.deletingLastPathComponent())
        var entries: [UpdateRetentionEntry] = []
        var total: Int64 = 0
        var complete = true
        for directory in directories {
            try Task.checkCancellation()
            let bytes: Int64?
            do {
                bytes = try await SnapshotIO.run { cancellation in
                    try retainedBytes(directory, cancellation: cancellation)
                }
            } catch is CancellationError { throw CancellationError() } catch { bytes = nil }
            if let bytes, total <= 1024 * 1024 * 1024 - bytes { total += bytes } else { complete = false }
            do {
                let inspected = try await inspectRetention(
                    directory: directory, target: target, ring: trustedKeyRing, scope: requiredScope)
                entries.append(inspected.entry)
            } catch is CancellationError { throw CancellationError() } catch {
                let busy = (error as? UpdateFailure) == .busy
                if !busy { complete = false }
                entries.append(
                    UpdateRetentionEntry(
                        id: retentionID(directory), directory: directory, created: nil, version: nil,
                        build: nil,
                        state: busy ? .busy : .unverified, bytes: bytes, canClean: false,
                        detail: busy ? "active-transaction" : "verification-failed"))
            }
        }
        return UpdateRetentionInventory(
            entries: entries, totalBytes: complete ? total : nil,
            capacityBlocked: !complete || entries.count >= 20 || total >= 1024 * 1024 * 1024)
    }

    public static func prepareCleanup(
        entry: UpdateRetentionEntry, target: URL, trustedKeyRing: UpdateKeyRing,
        requiredScope: UpdateHandoffScope = .production
    ) async throws -> UpdateRetentionCleanupPlan {
        let target = try UpdateInstallationSandbox.canonical(target)
        try validateScope(requiredScope, target: target)
        guard entry.directory.deletingLastPathComponent().path == target.deletingLastPathComponent().path,
            entry.id == retentionID(entry.directory), entry.canClean
        else { throw UpdateFailure.changed }
        let inspected = try await inspectRetention(
            directory: entry.directory, target: target,
            ring: trustedKeyRing, scope: requiredScope)
        guard inspected.entry.canClean, inspected.entry.state == entry.state,
            inspected.entry.bytes == entry.bytes
        else { throw UpdateFailure.changed }
        return UpdateRetentionCleanupPlan(
            entry: inspected.entry, target: target, scope: requiredScope,
            parent: try UpdateNodeIdentity.read(target.deletingLastPathComponent(), directory: true),
            tree: inspected.tree, binding: inspected.binding)
    }

    public static func executeCleanup(_ plan: UpdateRetentionCleanupPlan, trustedKeyRing: UpdateKeyRing)
        async throws
    {
        let parentLease = try UpdateTransactionLease(
            directory: plan.target.deletingLastPathComponent(), name: ".WeGit-retention.lock")
        guard
            try UpdateNodeIdentity.read(plan.target.deletingLastPathComponent(), directory: true)
                == plan.parent
        else {
            throw UpdateFailure.changed
        }
        let inspected = try await inspectRetention(
            directory: plan.entry.directory, target: plan.target,
            ring: trustedKeyRing, scope: plan.scope, parentLease: parentLease)
        guard inspected.entry.canClean, inspected.entry.state == plan.entry.state,
            inspected.tree == plan.tree, inspected.binding == plan.binding
        else { throw UpdateFailure.changed }
        try await SnapshotIO.run { cancellation in
            defer { withExtendedLifetime(inspected.leases) {} }
            var progress =
                inspected.progress
                ?? UpdateCleanupProgress(
                    format: 1, entry: inspected.entry,
                    target: plan.target, scope: plan.scope, parent: plan.parent, tree: plan.tree,
                    binding: plan.binding, authorization: inspected.authorization, deleted: [], pending: nil,
                    rootRemoved: false)
            if inspected.progress == nil {
                guard try RepositoryNodeIdentity.readIfPresent(progress.url) == nil else {
                    throw UpdateFailure.changed
                }
                try progress.save()
            }
            try progress.execute(cancellation: cancellation)
        }
    }

    public static func diagnosticSummary(_ inventory: UpdateRetentionInventory) throws -> Data {
        struct Item: Encodable {
            let id: String
            let created: Date?
            let version: String?
            let build: UInt64?
            let state: UpdateRetentionState
            let bytes: Int64?
            let canClean: Bool
            let detail: String?
        }
        struct Summary: Encodable {
            let format = 1
            let recoveryBackup = false
            let includesUserData = false
            let totalBytes: Int64?
            let capacityBlocked: Bool
            let entries: [Item]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(
            Summary(
                totalBytes: inventory.totalBytes, capacityBlocked: inventory.capacityBlocked,
                entries: inventory.entries.map {
                    Item(
                        id: $0.id, created: $0.created, version: $0.version,
                        build: $0.build, state: $0.state, bytes: $0.bytes, canClean: $0.canClean,
                        detail: $0.detail)
                }))
    }

    private struct InspectedRetention: Sendable {
        let entry: UpdateRetentionEntry
        let tree: UpdateRetentionTree
        let binding: String
        let leases: [UpdateTransactionLease]
        let authorization: UpdateRetentionAuthorization
        let progress: UpdateCleanupProgress?
    }

    private static func inspectRetention(
        directory: URL, target: URL, ring: UpdateKeyRing, scope: UpdateHandoffScope,
        parentLease: UpdateTransactionLease? = nil
    ) async throws
        -> InspectedRetention
    {
        guard directory.deletingLastPathComponent().path == target.deletingLastPathComponent().path,
            UUID(uuidString: String(directory.lastPathComponent.dropFirst(".WeGit-update-".count))) != nil,
            directory.lastPathComponent.hasPrefix(".WeGit-update-"), !ring.keys.isEmpty
        else { throw UpdateFailure.changed }
        let cleanupURL = target.deletingLastPathComponent().appending(
            path: ".WeGit-cleanup-" + retentionID(directory) + ".json")
        if try RepositoryNodeIdentity.readIfPresent(cleanupURL) != nil {
            return try await inspectCleanupProgress(
                directory: directory, target: target, ring: ring,
                scope: scope, parentLease: parentLease)
        }
        if try RepositoryNodeIdentity.readIfPresent(directory.appending(path: "ticket.json")) != nil {
            let ticket = try loadTicket(at: directory.appending(path: "ticket.json"))
            let verified = try await readAndValidateForRecovery(
                ticket: ticket, trustedKeyRing: ring, requiredScope: scope)
            guard verified.request.target.path == target.path else { throw UpdateFailure.changed }
            return try await SnapshotIO.run { cancellation in
                let tree = try UpdateRetentionTree.read(directory, hashing: true, cancellation: cancellation)
                let journal = try readJournal(verified)
                let clean = try cleanableRetention(
                    verified, journal: journal, tree: tree, cancellation: cancellation)
                let state: UpdateRetentionState
                switch journal.phase {
                case .prepared: state = .prepared
                case .sourceExited, .swapIntent, .awaitingLaunch: state = .awaitingLaunch
                case .launchVerified: state = .completed
                case .rolledBack: state = .rolledBack
                case .rollbackIntent, .blocked: state = .blocked
                }
                return InspectedRetention(
                    entry: UpdateRetentionEntry(
                        id: retentionID(directory), directory: directory,
                        created: verified.request.created, version: verified.update.manifest.version,
                        build: verified.update.manifest.build, state: state, bytes: tree.bytes,
                        canClean: clean,
                        detail: clean ? nil : "recovery-required"), tree: tree,
                    binding: hash(try encode(journal)) + ":" + ticket.documentSHA256,
                    leases: [verified.lease] + (parentLease.map { [$0] } ?? []),
                    authorization: UpdateRetentionAuthorization(
                        signedManifest: verified.request.signedManifest,
                        installedVersion: verified.request.installedVersion,
                        installedBuild: verified.request.installedBuild,
                        installedVariant: verified.request.installedVariant,
                        created: verified.request.created,
                        helper: try retainedHelper(verified.request),
                        evidence: try retentionEvidence(directory: directory, tree: tree)), progress: nil)
            }
        }
        return try await SnapshotIO.run { cancellation in
            let lease = try UpdateTransactionLease(directory: directory, create: false)
            let tree = try UpdateRetentionTree.read(directory, hashing: true, cancellation: cancellation)
            let data = try UpdateInstaller.readSmall(
                directory.appending(path: "preparation.json"), limit: 2 * 1024 * 1024)
            let preparation = try decode(UpdatePreparationRecord.self, data: data)
            guard preparation.format == 1, preparation.scope == scope, preparation.target.path == target.path,
                directory.lastPathComponent == ".WeGit-update-" + preparation.id.uuidString,
                preparation.parentIdentity
                    == (try UpdateNodeIdentity.read(target.deletingLastPathComponent(), directory: true)),
                preparation.storageIdentity == tree.root
            else { throw UpdateFailure.changed }
            let envelope = try JSONDecoder().decode(
                SignedUpdateManifest.self, from: preparation.signedManifest)
            let metadata = try JSONDecoder().decode(UpdateManifest.self, from: envelope.payload)
            let installed = try InstalledUpdateVersion(
                version: preparation.installedVersion,
                build: preparation.installedBuild, variant: preparation.installedVariant)
            guard
                case .available(let update) = try UpdateManifestValidator.validate(
                    preparation.signedManifest,
                    ring: ring, channel: metadata.channel, installed: installed, now: preparation.created)
            else { throw UpdateFailure.changed }
            try validatePreparation(preparation, update: update)
            let targetMatches = try fingerprint(target, cancellation) == preparation.oldApp
            let matches = preparation.matches(tree) && targetMatches
            return InspectedRetention(
                entry: UpdateRetentionEntry(
                    id: retentionID(directory), directory: directory,
                    created: preparation.created, version: update.manifest.version,
                    build: update.manifest.build,
                    state: .preparing, bytes: tree.bytes, canClean: matches,
                    detail: matches ? nil : "preparation-incomplete"), tree: tree, binding: hash(data),
                leases: [lease] + (parentLease.map { [$0] } ?? []),
                authorization: UpdateRetentionAuthorization(
                    signedManifest: preparation.signedManifest,
                    installedVersion: preparation.installedVersion,
                    installedBuild: preparation.installedBuild,
                    installedVariant: preparation.installedVariant, created: preparation.created, helper: nil,
                    evidence: try retentionEvidence(directory: directory, tree: tree)),
                progress: nil)
        }
    }

    private static func cleanableRetention(
        _ verified: VerifiedUpdateHandoff, journal: UpdateInstallJournal,
        tree: UpdateRetentionTree, cancellation: IOCancellation
    ) throws -> Bool {
        guard !journal.preferencesRestoreRequired, !journal.storeRestoreRequired else { return false }
        let request = verified.request
        guard tree.files["lock"]?.bytes == 0, tree.files["lock"]?.mode == 0o600 else { return false }
        if try RepositoryNodeIdentity.readIfPresent(request.helperReadyURL) != nil {
            let ready = try decode(
                UpdateHelperReadiness.self,
                data: UpdateInstaller.readSmall(request.helperReadyURL, limit: 16 * 1024))
            guard ready.id == request.id, ready.documentSHA256 == verified.ticket.documentSHA256,
                ready.authorizationSHA256 == request.authorizationSHA256,
                ready.source == request.source, !ready.helper.stillRunning()
            else { throw UpdateFailure.busy }
        }
        let metadata: Set<String> = [
            "lock", "ticket.json", "request.json", "journal.json", "preparation.json",
            "archive.dmg", "package-manifest.json", "original-preferences.plist", "current-preferences.plist",
            "current-store-backup.plist", "helper-ready.json", "helper-aborted.json", "source-abort.json",
            "ready.json",
        ]
        let prefixes = [
            "Replacement.app/", "Previous.app/", "FailedReplacement.app/",
            "Installer/Resources/WeGit_WeGitCore.bundle/",
        ]
        guard
            tree.files.keys.allSatisfy({
                metadata.contains($0) || $0 == "Installer/Helpers/WeGitUpdater"
                    || prefixes.contains(where: $0.hasPrefix)
            }),
            tree.directories.keys.allSatisfy({
                [
                    "Replacement.app", "Previous.app", "FailedReplacement.app", "Installer",
                    "Installer/Helpers",
                    "Installer/Resources", "Installer/Resources/WeGit_WeGitCore.bundle",
                ].contains($0)
                    || prefixes.contains(where: $0.hasPrefix)
            })
        else { return false }
        for (url, expected) in [
            (request.stage, request.newApp), (request.previousApp, request.oldApp),
            (request.directory.appending(path: "FailedReplacement.app"), request.newApp),
        ] {
            if let actual = try optionalFingerprint(url, cancellation), actual != expected { return false }
        }
        switch journal.phase {
        case .launchVerified:
            guard let ready = journal.readiness, let launched = journal.launchedProcess,
                ready.process == launched, ready.id == request.id,
                ready.documentSHA256 == verified.ticket.documentSHA256,
                ready.authorizationSHA256 == request.authorizationSHA256, ready.migrationCompleted,
                ready.windowsRestored, ready.preferencesFlushed,
                ready.version == verified.update.manifest.version,
                ready.build == verified.update.manifest.build, journal.sourceExitStatus == 0,
                journal.sourceExitObservedAt != nil
            else { return false }
            return true
        case .rolledBack:
            return try fingerprint(request.target, cancellation) == request.oldApp
        case .blocked:
            guard
                let abort = try? decode(
                    UpdateHelperAbort.self,
                    data: UpdateInstaller.readSmall(
                        request.directory.appending(path: "helper-aborted.json"), limit: 16 * 1024)),
                abort.id == request.id, abort.documentSHA256 == verified.ticket.documentSHA256,
                abort.authorizationSHA256 == request.authorizationSHA256
            else { return false }
            return try fingerprint(request.target, cancellation) == request.oldApp
        default: return false
        }
    }

    private static func retentionID(_ directory: URL) -> String {
        let name = directory.lastPathComponent
        let suffix = String(name.dropFirst(".WeGit-update-".count))
        return UUID(uuidString: suffix)?.uuidString ?? "unverified-"
            + String(hash(Data(name.utf8)).prefix(16))
    }
    private static func retentionDirectories(_ parent: URL) throws -> [URL] {
        let paths = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        guard paths.count <= 10_000 else { throw UpdateFailure.exceeded }
        var values = Dictionary(
            uniqueKeysWithValues: paths.filter { $0.lastPathComponent.hasPrefix(".WeGit-update-") }.map {
                ($0.path, $0)
            })
        for path in paths where path.lastPathComponent.hasPrefix(".WeGit-cleanup-") {
            let name = path.lastPathComponent
            let suffix = String(name.dropFirst(".WeGit-cleanup-".count).dropLast(".json".count))
            guard name.hasSuffix(".json"), let id = UUID(uuidString: suffix) else {
                values[path.path] = path
                continue
            }
            let directory = parent.appending(path: ".WeGit-update-" + id.uuidString)
            values[directory.path] = directory
        }
        guard values.count <= 100 else { throw UpdateFailure.exceeded }
        return values.values.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private static func cleanupURL(_ directory: URL) -> URL {
        directory.deletingLastPathComponent().appending(
            path: ".WeGit-cleanup-" + retentionID(directory) + ".json")
    }
    private static func retainedBytes(_ directory: URL, cancellation: IOCancellation) throws -> Int64 {
        var bytes: Int64 = 0
        if try RepositoryNodeIdentity.readIfPresent(directory) != nil {
            bytes = try UpdateRetentionTree.read(directory, hashing: false, cancellation: cancellation).bytes
        }
        let sidecar = cleanupURL(directory)
        if let node = try RepositoryNodeIdentity.readIfPresent(sidecar) {
            guard node.kind == UInt16(S_IFREG), let size = node.markerSize,
                (0...4 * 1024 * 1024).contains(size),
                bytes <= 1024 * 1024 * 1024 - size
            else { throw UpdateFailure.exceeded }
            bytes += size
        }
        return bytes
    }
    private static func recognizeRetention(_ directory: URL) throws {
        let sidecar = cleanupURL(directory)
        if try RepositoryNodeIdentity.readIfPresent(sidecar) != nil {
            let progress = try readCleanupProgress(sidecar)
            guard progress.entry.directory.path == directory.path else { throw UpdateFailure.changed }
            _ = try progress.validateRemaining(cancellation: IOCancellation())
        } else if try RepositoryNodeIdentity.readIfPresent(directory.appending(path: "ticket.json")) != nil {
            let ticket = try loadTicket(at: directory.appending(path: "ticket.json"))
            let request = try readRequest(ticket)
            let journal = try decode(
                UpdateInstallJournal.self,
                data: UpdateInstaller.readSmall(request.journal, limit: 64 * 1024))
            guard journal.format == 1, journal.id == ticket.id,
                journal.handoffSHA256 == ticket.documentSHA256
            else { throw UpdateFailure.changed }
        } else {
            let preparation = try decode(
                UpdatePreparationRecord.self,
                data: UpdateInstaller.readSmall(
                    directory.appending(path: "preparation.json"), limit: 2 * 1024 * 1024))
            guard preparation.format == 1,
                directory.lastPathComponent == ".WeGit-update-" + preparation.id.uuidString,
                preparation.storageIdentity == (try UpdateNodeIdentity.read(directory, directory: true)),
                preparation.parentIdentity
                    == (try UpdateNodeIdentity.read(directory.deletingLastPathComponent(), directory: true))
            else { throw UpdateFailure.changed }
        }
    }
    private static func readCleanupProgress(_ url: URL) throws -> UpdateCleanupProgress {
        let node = try UpdateNodeIdentity.read(url)
        guard node.owner == getuid(), node.permissions == 0o600 else { throw UpdateFailure.changed }
        let progress = try decode(
            UpdateCleanupProgress.self, data: UpdateInstaller.readSmall(url, limit: 4 * 1024 * 1024))
        guard progress.url.path == url.path else { throw UpdateFailure.changed }
        return progress
    }
    private static func inspectCleanupProgress(
        directory: URL, target: URL, ring: UpdateKeyRing,
        scope: UpdateHandoffScope, parentLease: UpdateTransactionLease?
    ) async throws -> InspectedRetention {
        let parentLease =
            try parentLease
            ?? UpdateTransactionLease(
                directory: target.deletingLastPathComponent(),
                create: false, name: ".WeGit-retention.lock")
        return try await SnapshotIO.run { cancellation in
            let progress = try readCleanupProgress(cleanupURL(directory))
            guard progress.target.path == target.path, progress.scope == scope,
                progress.entry.canClean, progress.entry.directory.path == directory.path
            else { throw UpdateFailure.changed }
            try validateCleanupAuthorization(progress, ring: ring, cancellation: cancellation)
            let authorization = progress.authorization
            if authorization.helper?.stillRunning() == true { throw UpdateFailure.busy }
            let envelope = try JSONDecoder().decode(
                SignedUpdateManifest.self, from: authorization.signedManifest)
            let metadata = try JSONDecoder().decode(UpdateManifest.self, from: envelope.payload)
            let installed = try InstalledUpdateVersion(
                version: authorization.installedVersion,
                build: authorization.installedBuild, variant: authorization.installedVariant)
            guard
                case .available(let update) = try UpdateManifestValidator.validate(
                    authorization.signedManifest,
                    ring: ring, channel: metadata.channel, installed: installed, now: authorization.created),
                update.manifest.version == progress.entry.version,
                update.manifest.build == progress.entry.build
            else {
                throw UpdateFailure.changed
            }
            var leases = [parentLease]
            if try RepositoryNodeIdentity.readIfPresent(directory.appending(path: "lock")) != nil {
                leases.append(try UpdateTransactionLease(directory: directory, create: false))
            }
            _ = try progress.validateRemaining(cancellation: cancellation)
            let bytes = try retainedBytes(directory, cancellation: cancellation)
            return InspectedRetention(
                entry: UpdateRetentionEntry(
                    id: progress.entry.id, directory: directory,
                    created: progress.entry.created, version: progress.entry.version,
                    build: progress.entry.build,
                    state: progress.entry.state, bytes: bytes, canClean: true, detail: nil),
                tree: progress.tree, binding: hash(try progress.encoded()), leases: leases,
                authorization: authorization, progress: progress)
        }
    }
    private static func retainedHelper(_ request: UpdateHandoffRequest) throws -> UpdateProcessIdentity? {
        guard try RepositoryNodeIdentity.readIfPresent(request.helperReadyURL) != nil else { return nil }
        return try decode(
            UpdateHelperReadiness.self,
            data: UpdateInstaller.readSmall(request.helperReadyURL, limit: 16 * 1024)
        ).helper
    }

    private static func preparationRecord(
        plan: UpdateInstallPlan, source: UpdateProcessIdentity,
        scope: UpdateHandoffScope, directory: URL, helperPath: URL, resourcePath: URL,
        download: UpdateDownload, cancellation: IOCancellation
    ) throws -> UpdatePreparationRecord {
        var files: [String: UpdatePreparationRecord.File] = [:]
        var directories: Set<String> = [
            "Replacement.app", "Installer", "Installer/Helpers", "Installer/Resources",
            "Installer/Resources/WeGit_WeGitCore.bundle",
        ]
        func addTree(_ tree: UpdateAppTree, prefix: String) {
            for (path, file) in tree.files {
                files[prefix + path] = .init(bytes: file.identity.markerSize!, sha256: file.hash)
            }
            for path in tree.directories.keys { directories.insert(prefix + path) }
        }
        addTree(plan.newTree, prefix: "Replacement.app/")
        addTree(
            try UpdateAppTree.read(resourcePath, cancellation: cancellation),
            prefix: "Installer/Resources/WeGit_WeGitCore.bundle/")
        let helper = plan.oldTree.files["Contents/Helpers/WeGitUpdater"]!
        files["Installer/Helpers/WeGitUpdater"] = .init(
            bytes: helper.identity.markerSize!, sha256: helper.hash)
        files["archive.dmg"] = .init(bytes: download.byteCount, sha256: download.sha256)
        for (name, data) in [
            ("original-preferences.plist", plan.backup.originalPreferences),
            ("current-preferences.plist", plan.backup.currentPreferences),
            ("package-manifest.json", plan.packageManifest),
        ] {
            files[name] = .init(bytes: Int64(data.count), sha256: hash(data))
        }
        if let store = plan.backup.currentStoreBackup {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(store)
            files["current-store-backup.plist"] = .init(bytes: Int64(data.count), sha256: hash(data))
        }
        return UpdatePreparationRecord(
            format: 1, id: plan.id, created: Date(), scope: scope,
            target: plan.currentApp,
            parentIdentity: try UpdateNodeIdentity.read(
                plan.currentApp.deletingLastPathComponent(), directory: true),
            storageIdentity: try UpdateNodeIdentity.read(directory, directory: true), source: source,
            signedManifest: plan.update.signedManifest, packageManifest: plan.packageManifest,
            installedVersion: plan.update.installed.version.rawValue,
            installedBuild: plan.update.installed.build, installedVariant: plan.update.installed.variant,
            oldApp: try fingerprint(plan.currentApp, cancellation), files: files, directories: directories)
    }
    private static func savePreparation(_ preparation: UpdatePreparationRecord, directory: URL) throws {
        let data = try encode(preparation)
        guard data.count <= 2 * 1024 * 1024 else { throw UpdateFailure.exceeded }
        let temporary = directory.appending(path: "preparation-" + UUID().uuidString + ".tmp")
        try UpdateInstaller.exclusiveWrite(data, to: temporary)
        guard rename(temporary.path, directory.appending(path: "preparation.json").path) == 0 else {
            throw UpdateFailure.changed
        }
        try UpdateInstaller.sync(directory)
        try UpdateInstaller.sync(directory.deletingLastPathComponent())
    }
}

extension ProductionUpdateInstaller {
    private static let retentionMetadata: Set<String> = [
        "ticket.json", "request.json", "journal.json", "preparation.json", "package-manifest.json",
        "helper-ready.json", "helper-aborted.json", "source-abort.json", "ready.json",
    ]
    private static func retentionEvidence(directory: URL, tree: UpdateRetentionTree) throws -> [String: Data]
    {
        var result: [String: Data] = [:]
        var total = 0
        for name in retentionMetadata where tree.files[name] != nil {
            let data = try UpdateInstaller.readSmall(directory.appending(path: name), limit: 2 * 1024 * 1024)
            total += data.count
            guard total <= 3 * 1024 * 1024, hash(data) == tree.files[name]?.sha256 else {
                throw UpdateFailure.changed
            }
            result[name] = data
        }
        return result
    }
    private static func validateCleanupAuthorization(
        _ progress: UpdateCleanupProgress, ring: UpdateKeyRing,
        cancellation: IOCancellation
    ) throws {
        let tree = progress.tree
        let evidence = progress.authorization.evidence
        guard progress.entry.canClean, tree.root.owner == getuid(), tree.root.permissions == 0o700,
            tree.files["lock"]?.bytes == 0, tree.files["lock"]?.mode == 0o600,
            evidence.keys.allSatisfy(retentionMetadata.contains)
        else { throw UpdateFailure.changed }
        for (name, data) in evidence {
            guard let file = tree.files[name], Int64(data.count) == file.bytes, hash(data) == file.sha256
            else {
                throw UpdateFailure.changed
            }
        }
        guard Set(tree.files.keys).intersection(retentionMetadata) == Set(evidence.keys) else {
            throw UpdateFailure.changed
        }
        if evidence["ticket.json"] == nil {
            guard progress.entry.state == .preparing, let data = evidence["preparation.json"] else {
                throw UpdateFailure.changed
            }
            let preparation = try decode(UpdatePreparationRecord.self, data: data)
            guard preparation.format == 1, preparation.matches(tree), preparation.scope == progress.scope,
                preparation.id.uuidString == progress.entry.id,
                preparation.target.path == progress.target.path,
                preparation.storageIdentity == tree.root, preparation.parentIdentity == progress.parent,
                hash(data) == progress.binding,
                preparation.signedManifest == progress.authorization.signedManifest,
                preparation.installedVersion == progress.authorization.installedVersion,
                preparation.installedBuild == progress.authorization.installedBuild,
                preparation.installedVariant == progress.authorization.installedVariant,
                preparation.created == progress.authorization.created,
                progress.authorization.helper == nil,
                try fingerprint(progress.target, cancellation) == preparation.oldApp
            else { throw UpdateFailure.changed }
            let envelope = try JSONDecoder().decode(
                SignedUpdateManifest.self, from: preparation.signedManifest)
            let metadata = try JSONDecoder().decode(UpdateManifest.self, from: envelope.payload)
            let installed = try InstalledUpdateVersion(
                version: preparation.installedVersion,
                build: preparation.installedBuild, variant: preparation.installedVariant)
            guard
                case .available(let update) = try UpdateManifestValidator.validate(
                    preparation.signedManifest,
                    ring: ring, channel: metadata.channel, installed: installed, now: preparation.created)
            else { throw UpdateFailure.changed }
            try validatePreparation(preparation, update: update)
            return
        }
        guard let ticketData = evidence["ticket.json"], let requestData = evidence["request.json"],
            let journalData = evidence["journal.json"], let packageData = evidence["package-manifest.json"]
        else { throw UpdateFailure.changed }
        let ticket = try decode(UpdateHandoffTicket.self, data: ticketData)
        let request = try decode(UpdateHandoffRequest.self, data: requestData)
        let journal = try decode(UpdateInstallJournal.self, data: journalData)
        guard ticket.id.uuidString == progress.entry.id, ticket.directory == progress.entry.directory.path,
            request.format == 1, request.id == ticket.id, request.directory.path == ticket.directory,
            hash(requestData) == ticket.documentSHA256,
            hash(Data(ticket.token.utf8)) == request.authorizationSHA256,
            request.target.path == progress.target.path, request.scope == progress.scope,
            request.parentIdentity == progress.parent, request.storageIdentity == tree.root,
            journal.format == 1, journal.id == ticket.id, journal.handoffSHA256 == ticket.documentSHA256,
            !journal.preferencesRestoreRequired, !journal.storeRestoreRequired,
            hash(try encode(journal)) + ":" + ticket.documentSHA256 == progress.binding,
            request.signedManifest == progress.authorization.signedManifest,
            request.installedVersion == progress.authorization.installedVersion,
            request.installedBuild == progress.authorization.installedBuild,
            request.installedVariant == progress.authorization.installedVariant,
            request.created == progress.authorization.created
        else { throw UpdateFailure.changed }
        let envelope = try JSONDecoder().decode(SignedUpdateManifest.self, from: request.signedManifest)
        let metadata = try JSONDecoder().decode(UpdateManifest.self, from: envelope.payload)
        let installed = try InstalledUpdateVersion(
            version: request.installedVersion, build: request.installedBuild,
            variant: request.installedVariant)
        guard
            case .available(let update) = try UpdateManifestValidator.validate(
                request.signedManifest,
                ring: ring, channel: metadata.channel, installed: installed, now: request.created),
            request.archive.sha256 == update.artifact.sha256,
            request.archive.bytes == update.artifact.downloadBytes,
            request.packageManifest.sha256 == update.artifact.manifestSHA256,
            hash(packageData) == update.artifact.manifestSHA256
        else { throw UpdateFailure.changed }
        let metadataFiles: Set<String> = retentionMetadata.union([
            "lock", "archive.dmg", "original-preferences.plist", "current-preferences.plist",
            "current-store-backup.plist",
        ])
        let prefixes = [
            "Replacement.app/", "Previous.app/", "FailedReplacement.app/",
            "Installer/Resources/WeGit_WeGitCore.bundle/",
        ]
        guard
            tree.files.keys.allSatisfy({
                metadataFiles.contains($0) || $0 == "Installer/Helpers/WeGitUpdater"
                    || prefixes.contains(where: $0.hasPrefix)
            }),
            tree.directories.keys.allSatisfy({
                [
                    "Replacement.app", "Previous.app", "FailedReplacement.app", "Installer",
                    "Installer/Helpers", "Installer/Resources", "Installer/Resources/WeGit_WeGitCore.bundle",
                ].contains($0) || prefixes.contains(where: $0.hasPrefix)
            })
        else { throw UpdateFailure.changed }
        for stored in [
            request.archive, request.packageManifest, request.originalPreferences, request.currentPreferences,
            request.helper,
        ] + (request.currentStoreBackup.map { [$0] } ?? []) {
            guard let file = tree.files[stored.name], file.bytes == stored.bytes,
                file.sha256 == stored.sha256,
                Int64(file.node.device) == stored.identity.device, file.node.inode == stored.identity.inode,
                file.node.kind == stored.identity.kind, file.node.bornSeconds == stored.identity.bornSeconds,
                file.node.bornNanoseconds == stored.identity.bornNanoseconds,
                file.mode == stored.identity.permissions
            else { throw UpdateFailure.changed }
        }
        guard try tree.fingerprint("Installer/Resources/WeGit_WeGitCore.bundle") == request.helperResources
        else { throw UpdateFailure.changed }
        for (prefix, expected) in [
            ("Replacement.app", request.newApp), ("Previous.app", request.oldApp),
            ("FailedReplacement.app", request.newApp),
        ] {
            if let fingerprint = try tree.fingerprint(prefix), fingerprint != expected {
                throw UpdateFailure.changed
            }
        }
        if let readyData = evidence["helper-ready.json"] {
            let ready = try decode(UpdateHelperReadiness.self, data: readyData)
            guard ready.id == request.id, ready.documentSHA256 == ticket.documentSHA256,
                ready.authorizationSHA256 == request.authorizationSHA256, ready.source == request.source,
                ready.helper == progress.authorization.helper
            else { throw UpdateFailure.changed }
        } else {
            guard progress.authorization.helper == nil else { throw UpdateFailure.changed }
        }
        switch journal.phase {
        case .launchVerified:
            guard progress.entry.state == .completed, let ready = journal.readiness,
                ready.process == journal.launchedProcess, ready.id == request.id,
                ready.documentSHA256 == ticket.documentSHA256,
                ready.authorizationSHA256 == request.authorizationSHA256,
                ready.migrationCompleted, ready.windowsRestored, ready.preferencesFlushed,
                ready.version == update.manifest.version, ready.build == update.manifest.build,
                journal.sourceExitStatus == 0, journal.sourceExitObservedAt != nil
            else { throw UpdateFailure.changed }
        case .rolledBack:
            guard progress.entry.state == .rolledBack,
                try fingerprint(progress.target, cancellation) == request.oldApp
            else { throw UpdateFailure.changed }
        case .blocked:
            guard progress.entry.state == .blocked, let data = evidence["helper-aborted.json"] else {
                throw UpdateFailure.changed
            }
            let abort = try decode(UpdateHelperAbort.self, data: data)
            guard abort.id == request.id, abort.documentSHA256 == ticket.documentSHA256,
                abort.authorizationSHA256 == request.authorizationSHA256,
                try fingerprint(progress.target, cancellation) == request.oldApp
            else { throw UpdateFailure.changed }
        default: throw UpdateFailure.changed
        }
    }
}

extension ProductionUpdateInstaller {
    private static func validatePreparation(_ preparation: UpdatePreparationRecord, update: TrustedUpdate)
        throws
    {
        guard preparation.source.owner == getuid(),
            preparation.source.executable == preparation.target.appending(path: "Contents/MacOS/WeGit").path,
            preparation.files["archive.dmg"]?.sha256 == update.artifact.sha256,
            preparation.files["archive.dmg"]?.bytes == update.artifact.downloadBytes,
            preparation.files["package-manifest.json"]?.sha256 == update.artifact.manifestSHA256,
            hash(preparation.packageManifest) == update.artifact.manifestSHA256,
            preparation.packageManifest.count <= UpdateManifestValidator.metadataBytes
        else { throw UpdateFailure.changed }
        guard
            let package = try JSONSerialization.jsonObject(with: preparation.packageManifest)
                as? [String: Any],
            package["version"] as? String == String(update.manifest.version.split(separator: "-")[0]),
            package["releaseTag"] as? String == update.manifest.tag,
            package["buildVersion"] as? String == String(update.manifest.build),
            package["gitCommit"] as? String == update.manifest.sourceCommit,
            package["archiveSHA256"] as? String == update.artifact.sha256
        else { throw UpdateFailure.changed }
    }
}
