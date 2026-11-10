import AppKit
import Foundation
import WeGitCore

@main struct WeGitUpdater {
    static func main() async {
        do {
            let arguments = try UpdaterArguments(CommandLine.arguments)
            let ring = try UpdateTrustConfiguration.productionRing()
            let token = try arguments.tokenFromPipe()
            let ticket = try ProductionUpdateInstaller.loadTicket(at: arguments.ticketURL, token: token)
            let outcome = try await UpdaterCoordinator.run(
                ticket: ticket, ring: ring, recover: arguments.recover)
            let data = try JSONSerialization.data(
                withJSONObject: ["id": ticket.id.uuidString, "status": outcome.rawValue],
                options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data((Redaction.text(error.localizedDescription) + "\n").utf8))
            exit(1)
        }
    }
}

enum UpdaterOutcome: String, Sendable { case installed, rolledBack, aborted, recovered }

/// The source can cancel while its kernel exit observation remains pending.
enum UpdaterSourceGate {
    private enum Signal: Sendable {
        case exited(UpdateNormalExitPermit)
        case aborted
    }

    static func wait(
        monitor: UpdateSourceProcessMonitor,
        readAbort: @escaping @Sendable () async throws -> Bool
    ) async throws -> UpdateNormalExitPermit? {
        let signal = try await withThrowingTaskGroup(of: Signal.self) { group in
            group.addTask { .exited(try await monitor.waitForNormalExit(timeout: 60)) }
            group.addTask {
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    if try await readAbort() { return .aborted }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw UpdateFailure.busy
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw UpdateFailure.changed }
            return first
        }
        switch signal {
        case .exited(let permit): return permit
        case .aborted: return nil
        }
    }
}

/// A transaction owns one Core lease throughout installation. Recovery first
/// finishes Core's filesystem inspection, then obtains its historical lease.
@MainActor enum UpdaterCoordinator {
    private enum LaunchSignal: Sendable {
        case confirmed(PersistentUpdateReceipt)
        case exited(UpdateObservedExit)
    }

    static func run(ticket: UpdateHandoffTicket, ring: UpdateKeyRing, recover: Bool) async throws
        -> UpdaterOutcome
    {
        if recover { return try await resume(ticket: ticket, ring: ring) }
        let verified = try await ProductionUpdateInstaller.readAndValidate(
            ticket: ticket, trustedKeyRing: ring, requiredScope: .production)
        do {
            guard verified.request.scope == .production else { throw UpdateFailure.changed }
            let source = try UpdateSourceProcessMonitor(identity: verified.request.originalProcess)
            _ = try await ProductionUpdateInstaller.writeHelperReady(verified: verified, monitor: source)
            guard let permit = try await waitForSource(verified: verified, monitor: source) else {
                return .aborted
            }
            guard try await ProductionUpdateInstaller.readSourceAbort(verified: verified) == nil else {
                _ = try await ProductionUpdateInstaller.abortPrepared(
                    verified: verified, reason: "Source application cancelled the update")
                return .aborted
            }
            _ = try await ProductionUpdateInstaller.apply(verified: verified, permit: permit)
            let monitor = try await launch(verified.request.target, ticket: ticket)
            _ = try await ProductionUpdateInstaller.recordLaunchedProcess(
                verified: verified, monitor: monitor)
            return try await observe(verified: verified, monitor: monitor)
        } catch {
            await preserveFailure(verified: verified, error: error)
            throw error
        }
    }

    private static func resume(ticket: UpdateHandoffTicket, ring: UpdateKeyRing) async throws
        -> UpdaterOutcome
    {
        let decision = try await ProductionUpdateInstaller.recover(
            ticket: ticket, trustedKeyRing: ring, requiredScope: .production)
        let verified = try await ProductionUpdateInstaller.readAndValidateForRecovery(
            ticket: ticket, trustedKeyRing: ring, requiredScope: .production)
        do {
            guard verified.request.scope == .production else { throw UpdateFailure.changed }
            switch decision {
            case .completed: return .recovered
            case .prepared:
                _ = try await ProductionUpdateInstaller.abortPrepared(
                    verified: verified, reason: "Prepared update requires a fresh source exit handshake")
                return .aborted
            case .blocked: throw UpdateFailure.installation
            case .awaitingLaunch(let receipt):
                let journal = try await ProductionUpdateInstaller.readJournalSnapshot(verified: verified)
                guard receipt.phase == .awaitingLaunch, let process = journal.launchedProcess,
                    process.stillRunning()
                else { throw UpdateFailure.installation }
                let monitor = try UpdateSourceProcessMonitor(identity: process)
                return try await observe(verified: verified, monitor: monitor)
            case .rolledBack(let receipt):
                if receipt.preferencesRestoration != nil || receipt.storeRestoration != nil {
                    guard
                        let exit = try await ProductionUpdateInstaller.recordedRollbackExit(
                            verified: verified)
                    else { throw UpdateFailure.installation }
                    try await restoreCurrentData(
                        receipt, verified: verified, stoppedWriterPID: exit.source.pid)
                }
                return .rolledBack
            }
        } catch {
            await preserveFailure(verified: verified, error: error)
            throw error
        }
    }

    private static func waitForSource(verified: VerifiedUpdateHandoff, monitor: UpdateSourceProcessMonitor)
        async throws -> UpdateNormalExitPermit?
    {
        let permit = try await UpdaterSourceGate.wait(monitor: monitor) {
            try await ProductionUpdateInstaller.readSourceAbort(verified: verified) != nil
        }
        if permit == nil {
            _ = try await ProductionUpdateInstaller.abortPrepared(
                verified: verified, reason: "Source application cancelled the update")
        }
        return permit
    }

    private static func launch(_ target: URL, ticket: UpdateHandoffTicket) async throws
        -> UpdateSourceProcessMonitor
    {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--update-handoff", ticket.ticketURL.path]
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
        let identity = try UpdateProcessIdentity.capture(pid: app.processIdentifier)
        guard identity.executable == target.appending(path: "Contents/MacOS/WeGit").path else {
            throw UpdateFailure.changed
        }
        return try UpdateSourceProcessMonitor(identity: identity)
    }

    private static func observe(verified: VerifiedUpdateHandoff, monitor: UpdateSourceProcessMonitor)
        async throws -> UpdaterOutcome
    {
        let signal = try await withThrowingTaskGroup(of: LaunchSignal.self) { group in
            group.addTask { .exited(try await monitor.waitForExit(timeout: 60)) }
            group.addTask {
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                while ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    do {
                        if let readiness = try await ProductionUpdateInstaller.readReadiness(
                            verified: verified)
                        {
                            guard readiness.process == monitor.identity else { throw UpdateFailure.changed }
                            let receipt = try await ProductionUpdateInstaller.confirmLaunch(
                                verified: verified, readiness: readiness)
                            return .confirmed(receipt)
                        }
                    } catch {
                        // Disappearance only lets the kernel monitor win the race.
                        // It never becomes a permit or authorizes rollback.
                        if monitor.identity.stillRunning() { throw error }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw UpdateFailure.installation
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw UpdateFailure.changed }
            return first
        }
        switch signal {
        case .confirmed: return .installed
        case .exited(let observed):
            let journal = try await ProductionUpdateInstaller.readJournalSnapshot(verified: verified)
            if journal.phase == .launchVerified { return .installed }
            let receipt = try await ProductionUpdateInstaller.rollback(
                verified: verified, observedExit: observed)
            try await restoreCurrentData(receipt, verified: verified, stoppedWriterPID: observed.source.pid)
            return .rolledBack
        }
    }

    private static func restoreCurrentData(
        _ receipt: PersistentUpdateReceipt, verified: VerifiedUpdateHandoff, stoppedWriterPID: Int32
    ) async throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let configuration = try ApplicationDataMigration.Configuration.standard(
            applicationSupportDirectory: support, applicationIdentifier: "com.willxue.wegit")
        if let preferences = receipt.preferencesRestoration {
            guard preferences.domainName == configuration.currentDomain else { throw UpdateFailure.changed }
            let restored = try ApplicationDataMigration.restoreCurrentPreferencesSnapshot(
                preferences.bytes, configuration: configuration, stoppedWriterPID: stoppedWriterPID)
            _ = try await ProductionUpdateInstaller.confirmPreferencesRestored(
                verified: verified, restoredSHA256: restored)
        }
        if let store = receipt.storeRestoration {
            let restored = try ApplicationDataMigration.restoreCurrentStoreBackup(
                store, configuration: configuration, stoppedWriterPID: stoppedWriterPID)
            _ = try await ProductionUpdateInstaller.confirmStoreRestored(
                verified: verified, restoredSHA256: restored.restoredSHA256)
        }
    }

    private static func preserveFailure(verified: VerifiedUpdateHandoff, error: Error) async {
        guard let journal = try? await ProductionUpdateInstaller.readJournalSnapshot(verified: verified)
        else { return }
        if journal.phase == .prepared {
            _ = try? await ProductionUpdateInstaller.abortPrepared(verified: verified, reason: reason(error))
        } else if journal.phase != .launchVerified {
            _ = try? await ProductionUpdateInstaller.markBlocked(verified: verified, reason: reason(error))
        }
    }

    private static func reason(_ error: Error) -> String {
        String(Redaction.text(error.localizedDescription).prefix(256))
    }
}
