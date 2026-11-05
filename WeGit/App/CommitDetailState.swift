import Foundation
import Observation
import WeGitCore

struct ReferenceComparisonRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    var base: String = "HEAD"
    var target: String = "HEAD"
}

@Observable @MainActor
final class ReferenceComparisonState {
    let session: RepositorySession
    let detail: CommitDetailState
    var base: String
    var target: String
    var kind = ReferenceComparisonKind.twoPoint
    var references: [String] = ["HEAD"]
    var plan: ReferenceComparisonPlan?
    var ancestor = ""
    var result: ReferenceComparisonResult?
    var loading = false
    var error: String?
    var filter = ""
    var visibleFiles = 100
    var commits: [GitCommit] = []
    var nextCommitOffset: Int?
    var loadingCommits = false
    private var work: Task<Void, Never>?
    private var requestID = UUID()
    init(_ request: ReferenceComparisonRequest) {
        session = request.session
        base = request.base
        target = request.target
        detail = CommitDetailState(service: request.session.service)
        references += request.session.branches.map(\.id)
    }
    var files: [CommitFileChange] {
        (result?.comparison.files ?? []).filter {
            filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter)
                || $0.oldPath?.localizedCaseInsensitiveContains(filter) == true
        }
    }
    func loadReferences() async {
        if let tags = try? await session.service.tags(limit: 10000) {
            references += tags.entries.map(\.reference)
        }
        references = Array(Set(references)).sorted()
    }
    func clear() {
        work?.cancel()
        requestID = UUID()
        loading = false
        result = nil
        plan = nil
        ancestor = ""
        error = nil
        detail.releaseCache()
        visibleFiles = 100
        commits = []
        nextCommitOffset = nil
    }
    func compare() {
        guard !base.isEmpty, !target.isEmpty, !loading else { return }
        loading = true
        error = nil
        let id = UUID()
        requestID = id
        let from = base
        let to = target
        let mode = kind
        let selected = ancestor
        let existing = plan
        work = Task { [self] in
            defer { if requestID == id { loading = false } }
            do {
                let prepared: ReferenceComparisonPlan
                if let existing {
                    prepared = existing
                } else {
                    prepared = try await session.service.prepareReferenceComparison(
                        base: from, target: to, kind: mode)
                }
                guard requestID == id, !Task.isCancelled else { return }
                plan = prepared
                if mode == .mergeBase, prepared.mergeBases.count > 1, selected.isEmpty { return }
                let compared = try await session.service.referenceComparison(
                    prepared, mergeBase: selected.isEmpty ? nil : selected)
                guard requestID == id, !Task.isCancelled else { return }
                result = compared
                detail.useComparison(compared.comparison)
                if mode == .mergeBase {
                    let page = try await session.service.comparisonCommits(prepared)
                    guard requestID == id, !Task.isCancelled else { return }
                    commits = page.commits
                    nextCommitOffset = page.nextOffset
                }
            } catch { if requestID == id, !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func cancel() {
        work?.cancel()
        requestID = UUID()
        loading = false
        detail.cancel()
    }
    func loadMoreCommits() {
        guard let plan, let offset = nextCommitOffset, !loadingCommits else { return }
        let id = requestID
        loadingCommits = true
        Task { [self] in
            defer { loadingCommits = false }
            do {
                let page = try await session.service.comparisonCommits(plan, offset: offset)
                guard requestID == id else { return }
                commits += page.commits
                nextCommitOffset = page.nextOffset
            } catch { if requestID == id { self.error = error.localizedDescription } }
        }
    }
}

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

    func useComparison(_ value: CommitComparison) {
        releaseCache()
        comparison = value
        selectedPath = value.files.first?.path
        error = nil
        fileError = nil
    }

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
