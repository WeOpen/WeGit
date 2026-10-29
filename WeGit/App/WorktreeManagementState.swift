import Foundation
import Observation
import WeGitCore

struct WorktreeManagementRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
}

enum WorktreeFormKind: String, CaseIterable, Identifiable {
    case newBranch = "新分支"
    case existingBranch = "已有分支"
    case detached = "Detached HEAD"
    var id: String { rawValue }
    var title: String { L10n.key(rawValue) }
}

@Observable @MainActor
final class WorktreeManagementState {
    enum Screen {
        case list, form
        case creation(WorktreeCreationPlan)
        case removal(WorktreeRemovalPlan)
    }
    private enum ReadResult: Sendable {
        case list([GitWorktree])
        case creation(WorktreeCreationPlan)
        case removal(WorktreeRemovalPlan)
    }
    let app: AppState
    let request: WorktreeManagementRequest
    var screen = Screen.list
    var trees: [GitWorktree] = []
    var kind = WorktreeFormKind.newBranch
    var destination = ""
    var newBranch = "worktree"
    var existingBranch = ""
    var isReading = false
    var error: String?
    var attempted = false
    var preservedDirectory: URL?
    private var readID = UUID()
    private var readTask: Task<Void, Never>?
    var session: RepositorySession { request.session }
    var isCurrent: Bool { app.session === session && app.worktreeManagementRequest?.id == request.id }
    var canPreview: Bool {
        !destination.isEmpty && !isReading && session.canWrite && !session.isBusy
            && (kind == .detached || !(kind == .newBranch ? newBranch : existingBranch).isEmpty)
    }

    init(app: AppState, request: WorktreeManagementRequest) {
        self.app = app
        self.request = request
        destination =
            request.session.location.root.deletingLastPathComponent()
            .appending(path: request.session.location.name + "-worktree").path
    }

    func refresh() {
        guard isCurrent else { return }
        let service = session.service
        read { .list(try await service.worktrees()) }
    }

    private func read(_ operation: @escaping @Sendable () async throws -> ReadResult) {
        cancelReads()
        let token = UUID()
        readID = token
        isReading = true
        error = nil
        readTask = Task { [weak self] in
            do {
                let value = try await operation()
                guard let self, !Task.isCancelled, self.readID == token, self.isCurrent else { return }
                switch value {
                case .list(let rows): self.trees = rows
                case .creation(let plan): self.screen = .creation(plan)
                case .removal(let plan): self.screen = .removal(plan)
                }
                self.isReading = false
            } catch {
                guard let self, !Task.isCancelled, self.readID == token, self.isCurrent else { return }
                self.error = error.localizedDescription
                self.isReading = false
            }
        }
    }

    func cancelReads() {
        readID = UUID()
        readTask?.cancel()
        readTask = nil
        isReading = false
    }

    func beginCreation() {
        error = nil
        attempted = false
        screen = .form
    }
    func back() {
        guard isCurrent else { return }
        cancelReads()
        attempted = false
        error = nil
        screen = .list
        refresh()
    }
    func close() {
        cancelReads()
        if app.worktreeManagementRequest?.id == request.id { app.worktreeManagementRequest = nil }
    }
    func open(_ tree: GitWorktree) {
        guard isCurrent, !session.isBusy, !tree.bare, tree.prunable == nil else { return }
        close()
        Task { await app.open(tree.url) }
    }

    func prepareCreation() {
        guard isCurrent, canPreview else { return }
        let mode: WorktreeCreationKind
        switch kind {
        case .newBranch: mode = .newBranch(newBranch)
        case .existingBranch: mode = .existingBranch(existingBranch)
        case .detached: mode = .detached
        }
        let url = URL(fileURLWithPath: destination, isDirectory: true)
        let service = session.service
        read { .creation(try await service.prepareWorktreeCreation(at: url, kind: mode)) }
    }

    func prepareRemoval(_ tree: GitWorktree) {
        guard isCurrent, !session.isBusy else { return }
        attempted = false
        let service = session.service
        read { .removal(try await service.prepareWorktreeRemoval(tree)) }
    }

    func executeCreation(_ plan: WorktreeCreationPlan) {
        guard isCurrent, !attempted, session.canWrite, !session.isBusy else { return }
        attempted = true
        session.performResult(
            L10n.text("创建工作树"), onSuccess: { [weak self] in self?.back() },
            operation: { service in
                do {
                    _ = try await service.executeWorktreeCreation(plan)
                    return .completed(message: L10n.text("工作树已创建"))
                } catch let unknown as WorktreeOutcomeUnknown {
                    await self.keep(unknown.preservedDirectory)
                    return .needsReview(message: unknown.localizedDescription, details: unknown.details)
                }
            })
    }

    func executeRemoval(_ plan: WorktreeRemovalPlan) {
        guard isCurrent, !attempted, session.canWrite, !session.isBusy else { return }
        attempted = true
        session.performResult(
            L10n.text("移除工作树"), onSuccess: { [weak self] in self?.back() },
            operation: { service in
                do {
                    let receipt = try await service.executeWorktreeRemoval(plan)
                    await self.keep(receipt.preservedDirectory)
                    return .completed(message: L10n.text("工作树登记已移除，目录已保留。"))
                } catch let unknown as WorktreeOutcomeUnknown {
                    await self.keep(unknown.preservedDirectory)
                    return .needsReview(message: unknown.localizedDescription, details: unknown.details)
                }
            })
    }

    private func keep(_ directory: URL) {
        if isCurrent { preservedDirectory = directory }
    }
}
