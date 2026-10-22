import Foundation
import Observation
import WeGitCore

@Observable @MainActor final class FileHistoryState {
    private let service: RepositoryService
    let detail: CommitDetailState
    private(set) var anchor: FileHistoryAnchor?
    private(set) var entries: [FileHistoryEntry] = []
    var selection: String?
    var loading = false
    var error: String?
    private(set) var cancelled = false
    private var next: FileHistoryCursor?
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    var hasMore: Bool { next != nil }
    var selected: FileHistoryEntry? { entries.first { $0.id == selection } }
    init(service: RepositoryService) {
        self.service = service
        detail = CommitDetailState(service: service)
    }
    func reload(_ query: FileHistoryQuery, tip: String?) async {
        cancel()
        entries = []
        selection = nil
        anchor = nil
        next = nil
        error = nil
        guard !query.path.isEmpty else { return }
        let request = UUID()
        requestID = request
        loading = true
        let work = Task {
            defer { if requestID == request { loading = false } }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let anchor = try await service.fileHistoryAnchor(query, tip: tip)
                let page = try await service.fileHistoryPage(anchor)
                guard !Task.isCancelled, requestID == request else { return }
                self.anchor = anchor
                entries = page.entries
                selection = entries.first?.id
                next = page.next
            } catch { if !Task.isCancelled, requestID == request { self.error = error.localizedDescription } }
        }
        task = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
    func loadMore() {
        guard !loading, let anchor, let next else { return }
        let request = requestID
        loading = true
        error = nil
        task = Task {
            defer { if requestID == request { loading = false } }
            do {
                let page = try await service.fileHistoryPage(anchor, after: next)
                guard !Task.isCancelled, requestID == request else { return }
                entries += page.entries
                self.next = page.next
            } catch { if !Task.isCancelled, requestID == request { self.error = error.localizedDescription } }
        }
    }
    func cancel(userInitiated: Bool = false) {
        requestID = UUID()
        task?.cancel()
        loading = false
        cancelled = userInitiated
        detail.cancel()
    }
    func release() {
        cancel()
        anchor = nil
        next = nil
        entries = []
        detail.releaseCache()
    }
}
