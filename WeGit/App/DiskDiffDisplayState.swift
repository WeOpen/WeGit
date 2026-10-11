import Foundation
import Observation
import WeGitCore

@Observable @MainActor
final class DiskDiffDisplayState {
    let renderID: UUID
    let selection = DiffTextSelection()
    let snapshot: DiskDiffSnapshot
    var page: DiskDiffPage?
    var split = false
    var loading = false
    var error: String?
    var exporting = false
    var exportError: String?
    var exported = false
    var completedHunks: Set<Int> = []
    let contextGaps: [Int: DiffContextGap]
    var contexts: [Int: DiffContextExpansion] = [:]
    var expandingGap: Int?
    var currentHunk: Int?
    var navigationID = UUID()
    var scrollTarget: DiffDisplayRow.ID?
    var contextHighlighting = DiffHighlighting.empty
    private let contextReader: DiffContextReader
    private var contextTask: Task<Void, Never>?
    private var contextID = UUID()
    private(set) var pageIndex = 0
    private var history: [DiskDiffCursor] = []
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    init(snapshot: DiskDiffSnapshot, service: RepositoryService, renderID: UUID = UUID()) {
        self.renderID = renderID
        self.snapshot = snapshot
        contextGaps = Dictionary(uniqueKeysWithValues: DiffContextGap.gaps(for: snapshot).map { ($0.id, $0) })
        contextReader = DiffContextReader(snapshot: snapshot, service: service)
    }
    var canGoBack: Bool { pageIndex > 0 && !loading }
    var canGoForward: Bool { page?.next != nil && !loading }
    var totalLines: Int { split && !snapshot.rawPreview ? snapshot.splitRows : snapshot.unifiedRows }

    func prepare(split: Bool) async {
        cancelPage()
        self.split = split && !snapshot.rawPreview
        currentHunk = snapshot.hunks.first?.id
        page = nil
        contexts = [:]
        contextHighlighting = .empty
        pageIndex = 0
        history = []
        completedHunks = []
        let work = read(cursor: nil, index: 0)
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func previous() {
        guard canGoBack else { return }
        _ = read(cursor: history[pageIndex - 1], index: pageIndex - 1)
    }

    func next() {
        guard canGoForward, let cursor = page?.next else { return }
        _ = read(cursor: cursor, index: pageIndex + 1)
    }

    func retry() {
        guard !loading else { return }
        _ = read(cursor: page?.start, index: pageIndex)
    }

    func navigate(to hunk: Int) {
        guard !loading, snapshot.hunks.contains(where: { $0.id == hunk }) else { return }
        cancelPage()
        cancelContext()
        let request = UUID()
        requestID = request
        let layout = split
        loading = true
        error = nil
        task = Task {
            defer { if requestID == request { loading = false } }
            do {
                let result = try await snapshot.page(atHunk: hunk, split: layout)
                guard requestID == request, !Task.isCancelled else { return }
                page = result
                contexts = [:]
                contextHighlighting = .empty
                history = [result.start]
                pageIndex = 0
                completedHunks.formUnion(result.completedHunks)
                syncSelection()
                currentHunk = hunk
                scrollTarget = .hunk(hunk)
                navigationID = UUID()
            } catch {
                if requestID == request, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func read(cursor: DiskDiffCursor?, index: Int) -> Task<Void, Never> {
        cancelContext()
        let request = UUID()
        requestID = request
        let split = split
        loading = true
        error = nil
        let work = Task {
            defer { if requestID == request { loading = false } }
            do {
                let result = try await snapshot.page(from: cursor, split: split)
                guard requestID == request, !Task.isCancelled else { return }
                page = result
                if let hunk = result.rows.compactMap({ row -> Int? in
                    if case .hunk(let hunk) = row { return hunk.id }
                    return nil
                }).first {
                    currentHunk = hunk
                }
                contexts = [:]
                contextHighlighting = .empty
                pageIndex = index
                if history.count == index { history.append(result.start) }
                completedHunks.formUnion(result.completedHunks)
                syncSelection()
            } catch {
                guard requestID == request, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
        task = work
        return work
    }

    func cancelPage() {
        requestID = UUID()
        task?.cancel()
        task = nil
        loading = false
    }

    func export(to destination: URL) {
        guard !exporting else { return }
        exporting = true
        exported = false
        exportError = nil
        exportTask = Task {
            defer { exporting = false }
            do {
                try await snapshot.export(to: destination)
                if !Task.isCancelled { exported = true }
            } catch {
                if !Task.isCancelled { exportError = error.localizedDescription }
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }
    func gap(before hunk: DiskDiffHunk) -> DiffContextGap? {
        if page?.firstHunkContinues == true, case .hunk(let first) = page?.rows.first, first.id == hunk.id {
            return nil
        }
        return contextGaps[hunk.id]
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
                let result = try await contextReader.page(for: gap, offset: expansion.consumed)
                let ranges = try await DiffHighlighting.prepare(
                    lines: result.lines, pairs: [], filename: snapshot.path)
                guard contextID == request, !Task.isCancelled else { return }
                contexts[gap.id] = DiffContextExpansion(
                    lines: gap.expandsUpward
                        ? result.lines + expansion.lines : expansion.lines + result.lines,
                    consumed: expansion.consumed + result.consumedLines, hasMore: result.hasMore)
                contextHighlighting = contextHighlighting.merging(ranges)
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
        func context(_ gap: DiffContextGap?) {
            guard let gap else { return }
            for line in contexts[gap.id]?.lines ?? [] {
                if split {
                    add(line, side: .old)
                    add(line, side: .new)
                } else {
                    add(line, side: .unified)
                }
            }
        }
        for row in page?.rows ?? [] {
            switch row {
            case .line(let line): add(line, side: .unified)
            case .split(let pair):
                add(pair.old, side: .old)
                add(pair.new, side: .new)
            case .hunk(let hunk): context(gap(before: hunk))
            }
        }
        if page?.next == nil { context(contextGaps[snapshot.hunks.count]) }
        selection.replace(values)
    }

    func cancelAll() {
        selection.replace([:])
        cancelPage()
        cancelExport()
        cancelContext()
    }
}
