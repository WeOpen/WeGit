import Foundation
import Observation
import WeGitCore

struct DiffContextExpansion {
    var lines: [DiffLine] = []
    var consumed = 0
    var hasMore = true
    var error: String?
}

@Observable @MainActor
final class DiffDisplayState {
    let renderID: UUID
    let selection = DiffTextSelection()
    let diff: FileDiff
    let additions: Int
    let deletions: Int
    var split = false
    var document: DiffDisplayDocument?
    var rows: [DiffDisplayRow] = []
    var highlighting = DiffHighlighting.empty
    var loading = false
    var error: String?
    var contexts: [Int: DiffContextExpansion] = [:]
    var expandingGap: Int?
    var currentHunk: Int?
    var navigationID = UUID()
    var scrollTarget: DiffDisplayRow.ID?
    private var nextOffset = 0
    private var requestID = UUID()
    private var contextID = UUID()
    private var task: Task<Void, Never>?
    private var contextTask: Task<Void, Never>?
    private var contextHighlighting = DiffHighlighting.empty
    private let reader: DiffContextReader

    init(diff: FileDiff, service: RepositoryService, renderID: UUID = UUID()) {
        self.renderID = renderID
        self.diff = diff
        additions = diff.additions
        deletions = diff.deletions
        reader = DiffContextReader(diff: diff, service: service)
    }

    var hasMore: Bool { document.map { nextOffset < $0.rows.count } ?? false }
    var displayedLines: Int { rows.count(where: \.isContent) }

    func prepare(split: Bool) async {
        cancelPage()
        let request = UUID()
        requestID = request
        self.split = split
        currentHunk = diff.hunks.first?.id
        document = nil
        rows = []
        nextOffset = 0
        loading = true
        error = nil
        let work = Task {
            defer { if requestID == request { loading = false } }
            do {
                let prepared = try await DiffDisplayDocument.prepare(diff, split: split)
                let page = try await prepared.page(from: 0)
                guard requestID == request, !Task.isCancelled else { return }
                document = prepared
                rows = page.rows
                nextOffset = page.nextOffset
                highlighting = page.highlighting.merging(contextHighlighting)
                syncSelection()
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
        guard let document, hasMore, !loading else { return }
        let request = UUID()
        requestID = request
        let offset = nextOffset
        loading = true
        error = nil
        task = Task {
            defer { if requestID == request { loading = false } }
            do {
                let page = try await document.page(from: offset)
                guard requestID == request, !Task.isCancelled else { return }
                rows += page.rows
                nextOffset = page.nextOffset
                highlighting = highlighting.merging(page.highlighting)
                syncSelection()
            } catch {
                if requestID == request && !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func navigate(to hunk: Int) {
        guard !loading, let document, diff.hunks.contains(where: { $0.id == hunk }),
            let offset = document.rows.firstIndex(where: { $0.id == .hunk(hunk) })
        else { return }
        cancelPage()
        cancelContext()
        contexts = [:]
        contextHighlighting = .empty
        let request = UUID()
        requestID = request
        loading = true
        error = nil
        task = Task {
            defer { if requestID == request { loading = false } }
            do {
                let page = try await document.page(from: offset)
                guard requestID == request, !Task.isCancelled else { return }
                rows = page.rows
                nextOffset = page.nextOffset
                highlighting = page.highlighting
                syncSelection()
                currentHunk = hunk
                scrollTarget = .hunk(hunk)
                navigationID = UUID()
            } catch {
                if requestID == request, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancelPage() {
        requestID = UUID()
        task?.cancel()
        task = nil
        loading = false
    }

    func expand(_ gap: DiffContextGap) {
        guard expandingGap == nil else { return }
        let expansion = contexts[gap.id] ?? DiffContextExpansion()
        guard expansion.hasMore else { return }
        let request = UUID()
        contextID = request
        expandingGap = gap.id
        contexts[gap.id, default: DiffContextExpansion()].error = nil
        contextTask = Task {
            defer { if contextID == request { expandingGap = nil } }
            do {
                let page = try await reader.page(for: gap, offset: expansion.consumed)
                let ranges = try await DiffHighlighting.prepare(
                    lines: page.lines, pairs: [], filename: diff.path)
                guard contextID == request, !Task.isCancelled else { return }
                contexts[gap.id] = DiffContextExpansion(
                    lines: gap.expandsUpward ? page.lines + expansion.lines : expansion.lines + page.lines,
                    consumed: expansion.consumed + page.consumedLines, hasMore: page.hasMore)
                contextHighlighting = contextHighlighting.merging(ranges)
                highlighting = highlighting.merging(ranges)
                syncSelection()
            } catch {
                guard contextID == request, !Task.isCancelled else { return }
                contexts[gap.id, default: DiffContextExpansion()].error = error.localizedDescription
            }
        }
    }

    func cancelContext() {
        contextID = UUID()
        contextTask?.cancel()
        contextTask = nil
        expandingGap = nil
    }

    func collapse(_ gap: DiffContextGap) {
        if expandingGap == gap.id { cancelContext() }
        contexts.removeValue(forKey: gap.id)
        syncSelection()
        scrollTarget = .gap(gap.id)
        navigationID = UUID()
    }

    private func syncSelection() {
        var values: [DiffCodeSide: [DiffLine]] = [:]
        func add(_ line: DiffLine?, side: DiffCodeSide) {
            if let line, line.kind != "\\" { values[side, default: []].append(line) }
        }
        for row in rows {
            switch row {
            case .line(let line): add(line, side: .unified)
            case .split(let pair):
                add(pair.old, side: .old)
                add(pair.new, side: .new)
            case .gap(let gap):
                for line in contexts[gap.id]?.lines ?? [] {
                    if split {
                        add(line, side: .old)
                        add(line, side: .new)
                    } else {
                        add(line, side: .unified)
                    }
                }
            case .hunk: break
            }
        }
        selection.replace(values)
    }

    func cancelAll() {
        selection.replace([:])
        cancelPage()
        cancelContext()
    }
}
