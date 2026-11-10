import AppKit
import Foundation
import Observation
import WeGitCore

struct UpdateInstallRequest: Sendable {
    let update: TrustedUpdate
    let download: UpdateDownload
    let packageManifest: Data
}

/// Shared at application scope. Closing its sheet does not cancel another
/// window's download, close a workspace or discard an in-progress Git draft.
@Observable @MainActor final class UpdateState {
    enum Phase {
        case idle, checking, current, available, downloading, ready, installing, handedOff, cancelled
    }
    enum RetentionPhase { case idle, loading, preparing, cleaning }
    var channel: UpdateChannel = .stable
    private(set) var retentionPhase: RetentionPhase = .idle
    private(set) var retentionInventory: UpdateRetentionInventory?
    private(set) var retentionError: String?
    private(set) var cleanupRequest: UpdateRetentionCleanupPlan?
    private(set) var phase: Phase = .idle
    private(set) var error: String?
    private(set) var update: TrustedUpdate?
    private(set) var received: Int64 = 0
    private(set) var expected: Int64 = 0
    let installed: InstalledUpdateVersion
    @ObservationIgnored private let ring: UpdateKeyRing?
    @ObservationIgnored private let retentionTarget: URL
    @ObservationIgnored private let retentionScope: UpdateHandoffScope
    @ObservationIgnored private var retentionOperation: Task<Void, Never>?
    @ObservationIgnored private let client = UpdateHTTPClient()
    @ObservationIgnored private var installer: (@MainActor (UpdateInstallRequest) async throws -> Void)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var request: UpdateInstallRequest?

    var configured: Bool { ring?.keys.isEmpty == false }
    var installerConfigured: Bool { installer != nil }
    var running: Bool { [.checking, .downloading, .installing, .handedOff].contains(phase) }
    var cancellable: Bool { [.checking, .downloading].contains(phase) }
    var retentionBusy: Bool { retentionPhase != .idle || cleanupRequest != nil }
    var canManageRetention: Bool { !running && !retentionBusy }
    var retainedEntries: [UpdateRetentionEntry] { retentionInventory?.entries ?? [] }

    init(
        installed: InstalledUpdateVersion, ring: UpdateKeyRing?,
        installer: (@MainActor (UpdateInstallRequest) async throws -> Void)? = nil,
        retentionTarget: URL = Bundle.main.bundleURL,
        retentionScope: UpdateHandoffScope = .production
    ) {
        self.installed = installed
        self.ring = ring
        self.installer = installer
        self.retentionTarget = retentionTarget
        self.retentionScope = retentionScope
    }

    func check() {
        guard !running, !retentionBusy else { return }
        guard let ring, configured else {
            error = UpdateFailure.configurationMissing.localizedDescription
            return
        }
        operationID = UUID()
        let id = operationID
        let selectedChannel = channel
        phase = .checking
        error = nil
        update = nil
        request = nil
        operation = Task { [self] in
            do {
                let result = try await client.check(
                    channel: selectedChannel, ring: ring, installed: installed)
                try Task.checkCancellation()
                guard id == operationID else { return }
                switch result {
                case .current: phase = .current
                case .available(let available):
                    update = available
                    phase = .available
                }
            } catch is CancellationError { if id == operationID { phase = .cancelled } } catch {
                if id == operationID {
                    phase = .idle
                    self.error = error.localizedDescription
                }
            }
            if id == operationID { operation = nil }
        }
    }

    func download() {
        guard !running, !retentionBusy, let update else { return }
        operationID = UUID()
        let id = operationID
        phase = .downloading
        error = nil
        received = 0
        expected = update.artifact.downloadBytes
        operation = Task { [self] in
            do {
                async let package = client.packageManifest(update)
                let downloaded = try await client.download(update) { [weak self] completed, total in
                    Task { @MainActor in
                        guard let self, self.operationID == id, self.phase == .downloading else { return }
                        self.received = completed
                        self.expected = total
                    }
                }
                let packageManifest = try await package
                try Task.checkCancellation()
                guard id == operationID else { return }
                request = UpdateInstallRequest(
                    update: update, download: downloaded, packageManifest: packageManifest)
                received = expected
                phase = .ready
            } catch is CancellationError { if id == operationID { phase = .cancelled } } catch {
                if id == operationID {
                    phase = .available
                    self.error = error.localizedDescription
                }
            }
            if id == operationID { operation = nil }
        }
    }

    func install() {
        guard !running, !retentionBusy else { return }
        guard let request, let installer else {
            error = L10n.text("安装器尚未配置，请使用官网下载。")
            return
        }
        operationID = UUID()
        let id = operationID
        phase = .installing
        error = nil
        operation = Task { [self] in
            do {
                try await request.download.validate()
                guard Date() < request.update.expiresAt else { throw UpdateFailure.expired }
                try await installer(request)
                if id == operationID { phase = .handedOff }
            } catch {
                if id == operationID {
                    phase = .ready
                    self.error = error.localizedDescription
                }
            }
            if id == operationID { operation = nil }
        }
    }

    func cancel() { if cancellable { operation?.cancel() } }
    func configureInstaller(_ installer: @escaping @MainActor (UpdateInstallRequest) async throws -> Void) {
        guard !running else { return }
        self.installer = installer
    }
    func installerHandoffFailed(_ message: String) {
        guard phase == .handedOff else { return }
        phase = .ready
        error = message
    }
    func channelChanged() {
        guard !running, !retentionBusy else { return }
        request = nil
        update = nil
        error = nil
        phase = .idle
    }

    func refreshRetention() {
        guard canManageRetention else { return }
        retentionPhase = .loading
        retentionError = nil
        retentionOperation = Task { [self] in
            defer {
                retentionPhase = .idle
                retentionOperation = nil
            }
            do {
                retentionInventory = try await ProductionUpdateInstaller.inventory(
                    target: retentionTarget, trustedKeyRing: ring ?? UpdateKeyRing(keys: []),
                    requiredScope: retentionScope)
            } catch {
                retentionInventory = nil
                retentionError = error.localizedDescription
            }
        }
    }

    func prepareRetentionCleanup(_ entry: UpdateRetentionEntry) {
        guard canManageRetention, entry.canClean,
            retainedEntries.contains(where: { $0.id == entry.id && $0.canClean })
        else { return }
        retentionPhase = .preparing
        retentionError = nil
        retentionOperation = Task { [self] in
            defer {
                retentionPhase = .idle
                retentionOperation = nil
            }
            do {
                let plan = try await ProductionUpdateInstaller.prepareCleanup(
                    entry: entry, target: retentionTarget,
                    trustedKeyRing: ring ?? UpdateKeyRing(keys: []), requiredScope: retentionScope)
                try Task.checkCancellation()
                cleanupRequest = plan
            } catch is CancellationError {
                cleanupRequest = nil
            } catch {
                retentionError = error.localizedDescription
            }
        }
    }

    func cancelRetentionCleanup() {
        if retentionPhase == .preparing { retentionOperation?.cancel() }
        cleanupRequest = nil
    }

    func executeRetentionCleanup(_ plan: UpdateRetentionCleanupPlan) {
        guard !running, retentionPhase == .idle else { return }
        cleanupRequest = nil
        retentionPhase = .cleaning
        retentionError = nil
        retentionOperation = Task { [self] in
            defer {
                retentionPhase = .idle
                retentionOperation = nil
            }
            do {
                try await ProductionUpdateInstaller.executeCleanup(
                    plan, trustedKeyRing: ring ?? UpdateKeyRing(keys: []))
            } catch {
                retentionError = error.localizedDescription
            }
            // Refresh after success or failure so changed/partially cleaned
            // records cannot keep an old destructive capability in the list.
            do {
                retentionInventory = try await ProductionUpdateInstaller.inventory(
                    target: retentionTarget, trustedKeyRing: ring ?? UpdateKeyRing(keys: []),
                    requiredScope: retentionScope)
            } catch {
                retentionInventory = nil
                if retentionError == nil { retentionError = error.localizedDescription }
            }
        }
    }

    func revealRetention(_ entry: UpdateRetentionEntry) {
        guard !retentionBusy, retainedEntries.contains(where: { $0.id == entry.id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([entry.directory])
    }

    func exportRetentionDiagnostics() {
        guard canManageRetention, let inventory = retentionInventory else { return }
        do {
            let data = try ProductionUpdateInstaller.diagnosticSummary(inventory)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "WeGit-update-diagnostics.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            retentionError = error.localizedDescription
        }
    }

}
