import Foundation
import Observation
import WeGitCore

struct HistoryTableRow: Identifiable {
    let commit: GitCommit
    let graph: GraphRow
    var id: String { commit.id }
}

@Observable @MainActor
final class HistoryState {
    var firstRenderID = UUID()
    var scope = HistoryScope.all
    var query = ""
    var searchField = HistorySearchField.message
    private(set) var anchor: HistoryAnchor?
    private(set) var commits: [GitCommit] = []
    private(set) var tableRows: [HistoryTableRow] = []
    private(set) var graphWidth = 2
    private(set) var references: [String: [GitReference]] = [:]
    var loading = false
    var stale = false
    var error: String?
    var cancelled = false
    private var next: HistoryCursor?
    private var graph = CommitGraphLayoutEngine()
    private var loadedIDs: Set<String> = []
    private let service: RepositoryService
    let detail: CommitDetailState
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var checkID = UUID()
    var hasMore: Bool { next != nil }

    init(service: RepositoryService) {
        self.service = service
        detail = CommitDetailState(service: service)
    }

    func synchronize() async {
        if needsReload {
            // A new SwiftUI task can arrive before its cancelled predecessor has
            // finished unwinding. Wait for that read, then recheck the anchor so
            // a cancelled first page cannot leave the history permanently empty.
            if loading, let work = task {
                await work.value
                if cancelled { return }
            }
            guard !Task.isCancelled else { return }
            if needsReload { await reload() }
            return
        }
        guard let anchor else { return }
        let request = UUID()
        checkID = request
        do {
            let fresh = try await service.historyAnchor(
                scope: anchor.scope, query: anchor.query, searchField: anchor.searchField)
            guard checkID == request, self.anchor?.id == anchor.id, !Task.isCancelled else { return }
            stale =
                fresh.references != anchor.references || fresh.head != anchor.head
                || fresh.isShallow != anchor.isShallow
        } catch {
            if checkID == request && !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private var needsReload: Bool {
        anchor == nil || anchor?.query != query || anchor?.scope != scope
            || anchor?.searchField != searchField
    }

    func reload() async {
        cancel()
        let request = UUID()
        firstRenderID = request
        ViewPerformanceJournal.begin("history", id: request)
        requestID = request
        let scope = scope
        let query = query
        let searchField = searchField
        anchor = nil
        commits = []
        tableRows = []
        graphWidth = 2
        references = [:]
        loadedIDs = []
        graph = CommitGraphLayoutEngine()
        next = nil
        stale = false
        error = nil
        cancelled = false
        loading = true
        let work = Task {
            defer { if requestID == request { loading = false } }
            do {
                let anchor = try await service.historyAnchor(
                    scope: scope, query: query, searchField: searchField)
                let page = try await service.historyPage(anchor)
                let layout = try await Self.layout(
                    page.commits, using: CommitGraphLayoutEngine(), filtered: !query.isEmpty)
                guard requestID == request, !Task.isCancelled else { return }
                self.anchor = anchor
                references = Dictionary(grouping: anchor.references, by: \.target)
                commits = page.commits
                tableRows = zip(page.commits, layout.0).map { HistoryTableRow(commit: $0.0, graph: $0.1) }
                graphWidth = max(2, layout.0.map(\.width).max() ?? 2)
                graph = layout.1
                next = page.next
                loadedIDs = Set(page.commits.map(\.id))
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

    func loadMore() {
        guard let anchor, let next, !loading else { return }
        let request = UUID()
        requestID = request
        loading = true
        error = nil
        let priorGraph = graph
        task = Task {
            defer { if requestID == request { loading = false } }
            do {
                let page = try await service.historyPage(anchor, after: next)
                let layout = try await Self.layout(
                    page.commits, using: priorGraph, filtered: !anchor.query.isEmpty)
                guard requestID == request, self.anchor?.id == anchor.id, !Task.isCancelled else { return }
                guard loadedIDs.isDisjoint(with: page.commits.map(\.id)) else {
                    throw ModelFailure.invalidOutput(L10n.text("历史分页包含重复提交，请重新读取。"))
                }
                commits += page.commits
                tableRows += zip(page.commits, layout.0).map { HistoryTableRow(commit: $0.0, graph: $0.1) }
                graphWidth = max(graphWidth, layout.0.map(\.width).max() ?? 2)
                graph = layout.1
                self.next = page.next
                loadedIDs.formUnion(page.commits.map(\.id))
            } catch {
                if requestID == request && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancel(userInitiated: Bool = false) {
        requestID = UUID()
        checkID = UUID()
        task?.cancel()
        task = nil
        loading = false
        if userInitiated { cancelled = true }
    }

    func releaseCache() {
        cancel()
        detail.releaseCache()
        anchor = nil
        commits = []
        tableRows = []
        graphWidth = 2
        references = [:]
        loadedIDs = []
        graph = CommitGraphLayoutEngine()
        next = nil
    }

    @concurrent private static func layout(
        _ commits: [GitCommit], using previous: CommitGraphLayoutEngine, filtered: Bool
    ) async throws -> ([GraphRow], CommitGraphLayoutEngine) {
        try Task.checkCancellation()
        var graph = previous
        let rows =
            filtered
            ? commits.map { _ in GraphRow(column: 0, connections: [], width: 1) } : graph.append(commits)
        try Task.checkCancellation()
        return (rows, graph)
    }
}
