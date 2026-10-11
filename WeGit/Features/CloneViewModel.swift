import Foundation
import Observation
import WeGitCore

@Observable @MainActor
final class CloneViewModel {
    enum Phase { case editing, cloning, cancelling, cleaning, opening, failed, completed }
    var address = ""
    var folderName = ""
    var parentPath = FileManager.default.homeDirectoryForCurrentUser.path
    var phase: Phase = .editing
    var progress = CloneProgress(stage: .connecting)
    var error: String?
    var failure: CloneFailure?
    var notice: String?
    private let coordinator: CloneCoordinator
    private var suggestedName = ""
    private var task: Task<Void, Never>?
    private var operationID = UUID()

    init(coordinator: CloneCoordinator) { self.coordinator = coordinator }
    var isBusy: Bool { [.cloning, .cancelling, .cleaning, .opening].contains(phase) }
    var canStart: Bool {
        !isBusy && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !folderName.isEmpty
    }
    var destination: String { URL(fileURLWithPath: parentPath).appendingPathComponent(folderName).path }

    func updateSuggestion() {
        let tail = String(
            address.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").last ?? "")
        let suggestion = tail.hasSuffix(".git") ? String(tail.dropLast(4)) : tail
        if folderName.isEmpty || folderName == suggestedName { folderName = suggestion }
        suggestedName = suggestion
    }

    func resetCompleted(defaultDirectory: String) {
        guard phase == .completed else { return }
        address = ""
        folderName = ""
        suggestedName = ""
        parentPath = defaultDirectory
        phase = .editing
        progress = CloneProgress(stage: .connecting)
        notice = nil
        error = nil
        failure = nil
    }

    func start(onSuccess: @escaping @MainActor (RepositoryLocation) async -> Void) {
        guard canStart else { return }
        let request = CloneRequest(
            address: address, parent: URL(fileURLWithPath: parentPath), folderName: folderName)
        let id = UUID()
        operationID = id
        let previousCleanup = failure?.cleanup
        phase = .cloning
        error = nil
        failure = nil
        notice = nil
        progress = CloneProgress(stage: .connecting)
        task = Task { [self] in
            defer { task = nil }
            do {
                if let previousCleanup { await coordinator.forgetCleanup(previousCleanup) }
                let location = try await coordinator.clone(request) { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.operationID == id, self.phase == .cloning else { return }
                        self.progress = update
                    }
                }
                phase = .opening
                notice = "克隆完成：\(location.root.path)"
                await onSuccess(location)
                phase = .completed
            } catch {
                failure = error as? CloneFailure
                self.error = error is CancellationError ? "克隆已取消，没有创建仓库。" : error.localizedDescription
                phase = .failed
            }
        }
    }

    func cancel() {
        guard phase == .cloning else { return }
        phase = .cancelling
        task?.cancel()
    }

    func cleanUp() {
        guard !isBusy, let token = failure?.cleanup else { return }
        phase = .cleaning
        task = Task {
            defer { task = nil }
            do {
                _ = try await coordinator.cleanUp(token)
                failure = nil
                error = nil
                notice = "未完成目录已移到废纸篓，可以使用相同名称重试。"
                phase = .editing
            } catch {
                self.error = error.localizedDescription
                phase = .failed
            }
        }
    }
}
