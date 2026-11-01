import Foundation
import Observation
import WeGitCore

@Observable @MainActor
final class CommitDetailState {
    private let service: RepositoryService
    var comparison: CommitComparison?
    var selectedPath: String?
    var display: DiffDisplayState?
    var diskDisplay: DiskDiffDisplayState?
    var summary: DiffSummary?
    var limit: DiffContentLimit?
    var loading = false
    var loadingFile = false
    var error: String?
    var fileError: String?
    private var preferredSplit = false
    private var requestID = UUID()
    private var fileID = UUID()
    private var task: Task<Void, Never>?
    private var fileTask: Task<Void, Never>?
    private var requestedCommit: GitCommit?
    private var requestedParent: String?
    private var requestedPaths: [String]?

    init(service: RepositoryService) { self.service = service }

    func select(_ commit: GitCommit?, parent: String?, paths: [String]? = nil) async {
        cancel()
        requestedCommit = commit
        requestedParent = parent
        requestedPaths = paths
        comparison = nil
        selectedPath = nil
        display = nil
        diskDisplay = nil
        summary = nil
        error = nil
        fileError = nil
        guard let commit else { return }
        let request = UUID()
        requestID = request
        loading = true
        let work = Task {
            defer { if requestID == request { loading = false } }
            do {
                let result = try await service.commitComparison(id: commit.id, parent: parent, paths: paths)
                guard requestID == request, !Task.isCancelled else { return }
                comparison = result
                selectedPath = result.files.first?.id
            } catch {
                if requestID == request && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        task = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func loadFile(options: DiffReadOptions, split: Bool, large: Bool = false) async {
        fileTask?.cancel()
        display?.cancelAll()
        diskDisplay?.cancelAll()
        preferredSplit = split
        display = nil
        diskDisplay = nil
        fileError = nil
        if !large {
            summary = nil
            limit = nil
        }
        guard let comparison, let file = comparison.files.first(where: { $0.path == selectedPath }) else {
            return
        }
        let request = UUID()
        fileID = request
        loadingFile = true
        let work = Task {
            defer { if fileID == request { loadingFile = false } }
            do {
                let result = try await service.readCommitFile(
                    file, comparison: comparison, options: options, loadLarge: large)
                guard fileID == request, !Task.isCancelled else { return }
                switch result {
                case .deferred(let summary, let limit):
                    self.summary = summary
                    self.limit = limit
                case .loaded(let diff):
                    summary = nil
                    let value = DiffDisplayState(diff: diff, service: service)
                    display = value
                    loadingFile = false
                    await value.prepare(split: preferredSplit)
                case .disk(let snapshot):
                    summary = nil
                    let value = DiskDiffDisplayState(snapshot: snapshot, service: service)
                    diskDisplay = value
                    loadingFile = false
                    await value.prepare(split: preferredSplit)
                }
            } catch {
                if fileID == request && !Task.isCancelled { fileError = error.localizedDescription }
            }
        }
        fileTask = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func setLayout(_ split: Bool) {
        preferredSplit = split
        if let display {
            Task {
                if self.display === display && preferredSplit == split { await display.prepare(split: split) }
            }
        }
        if let diskDisplay {
            Task {
                if self.diskDisplay === diskDisplay && preferredSplit == split {
                    await diskDisplay.prepare(split: split)
                }
            }
        }
    }

    func cancelFile() {
        fileID = UUID()
        fileTask?.cancel()
        loadingFile = false
        fileError = L10n.text("已取消读取，可重新选择文件或重试。")
        display?.cancelAll()
        diskDisplay?.cancelAll()
    }

    func retry() { Task { await select(requestedCommit, parent: requestedParent, paths: requestedPaths) } }

    func cancel(userInitiated: Bool = false) {
        requestID = UUID()
        task?.cancel()
        loading = false
        cancelFile()
        if userInitiated { error = L10n.text("已取消读取，可随时重试。") }
    }

    func releaseCache() {
        cancel()
        comparison = nil
        display = nil
        diskDisplay = nil
        summary = nil
        limit = nil
        selectedPath = nil
        requestedCommit = nil
        requestedParent = nil
        requestedPaths = nil
    }
}
