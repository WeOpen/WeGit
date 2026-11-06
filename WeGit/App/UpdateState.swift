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
    var channel: UpdateChannel = .stable
    private(set) var phase: Phase = .idle
    private(set) var error: String?
    private(set) var update: TrustedUpdate?
    private(set) var received: Int64 = 0
    private(set) var expected: Int64 = 0
    let installed: InstalledUpdateVersion
    @ObservationIgnored private let ring: UpdateKeyRing?
    @ObservationIgnored private let client = UpdateHTTPClient()
    @ObservationIgnored private let installer: (@MainActor (UpdateInstallRequest) async throws -> Void)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var request: UpdateInstallRequest?

    var configured: Bool { ring?.keys.isEmpty == false }
    var installerConfigured: Bool { installer != nil }
    var running: Bool { [.checking, .downloading, .installing, .handedOff].contains(phase) }
    var cancellable: Bool { [.checking, .downloading].contains(phase) }

    init(
        installed: InstalledUpdateVersion, ring: UpdateKeyRing?,
        installer: (@MainActor (UpdateInstallRequest) async throws -> Void)? = nil
    ) {
        self.installed = installed
        self.ring = ring
        self.installer = installer
    }

    func check() {
        guard !running else { return }
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
        guard !running, let update else { return }
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
        guard !running, let request, let installer else {
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
    func channelChanged() {
        guard !running else { return }
        request = nil
        update = nil
        error = nil
        phase = .idle
    }
}
