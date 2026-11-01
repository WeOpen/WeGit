import AppKit
import Foundation
import Observation
import WeGitCore

struct WorktreeManagementRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
}

/// Keep the native editing target across SwiftUI sheet dismissal. Field editors
/// are shared and detach on resigning focus, so retain their owning control weakly.
@MainActor
final class WorktreeFocusRestoration {
    private let sessionID: UUID
    private weak var window: NSWindow?
    private weak var responder: NSResponder?
    private let selection: NSRange?

    init?(sessionID: UUID) {
        self.sessionID = sessionID
        guard let key = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        let window = key.sheetParent ?? key
        guard let original = window.firstResponder, original !== window else { return nil }
        self.window = window
        if let editor = original as? NSTextView, editor.isFieldEditor {
            guard let content = window.contentView,
                let control = Self.editingControl(editor, in: content)
            else { return nil }
            responder = control
            selection = editor.selectedRange()
        } else {
            responder = original
            selection = (original as? NSTextView)?.selectedRange()
        }
    }

    private static func editingControl(_ editor: NSTextView, in view: NSView) -> NSControl? {
        if let control = view as? NSControl, control.currentEditor() === editor { return control }
        for child in view.subviews {
            if let control = editingControl(editor, in: child) { return control }
        }
        return nil
    }

    func restore(sessionID currentID: UUID?) {
        guard currentID == sessionID, let window, window.isVisible, let responder else { return }
        if let view = responder as? NSView {
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return }
        }
        if let current = window.firstResponder {
            if current === responder { return }
            // A new editing target may have been chosen while the sheet finished
            // dismissing. Restoring the old target must not override that choice.
            if let editor = current as? NSTextView, editor.window === window {
                if !editor.isFieldEditor { return }
                if let content = window.contentView, Self.editingControl(editor, in: content) != nil {
                    return
                }
            }
            if let control = current as? NSControl, control.window === window { return }
        }
        guard window.makeFirstResponder(responder), let selection,
            let editor = ((responder as? NSControl)?.currentEditor() as? NSTextView)
                ?? (responder as? NSTextView)
        else { return }
        let count = editor.string.utf16.count
        let start = min(selection.location, count)
        let range = NSRange(location: start, length: min(selection.length, count - start))
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
    }
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
        app.discardWorktreeManagementFocus()
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
