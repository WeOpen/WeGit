import Foundation
import Observation
import WeGitCore

@Observable @MainActor
final class CloneViewModel {
    enum Phase { case editing, cloning, cancelling, cleaning, opening, failed, completed }
    var address = ""
    var folderName = ""
    var parentPath = FileManager.default.homeDirectoryForCurrentUser.path
    var branch = ""
    var singleBranch = false
    var shallow = false
    var depth = 100
    var recurseSubmodules = false
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
            && (!shallow || (1...Int(Int32.max)).contains(depth))
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
        branch = ""
        singleBranch = false
        shallow = false
        depth = 100
        recurseSubmodules = false
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
            address: address, parent: URL(fileURLWithPath: parentPath), folderName: folderName,
            options: CloneOptions(
                branch: branch.isEmpty ? nil : branch, singleBranch: singleBranch,
                depth: shallow ? depth : nil, recurseSubmodules: recurseSubmodules))
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
                notice = L10n.text("克隆完成：\(location.root.path)")
                await onSuccess(location)
                phase = .completed
            } catch {
                failure = error as? CloneFailure
                self.error =
                    error is CancellationError ? L10n.text("克隆已取消，没有创建仓库。") : error.localizedDescription
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
                notice = L10n.text("未完成目录已移到废纸篓，可以使用相同名称重试。")
                phase = .editing
            } catch {
                self.error = error.localizedDescription
                phase = .failed
            }
        }
    }
}

@Observable @MainActor
final class RepositoryInitializationViewModel {
    enum Phase { case editing, creating, cancelling, opening, failed, completed }
    var directoryPath = ""
    var branch = "main"
    var phase: Phase = .editing
    var error: String?
    var createdDirectory: URL?
    private let coordinator: RepositoryInitializationCoordinator
    private var task: Task<Void, Never>?
    init(coordinator: RepositoryInitializationCoordinator) { self.coordinator = coordinator }
    var isBusy: Bool { [.creating, .cancelling, .opening].contains(phase) }
    var canStart: Bool {
        !isBusy && createdDirectory == nil && directoryPath.hasPrefix("/") && !branch.isEmpty
    }
    func resetCompleted() {
        guard phase == .completed else { return }
        directoryPath = ""
        branch = "main"
        phase = .editing
        error = nil
        createdDirectory = nil
    }
    func start(onSuccess: @escaping @MainActor (RepositoryLocation) async -> Bool) {
        guard canStart else { return }
        phase = .creating
        error = nil
        let request = RepositoryInitializationRequest(
            directory: URL(fileURLWithPath: directoryPath), branch: branch)
        task = Task { [self] in
            defer { task = nil }
            do {
                let plan = try await coordinator.prepare(request)
                let location = try await coordinator.initialize(plan)
                createdDirectory = location.root
                phase = .opening
                if await onSuccess(location) {
                    phase = .completed
                } else {
                    phase = .failed
                    error = L10n.text("仓库已建立，但尚未打开。请重新打开该目录。")
                }
            } catch {
                if let failure = error as? RepositoryInitializationFailure {
                    createdDirectory = failure.createdDirectory
                }
                self.error = error.localizedDescription
                phase = .failed
            }
        }
    }
    func cancel() {
        guard phase == .creating else { return }
        phase = .cancelling
        task?.cancel()
    }
}
