import CryptoKit
import Darwin
import Foundation

public enum UpdateHandoffScope: String, Codable, Sendable { case production, isolatedControl }

public struct UpdateNodeIdentity: Codable, Equatable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public let kind: UInt16
    public let bornSeconds: Int64
    public let bornNanoseconds: Int64
    public let owner: UInt32
    public let permissions: UInt16

    static func read(_ url: URL, directory: Bool = false) throws -> Self {
        let node = try RepositoryNodeIdentity.read(url, directory: directory)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid() || directory else {
            throw UpdateFailure.changed
        }
        return Self(
            device: Int64(node.device), inode: UInt64(node.inode), kind: node.kind,
            bornSeconds: Int64(node.bornSeconds), bornNanoseconds: Int64(node.bornNanoseconds),
            owner: info.st_uid, permissions: info.st_mode & 0o777)
    }
}

public struct UpdateAppFingerprint: Codable, Equatable, Sendable {
    public let root: UpdateNodeIdentity
    public let bytes: Int64
    public let contentSHA256: String
    public let stampSHA256: String

    static func capture(_ url: URL, cancellation: IOCancellation) throws -> Self {
        let tree = try UpdateAppTree.read(url, cancellation: cancellation)
        var content = SHA256()
        var stamps = SHA256()
        for path in tree.files.keys.sorted() {
            let file = tree.files[path]!
            let data = try UpdateManifestValidator.canonicalJSON([path, String(file.mode), file.hash])
            content.update(data: data)
            stamps.update(data: data)
            stamps.update(data: try nodeBytes(file.identity))
        }
        for path in tree.directories.keys.sorted() {
            let data = try UpdateManifestValidator.canonicalJSON([path, "directory"])
            content.update(data: data)
            stamps.update(data: data)
            stamps.update(data: try nodeBytes(tree.directories[path]!))
        }
        return Self(
            root: try UpdateNodeIdentity.read(url, directory: true), bytes: tree.bytes,
            contentSHA256: hex(content.finalize()), stampSHA256: hex(stamps.finalize()))
    }

    private static func nodeBytes(_ node: RepositoryNodeIdentity) throws -> Data {
        var values = [
            String(node.device), String(node.inode), String(node.kind), String(node.bornSeconds),
            String(node.bornNanoseconds),
        ]
        values.append(node.markerSize.map { String($0) } ?? "")
        values.append(node.markerModifiedSeconds.map { String($0) } ?? "")
        values.append(node.markerModifiedNanoseconds.map { String($0) } ?? "")
        values.append(node.markerChangedSeconds.map { String($0) } ?? "")
        values.append(node.markerChangedNanoseconds.map { String($0) } ?? "")
        return try UpdateManifestValidator.canonicalJSON(values)
    }
    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct UpdateStoredFile: Codable, Equatable, Sendable {
    public let name: String
    public let bytes: Int64
    public let sha256: String
    public let identity: UpdateNodeIdentity
}

public struct UpdateProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let owner: UInt32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let executable: String
    public let executableIdentity: UpdateNodeIdentity

    public static func capture(pid: Int32 = getpid()) throws -> Self {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
            info.pbi_uid == getuid()
        else { throw UpdateFailure.changed }
        var bytes = [UInt8](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { throw UpdateFailure.changed }
        let path = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        let executable = try UpdateInstallationSandbox.canonical(URL(fileURLWithPath: path))
        return Self(
            pid: pid, owner: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec, executable: executable.path,
            executableIdentity: try UpdateNodeIdentity.read(executable))
    }

    public func stillRunning() -> Bool {
        // A reused PID is another process, not the original instance.
        (try? Self.capture(pid: pid)) == self
    }
}

public struct UpdateNormalExitPermit: Sendable {
    public let source: UpdateProcessIdentity
    public let observedAt: Date
    public let exitStatus: Int32
    fileprivate init(source: UpdateProcessIdentity, observedAt: Date, exitStatus: Int32) {
        self.source = source
        self.observedAt = observedAt
        self.exitStatus = exitStatus
    }
}

public struct UpdateObservedExit: Sendable {
    public let source: UpdateProcessIdentity
    public let observedAt: Date
    public let exitStatus: Int32
}

/// Register before acknowledging helper readiness. Only a kernel-observed normal
/// exit creates an install permit; ESRCH and PID disappearance are insufficient.
public final class UpdateSourceProcessMonitor: @unchecked Sendable {
    public let identity: UpdateProcessIdentity
    private let descriptor: Int32
    private let lock = NSLock()
    private var consumed = false

    public init(identity: UpdateProcessIdentity) throws {
        guard identity.stillRunning() else { throw UpdateFailure.changed }
        self.identity = identity
        descriptor = kqueue()
        guard descriptor >= 0 else { throw UpdateFailure.changed }
        var event = kevent(
            ident: UInt(identity.pid), filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil)
        if kevent(descriptor, &event, 1, nil, 0, nil) != 0 {
            close(descriptor)
            throw UpdateFailure.changed
        }
    }
    deinit { close(descriptor) }

    public func waitForNormalExit(timeout: TimeInterval = 60) async throws -> UpdateNormalExitPermit {
        let observed = try await waitForExit(timeout: timeout)
        guard observed.exitStatus == 0 else { throw UpdateFailure.busy }
        return UpdateNormalExitPermit(
            source: observed.source, observedAt: observed.observedAt, exitStatus: observed.exitStatus)
    }

    public func waitForExit(timeout: TimeInterval = 60) async throws -> UpdateObservedExit {
        guard timeout > 0, timeout <= 60,
            lock.withLock({
                if consumed { return false }
                consumed = true
                return true
            })
        else {
            throw UpdateFailure.changed
        }
        return try await SnapshotIO.run { cancellation in
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                try cancellation.check()
                var event = kevent()
                var wait = timespec(tv_sec: 0, tv_nsec: 100_000_000)
                let count = kevent(self.descriptor, nil, 0, &event, 1, &wait)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw UpdateFailure.changed }
                if count == 0 { continue }
                guard event.ident == UInt(self.identity.pid), event.fflags & UInt32(NOTE_EXIT) != 0,
                    event.flags & UInt16(EV_ERROR) == 0
                else { throw UpdateFailure.busy }
                return UpdateObservedExit(
                    source: self.identity, observedAt: Date(),
                    exitStatus: Int32(truncatingIfNeeded: event.data))
            }
            throw UpdateFailure.busy
        }
    }
}

public struct UpdateHandoffTicket: Codable, Equatable, Sendable {
    public let id: UUID
    public let directory: String
    /// Private pipe/file secret, never a command-line argument or signing key.
    public let token: String
    public let documentSHA256: String
    public var ticketURL: URL { URL(fileURLWithPath: directory).appending(path: "ticket.json") }
    public static func load(from url: URL) throws -> Self {
        let data = try UpdateInstaller.readSmall(url, limit: 16 * 1024)
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct UpdateHandoffRequest: Codable, Sendable {
    public let format: Int
    public let id: UUID
    public let created: Date
    public let scope: UpdateHandoffScope
    public let source: UpdateProcessIdentity
    public let target: URL
    public let directory: URL
    public var originalProcess: UpdateProcessIdentity { source }
    public var stage: URL { directory.appending(path: "Replacement.app") }
    public var previousApp: URL { directory.appending(path: "Previous.app") }
    public var journal: URL { directory.appending(path: "journal.json") }
    public var readyURL: URL { directory.appending(path: "ready.json") }
    public var helperReadyURL: URL { directory.appending(path: "helper-ready.json") }
    public var helperExecutable: URL { directory.appending(path: "Installer/Helpers/WeGitUpdater") }
    public var helperResourcesURL: URL {
        directory.appending(path: "Installer/Resources/WeGit_WeGitCore.bundle")
    }
    public let parentIdentity: UpdateNodeIdentity
    public let storageIdentity: UpdateNodeIdentity
    public let authorizationSHA256: String
    public let preferencesDomain: String
    public let windowIDs: [UUID]
    public let persistenceGeneration: UInt64
    public let installedVersion: String
    public let installedBuild: UInt64
    public let installedVariant: UpdateVariant
    public let signedManifest: Data
    public let oldApp: UpdateAppFingerprint
    public let newApp: UpdateAppFingerprint
    public let archive: UpdateStoredFile
    public let packageManifest: UpdateStoredFile
    public let originalPreferences: UpdateStoredFile
    public let currentPreferences: UpdateStoredFile
    public let currentStoreBackup: UpdateStoredFile?
    public let helper: UpdateStoredFile
    public let helperResources: UpdateAppFingerprint
}

public enum UpdateInstallPhase: String, Codable, Sendable {
    case prepared, sourceExited, swapIntent, awaitingLaunch, launchVerified, rollbackIntent, rolledBack,
        blocked
}

public struct UpdateInstallJournal: Codable, Sendable {
    public var format = 1
    public let id: UUID
    public let handoffSHA256: String
    public var revision: UInt64 = 0
    public var phase: UpdateInstallPhase = .prepared
    public var sourceExitObservedAt: Date?
    public var sourceExitStatus: Int32?
    public var preferencesRestoreRequired = false
    public var storeRestoreRequired = false
    public var readiness: UpdateLaunchReadiness?
    public var launchedProcess: UpdateProcessIdentity?
    public var launchedExitObservedAt: Date?
    public var launchedExitStatus: Int32?
    public var detail: String?
}

public struct UpdateHelperReadiness: Codable, Sendable {
    public let id: UUID
    public let documentSHA256: String
    public let authorizationSHA256: String
    public let helper: UpdateProcessIdentity
    public let source: UpdateProcessIdentity
}

public struct UpdateHelperAbort: Codable, Sendable {
    public let id: UUID
    public let documentSHA256: String
    public let authorizationSHA256: String
    public let reason: String
}

public struct UpdateSourceAbort: Codable, Sendable {
    public let id: UUID
    public let documentSHA256: String
    public let authorizationSHA256: String
    public let source: UpdateProcessIdentity
    public let reason: String
}

public struct UpdateLaunchReadiness: Codable, Sendable {
    public let id: UUID
    public let documentSHA256: String
    public let authorizationSHA256: String
    public let process: UpdateProcessIdentity
    public let version: String
    public let build: UInt64
    public let variant: UpdateVariant
    public let migrationCompleted: Bool
    public let windowsRestored: Bool
    public let preferencesFlushed: Bool
}

public struct UpdatePreferencesRestoration: Sendable {
    public let transactionID: UUID
    public let domainName: String
    public let bytes: Data
    public let sha256: String
}

public struct PersistentUpdateReceipt: Sendable {
    public let ticket: UpdateHandoffTicket
    public let phase: UpdateInstallPhase
    public let installedApp: URL
    public let previousApp: URL
    public let preferencesRestoration: UpdatePreferencesRestoration?
    public let storeRestoration: ApplicationStoreBackup?
    public var currentApp: URL { installedApp }
    public var readyURL: URL { URL(fileURLWithPath: ticket.directory).appending(path: "ready.json") }
    public var journalURL: URL { URL(fileURLWithPath: ticket.directory).appending(path: "journal.json") }
}

public enum UpdateRecoveryDecision: Sendable {
    case prepared(PersistentUpdateReceipt)
    case awaitingLaunch(PersistentUpdateReceipt)
    case rolledBack(PersistentUpdateReceipt)
    case completed(PersistentUpdateReceipt)
    case blocked(PersistentUpdateReceipt)
}

public final class VerifiedUpdateHandoff: @unchecked Sendable {
    public let ticket: UpdateHandoffTicket
    public let request: UpdateHandoffRequest
    public let update: TrustedUpdate
    let lease: UpdateTransactionLease
    init(
        ticket: UpdateHandoffTicket, request: UpdateHandoffRequest, update: TrustedUpdate,
        lease: UpdateTransactionLease
    ) {
        self.ticket = ticket
        self.request = request
        self.update = update
        self.lease = lease
    }
}
