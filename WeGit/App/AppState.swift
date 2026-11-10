import AppKit
import Observation
import SwiftData
import SwiftUI
import WeGitCore

@Model
final class RecentRepository {
    @Attribute(.unique) var path: String
    var name: String
    var openedAt: Date
    var pinned: Bool
    init(path: String, name: String) {
        self.path = path
        self.name = name
        openedAt = Date()
        pinned = false
    }
}

enum WorkspaceRoute: String, CaseIterable, Identifiable {
    case changes = "更改"
    case history = "提交历史"
    case branches = "分支"
    case stashes = "暂存记录"
    case tags = "标签"
    var id: String { rawValue }
    var title: String { self == .stashes ? L10n.text("储藏") : L10n.key(rawValue) }
    var icon: String {
        switch self {
        case .changes: "square.and.pencil"
        case .history: "clock.arrow.circlepath"
        case .branches: "arrow.triangle.branch"
        case .stashes: "archivebox"
        case .tags: "tag"
        }
    }
}

@Observable @MainActor
final class WorkspaceState {
    // The inspector observes the same comparison and selection as the visible diff.
    // A route/session identity prevents a disappearing pane from exposing stale data.
    var commitInspection: CommitInspection?
    var route: WorkspaceRoute = .changes
    var selectedFile: String? {
        didSet {
            if selectedFile != oldValue, selectedFile != nil { ViewPerformanceJournal.selectionChanged() }
        }
    }
    var selectedCommit: GitCommit?
    var diff: FileDiff?
    var diffDisplay: DiffDisplayState?
    var diskDisplay: DiskDiffDisplayState?
    var diffSummary: DiffSummary?
    var diffLimit: DiffContentLimit?
    var diffCancelled = false
    var wordDiff = false
    var diffError: String?
    var commitDiff = ""
    var inspector = false
    var inspectorResourcesRequestID: UUID?
    var filter = ""
    var changeFilter = ChangeKindFilter.all
    var changesByFolder = false
    var collapsedChangeGroups: Set<String> = []
    var collapsedChangeFolders: Set<String> = []
    var fileFilter: ChangeFilter { ChangeFilter(query: filter, kind: changeFilter) }
    var branchFilter = ""
    var splitDiff = false
    var diffOptions = DiffReadOptions()
    var shellRenderID = UUID()
    var loadingDiff = false
    var refreshingDiff = false
    var diffBranch: String?
    var diffReadNotice: String?
    var savedView: RepositoryViewPreferences {
        RepositoryViewPreferences(
            route: route.rawValue, selectedFile: selectedFile, inspector: inspector,
            filter: filter, branchFilter: branchFilter, splitDiff: splitDiff, wordDiff: wordDiff,
            contextLines: diffOptions.contextLines, ignoreWhitespace: diffOptions.ignoreWhitespace,
            changeFilter: changeFilter.rawValue, changesByFolder: changesByFolder)
    }
}

struct CommitInspection {
    let sessionID: UUID
    let route: WorkspaceRoute
    let detail: CommitDetailState
    let allowsFileHistory: Bool
}

@Observable @MainActor
final class RepositorySession {
    let id = UUID()
    let service: RepositoryService
    var status = RepositoryStatus()
    var branches: [GitBranch] = []
    var branchTips: [String: GitCommit] = [:]
    let historyState: HistoryState
    var history: [GitCommit] { historyState.commits }
    var remotes: [String] = []
    var pendingTagPush: TagPushPlan?
    var tagPushFeedback: OperationFeedbackResult?
    var statusRenderID = UUID()
    var watcherRenderID: UUID?
    #if WEGIT_PERFORMANCE
        private var pendingWatcherRenderID: UUID?
    #endif
    var generation = 0
    var diffGeneration = 0
    var historyGeneration = 0
    var hasLoaded = false
    var isStale = true
    var isRefreshing = false
    var refreshError: String?
    var observationWarning: String?
    var lastRefreshed: Date?
    private(set) var isActive = false
    private(set) var lastUsed = Date()
    var onIdle: (@MainActor () -> Void)?
    var isBusy = false
    private(set) var updateHandoffSuspended = false
    var activityLabel = ""
    var error: String?
    var details = ""
    var operationFeedback: OperationFeedbackResult?
    var operationFeedbackContext: OperationFeedbackContext = .standard
    var lastTrashedFile: URL?
    var pendingPush: PendingPushRecord? {
        didSet {
            defaults.set(
                pendingPush.flatMap { try? JSONEncoder().encode($0) },
                forKey: "pending-push:" + location.persistenceID)
        }
    }
    var pendingPushCommit: String? { pendingPush?.commit }
    var legacyDraft: String?
    private(set) var draftRevision: UInt64 = 0
    @ObservationIgnored private var draftInitialized = false
    private(set) var draftOwner: UUID?
    var draftSaveError: String?
    private(set) var message: String { didSet { if message != oldValue { draftChanged() } } }
    private var replacedMessage: (before: String, after: String, revision: UInt64)?
    @ObservationIgnored private var amendFillTask: Task<Void, Never>?
    @ObservationIgnored private var draftLeaseID = UUID()
    var canUndoMessageReplacement: Bool {
        replacedMessage?.after == message && replacedMessage?.revision == draftRevision
    }
    func savedMessages() throws -> [String] {
        try CommitMessageHistory(defaults: defaults).messages(in: location)
    }
    private var clearedMessageHistory: Data?
    var canUndoHistoryClear: Bool {
        clearedMessageHistory != nil && !CommitMessageHistory(defaults: defaults).hasSavedData(in: location)
    }
    func clearSavedMessages() {
        clearedMessageHistory = CommitMessageHistory(defaults: defaults).clear(in: location)
    }
    func undoHistoryClear() {
        guard let data = clearedMessageHistory, canUndoHistoryClear else { return }
        CommitMessageHistory(defaults: defaults).restore(data, in: location)
        clearedMessageHistory = nil
    }
    private(set) var amend = false { didSet { if amend != oldValue { draftChanged() } } }
    @ObservationIgnored private var activeOwners: Set<UUID> = []
    @ObservationIgnored private let legacyOwner = UUID()
    @ObservationIgnored var historyOwner: UUID?
    var subscriberCount: Int { activeOwners.count }
    private var refreshID = UUID()
    private var watcher: RepositoryWatcher?
    private var debounce: Task<Void, Never>?
    private var pendingRefresh: RepositoryRefreshScope = .all
    private var refreshTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let preferences: AppPreferences
    private let persistence: WindowSessionPersistence?
    private let allowLegacyPersistence: Bool
    private var draftKey: String { "draft-v2:" + service.location.persistenceID }

    init(
        service: RepositoryService, defaults: UserDefaults, preferences: AppPreferences,
        persistence: WindowSessionPersistence? = nil, allowLegacyPersistence: Bool = true
    ) {
        self.service = service
        historyState = HistoryState(service: service)
        self.defaults = defaults
        self.preferences = preferences
        self.persistence = persistence
        self.allowLegacyPersistence = allowLegacyPersistence
        message =
            preferences.saveDrafts
            ? defaults.string(forKey: "draft-v2:" + service.location.persistenceID) ?? "" : ""
        if preferences.saveDrafts, let persistence {
            do {
                if let draft = try persistence.readDraft(
                    workspaceID: service.location.persistenceID,
                    legacyKey: "draft-v2:" + service.location.persistenceID)
                {
                    message = draft.text
                    draftRevision = draft.revision
                    amend = draft.amend ?? false
                }
            } catch { draftSaveError = error.localizedDescription }
        }
        legacyDraft = defaults.string(forKey: "draft:" + service.location.id).flatMap {
            $0.isEmpty ? nil : $0
        }
        pendingPush = defaults.data(forKey: "pending-push:" + service.location.persistenceID)
            .flatMap { try? JSONDecoder().decode(PendingPushRecord.self, from: $0) }
        draftInitialized = true
    }
    var location: RepositoryLocation { service.location }
    func canEditDraft(owner: UUID) -> Bool {
        !updateHandoffSuspended && activeOwners.contains(owner) && (draftOwner == nil || draftOwner == owner)
    }
    func claimDraft(_ owner: UUID) {
        guard !updateHandoffSuspended, activeOwners.contains(owner) else { return }
        if draftOwner != owner {
            amendFillTask?.cancel()
            draftLeaseID = UUID()
        }
        draftOwner = owner
    }
    private func canMutateDraft(owner: UUID, revision: UInt64) -> Bool {
        canEditDraft(owner: owner) && draftRevision == revision && revision < UInt64.max - 1
    }
    func editDraft(_ text: String, owner: UUID, revision: UInt64) -> Bool {
        guard canMutateDraft(owner: owner, revision: revision) else { return false }
        draftOwner = owner
        if message != text { amendFillTask?.cancel() }
        message = text
        return true
    }
    func replaceDraft(_ text: String, owner: UUID, revision: UInt64) -> Bool {
        guard canMutateDraft(owner: owner, revision: revision) else { return false }
        let previous = message
        guard editDraft(text, owner: owner, revision: revision) else { return false }
        replacedMessage = (previous, text, draftRevision)
        return true
    }
    func undoDraftReplacement(owner: UUID, revision: UInt64) -> Bool {
        guard canMutateDraft(owner: owner, revision: revision), canUndoMessageReplacement,
            let previous = replacedMessage
        else { return false }
        guard editDraft(previous.before, owner: owner, revision: revision) else { return false }
        replacedMessage = nil
        return true
    }
    func setAmend(_ value: Bool, owner: UUID, revision: UInt64) -> Bool {
        guard canMutateDraft(owner: owner, revision: revision) else { return false }
        if amend == value { return true }
        claimDraft(owner)
        amendFillTask?.cancel()
        amend = value
        guard value, message.isEmpty, let head = status.head else { return true }
        let expectedRevision = draftRevision
        let lease = draftLeaseID
        // The session starts one read for the explicit toggle. Sibling views do not
        // observe amend changes and independently fill or overwrite the shared draft.
        amendFillTask = Task {
            do {
                let commit = try await service.readCommit(head)
                try Task.checkCancellation()
                guard draftLeaseID == lease, status.head == head, amend, message.isEmpty,
                    canMutateDraft(owner: owner, revision: expectedRevision)
                else { return }
                _ = editDraft(commit.message, owner: owner, revision: expectedRevision)
            } catch {
                if !Task.isCancelled, draftLeaseID == lease,
                    canMutateDraft(owner: owner, revision: expectedRevision)
                {
                    show(error)
                }
            }
        }
        return true
    }
    func copyDraftIfEmpty(_ text: String) {
        guard message.isEmpty, draftRevision == 0, draftOwner == nil, activeOwners.isEmpty else { return }
        message = text
    }
    private func draftChanged() {
        guard draftInitialized else { return }
        guard draftRevision < UInt64.max - 1 else {
            draftSaveError = L10n.text("草稿修订号无法更新，原始内容已保留。")
            return
        }
        draftRevision += 1
        guard preferences.saveDrafts else { return }
        do {
            if let persistence {
                try persistence.saveDraft(
                    SharedDraftSnapshot(revision: draftRevision, text: message, amend: amend),
                    workspaceID: location.persistenceID)
            } else if allowLegacyPersistence {
                defaults.set(message, forKey: draftKey)
            } else {
                throw WindowSessionPersistence.Failure.invalid
            }
            draftSaveError = nil
        } catch { draftSaveError = error.localizedDescription }
    }
    func suspendForUpdate(_ value: Bool) {
        updateHandoffSuspended = value
        if value {
            amendFillTask?.cancel()
            draftLeaseID = UUID()
        }
    }
    var canWrite: Bool {
        !updateHandoffSuspended && hasLoaded && !isStale && !isBusy
            && !preferences.configurationWriteInProgress
    }
    var writeReason: String {
        if updateHandoffSuspended { return L10n.text("正在准备更新安装") }
        if preferences.configurationWriteInProgress { return L10n.text("正在保存 Git 配置") }
        if isBusy { return L10n.text("正在执行 \(activityLabel)") }
        if isStale { return L10n.text("仓库状态已过期，请先刷新") }
        if !hasLoaded { return L10n.text("请先读取仓库状态") }
        return ""
    }
    var isEditingRebase: Bool {
        status.rebaseRecovery?.interactiveEditPause == true && status.rebaseRecovery?.canContinue == true
    }
    var canCommit: Bool {
        canWrite && status.conflicts.isEmpty && (status.sequencer == .none || isEditingRebase)
            && status.commitQueue?.phase.pending != true && status.commitQueueUnavailable == nil
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (amend ? status.head != nil : status.files.contains(where: \.staged))
    }
    var canSync: Bool {
        canWrite && status.head != nil && !status.isDetached
            && status.commitQueue?.phase.pending != true
            && status.sequencer == .none && status.conflicts.isEmpty && !remotes.isEmpty
    }
    var canRebase: Bool {
        canWrite && status.head != nil && !status.isDetached && status.files.isEmpty
            && status.commitQueue?.phase.pending != true
            && status.sequencer == .none
    }
    var rebaseReason: String? {
        if !canWrite { return writeReason }
        if status.head == nil || status.isDetached { return L10n.text("请先切换到有提交的本地分支。") }
        if status.sequencer != .none { return L10n.text("请先完成当前 Git 操作。") }
        if !status.files.isEmpty { return L10n.text("请先提交或保存工作区改动。") }
        return nil
    }
    var canCommitAndPush: Bool {
        canCommit && status.sequencer == .none && !status.isDetached && !remotes.isEmpty
            && pendingPush?.verification == nil
    }
    var canVerifyPendingPush: Bool { canWrite && pendingPush?.verification != nil }
    var syncReason: String {
        if preferences.configurationWriteInProgress { return L10n.text("正在保存 Git 配置") }
        if isBusy { return L10n.text("正在执行 \(activityLabel)") }
        if isStale { return L10n.text("仓库状态已过期，请先刷新") }
        if !hasLoaded { return L10n.text("请先读取仓库状态") }
        if remotes.isEmpty { return L10n.text("尚未配置远端，请先添加 Remote") }
        if status.head == nil { return L10n.text("请先创建本地提交") }
        if status.isDetached { return L10n.text("请先切换到本地分支") }
        if status.sequencer != .none || !status.conflicts.isEmpty { return L10n.text("请先完成当前 Git 操作") }
        return L10n.text("选择远端、目标分支和同步方式")
    }
    var commitReason: String {
        if isBusy { return L10n.text("正在执行 \(activityLabel)") }
        if isStale { return L10n.text("请先刷新仓库状态") }
        if !status.conflicts.isEmpty { return L10n.text("请先解决冲突") }
        if status.sequencer != .none && !isEditingRebase { return L10n.text("请先完成当前 Git 操作") }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10n.text("填写提交消息") }
        return L10n.text("选择需要提交的内容并暂存")
    }

    func activate(owner: UUID? = nil) {
        activeOwners.insert(owner ?? legacyOwner)
        lastUsed = Date()
        guard !isActive else { return }
        isActive = true
        isStale = true
        pendingRefresh = .all
        observationWarning = nil
        do {
            watcher = try RepositoryWatcher(location: location) { [weak self] scope in
                Task { @MainActor in
                    if let self {
                        #if WEGIT_PERFORMANCE
                            let id = UUID()
                            self.pendingWatcherRenderID = id
                            ViewPerformanceJournal.begin("watcher", id: id)
                        #endif
                        self.scheduleRefresh(scope: scope)
                    }
                }
            }
        } catch { observationWarning = error.localizedDescription }
    }

    func deactivate(owner: UUID? = nil) {
        let owner = owner ?? legacyOwner
        activeOwners.remove(owner)
        if draftOwner == owner {
            amendFillTask?.cancel()
            draftLeaseID = UUID()
            draftOwner = nil
        }
        guard activeOwners.isEmpty else { return }
        isActive = false
        suspendRefresh()
        watcher?.stop()
        watcher = nil
        historyState.releaseCache()
        branchTips.removeAll()
        isStale = true
    }

    private func suspendRefresh() {
        debounce?.cancel()
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        pendingRefresh.formUnion(.all)
    }

    func scheduleRefresh(scope: RepositoryRefreshScope = .all) {
        pendingRefresh.formUnion(scope)
        guard isActive else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, isActive, !isBusy else { return }
            await refresh(scope: [])
        }
    }

    func refresh(scope: RepositoryRefreshScope = .all) async {
        pendingRefresh.formUnion(scope)
        guard isActive || isBusy else { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let request = UUID()
        refreshID = request
        isRefreshing = true
        let work = Task {
            defer {
                if refreshID == request {
                    isRefreshing = false
                    refreshTask = nil
                }
            }
            while !pendingRefresh.isEmpty && !Task.isCancelled && refreshID == request {
                let scope: RepositoryRefreshScope = hasLoaded ? pendingRefresh : .all
                pendingRefresh = []
                do {
                    let paintID = UUID()
                    #if WEGIT_PERFORMANCE
                        let watcherID = pendingWatcherRenderID
                    #endif
                    ViewPerformanceJournal.begin("status", id: paintID)
                    ViewPerformanceJournal.begin("status-read", id: paintID)
                    let data = try await service.readSnapshot(
                        scope: scope,
                        previousHead: status.head, previousBranch: status.branch)
                    ViewPerformanceJournal.finish("status-read", id: paintID)
                    guard refreshID == request, !Task.isCancelled, isActive || isBusy else { return }
                    statusRenderID = paintID
                    status = data.status
                    #if WEGIT_PERFORMANCE
                        watcherRenderID = watcherID
                        if pendingWatcherRenderID == watcherID { pendingWatcherRenderID = nil }
                    #endif
                    if let branches = data.branches { self.branches = branches }
                    if let remotes = data.remotes { self.remotes = remotes }
                    generation += 1
                    if data.scope.contains(.diff) { diffGeneration += 1 }
                    if data.scope.contains(.history) { historyGeneration += 1 }
                    hasLoaded = true
                    isStale = false
                    refreshError = nil
                    lastRefreshed = data.readAt
                } catch is CancellationError { return } catch {
                    guard refreshID == request, !Task.isCancelled else { return }
                    isStale = true
                    refreshError = error.localizedDescription
                    return
                }
            }
        }
        refreshTask = work
        await work.value
    }

    func loadHistory() async {
        await historyState.synchronize()
    }

    func loadBranchTip(_ oid: String) async {
        guard branchTips[oid] == nil else { return }
        do {
            let commit = try await service.readCommit(oid)
            guard !Task.isCancelled else { return }
            if branchTips.count >= 256, let key = branchTips.keys.first {
                branchTips.removeValue(forKey: key)
            }
            branchTips[oid] = commit
        } catch {
            // The verified branch OID remains visible if extra commit details are unavailable.
        }
    }

    func perform(
        _ name: String, onSuccess: (@MainActor () -> Void)? = nil,
        operation: @escaping @Sendable (RepositoryService) async throws -> Void
    ) {
        performResult(name, onSuccess: onSuccess) {
            try await operation($0)
            return .completed(message: L10n.text("\(name)完成"))
        }
    }

    func performResult(
        _ name: String, context: OperationFeedbackContext = .standard,
        onSuccess: (@MainActor () -> Void)? = nil,
        operation: @escaping @Sendable (RepositoryService) async throws -> OperationFeedbackOutcome
    ) {
        guard !isBusy else { return }
        guard canWrite else {
            let message = L10n.text("仓库状态已过期，请刷新后再操作。")
            error = message
            details = ""
            operationFeedback = .failure(message: message, details: nil)
            operationFeedbackContext = context
            return
        }
        suspendRefresh()
        isBusy = true
        activityLabel = name
        error = nil
        details = ""
        operationFeedback = nil
        operationFeedbackContext = context
        let pinned = service.expectingBranch(status.branch)
        operationTask = Task {
            var succeeded = false
            do {
                let outcome = try await operation(pinned)
                operationFeedback = outcome.feedback
                succeeded = outcome.didComplete
            } catch { show(error) }
            // Refresh in a fresh task even if the operation task was cancelled.
            await Task { await self.refresh() }.value
            isBusy = false
            activityLabel = ""
            operationTask = nil
            if succeeded { onSuccess?() }
            if !pendingRefresh.isEmpty { scheduleRefresh(scope: []) }
            onIdle?()
        }
    }

    func commit() {
        guard canCommit else { return }
        let text = message
        let revision = draftRevision
        let amend = amend
        let head = status.head
        let pinned = service.expectingBranch(status.branch)
        suspendRefresh()
        isBusy = true
        activityLabel = L10n.text("提交")
        error = nil
        details = ""
        operationFeedback = nil
        operationFeedbackContext = .commit
        operationTask = Task {
            do {
                _ = try await pinned.commit(message: text, amend: amend, expectedHead: head)
                completeCommit(message: text, revision: revision)
                operationFeedback = .success(message: L10n.text("提交完成"))
            } catch { show(error) }
            await Task { await self.refresh() }.value
            isBusy = false
            activityLabel = ""
            operationTask = nil
            if !pendingRefresh.isEmpty { scheduleRefresh(scope: []) }
            onIdle?()
        }
    }
    func cancel() { operationTask?.cancel() }
    func completeCommit(message text: String, revision: UInt64? = nil) {
        try? CommitMessageHistory(defaults: defaults).append(text, in: location)
        if revision == draftRevision && message == text {
            amendFillTask?.cancel()
            replacedMessage = nil
            amend = false
            message = ""
        }
        if persistence == nil, allowLegacyPersistence, defaults.string(forKey: draftKey) == text {
            defaults.removeObject(forKey: draftKey)
        }
    }
    func show(_ error: any Error) {
        self.error = error.localizedDescription
        operationFeedback = .from(error)
        details =
            (error as? GitFailure)?.details ?? (error as? PullFailure)?.details
            ?? (error as? CommitOutcomeUnknown)?.details ?? (error as? PushOutcomeUnknown)?.details
            ?? (error as? SingleCommitOutcomeUnknown)?.details
            ?? (error as? RebaseOutcomeUnknown)?.details
            ?? (error as? TagPushOutcomeUnknown)?.details ?? ""
        if error is RebaseOutcomeUnknown { details = operationFeedback?.details ?? details }
        if let path = (error as? UntrackedTrashFailure)?.trashURL, path.isFileURL { lastTrashedFile = path }
    }
}

@MainActor private final class WeakWindowState {
    weak var value: AppState?
    init(_ value: AppState) { self.value = value }
}

@Observable @MainActor
final class ApplicationWorkspaceRuntime {
    struct PendingThemeImport {
        let payload: ThemeImportPayload
        let windowID: UUID
    }
    var sessions: [String: RepositorySession] = [:]
    var pendingThemeImports: [PendingThemeImport] = []
    var recents: [RecentRepository] = []
    let persistence: WindowSessionPersistence?
    let services: ApplicationDeliveryServices
    let persistenceError: String?
    @ObservationIgnored private var peers: [UUID: WeakWindowState] = [:]
    @ObservationIgnored var windowCoordinator: WorkspaceWindowCoordinator?
    var activeWindowID: UUID?
    private(set) var primaryWindowID: UUID?
    var installationReady = false
    var updateHandoffInProgress = false
    var updateExitAuthorized = false
    var updateTerminationApproved = false
    var persistenceGeneration: UInt64 = 0
    var liveStates: [AppState] { peers.values.compactMap(\.value) }
    var activeState: AppState? {
        if let window = NSApp.keyWindow,
            let state = liveStates.first(where: { $0.nativeWindow === window })
        {
            return state
        }
        return activeWindowID.flatMap { peers[$0]?.value }
            ?? liveStates.first(where: \.mainWorkspaceMounted) ?? liveStates.first
    }
    var hasOperations: Bool {
        sessions.values.contains(where: \.isBusy)
            || liveStates.contains {
                $0.cloneRunning || $0.initialization.isBusy || $0.preferences.configurationWriteInProgress
            }
    }

    init(defaults: UserDefaults, domainName: String?) {
        services = ApplicationDeliveryServices(defaults: defaults)
        do {
            persistence = try WindowSessionPersistence(defaults: defaults, domainName: domainName)
            persistenceError = nil
        } catch {
            persistence = nil
            persistenceError = error.localizedDescription
        }
    }

    func register(_ app: AppState) {
        if primaryWindowID == nil { primaryWindowID = app.windowID }
        peers = peers.filter { $0.value.value != nil }
        peers[app.windowID] = WeakWindowState(app)
    }

    func trimSessions() {
        let removable = sessions.values.filter { !$0.isActive && !$0.isBusy && $0.draftSaveError == nil }
            .sorted { $0.lastUsed < $1.lastUsed }
        for session in removable where sessions.count > 8 {
            sessions.removeValue(forKey: session.location.id)
        }
    }

    func refreshActiveSessions() {
        for session in sessions.values where session.isActive && !session.isBusy {
            Task { await session.refresh() }
        }
    }
}

private struct WindowHistoryReading: Codable {
    let scope: String
    let query: String
    let field: String
    let selected: [String]
}

@Observable @MainActor
final class AppState {
    var workspace = WorkspaceState()
    let windowID: UUID
    let runtime: ApplicationWorkspaceRuntime
    let defaults: UserDefaults
    let migrationState: ApplicationMigrationState?
    let migrationFailure: String?
    var migrationRestartRequired = false
    var isMigrationBlocked: Bool {
        migrationFailure != nil || migrationRestartRequired || migrationState?.canUseVersion2 == false
    }
    var readyForUpdate: Bool {
        !isMigrationBlocked && initialRestoreCompleted && !isOpening && workspaceSaveError == nil
    }
    let preferences: AppPreferences
    private(set) var engine: GitEngine
    let authentication: AuthenticationController
    var session: RepositorySession? {
        didSet {
            if session !== oldValue {
                cancelPendingHistoryRestore()
                pendingSearchResult = nil
                pendingSearchSession = nil
                tagSearchTarget = nil
                stashSearchTarget = nil
            }
            if selectedLinesRequest?.session !== session { selectedLinesRequest = nil }
            if fileModificationRequest?.session !== session { fileModificationRequest = nil }
            if ignoreRuleRequest?.session !== session { ignoreRuleRequest = nil }
            if patchImportRequest?.session !== session { patchImportRequest = nil }
            if conflictEditorRequest?.session !== session { conflictEditorRequest = nil }
        }
    }
    var sessions: [String: RepositorySession] {
        get { runtime.sessions }
        set { runtime.sessions = newValue }
    }
    var recents: [RecentRepository] {
        get { runtime.recents }
        set { runtime.recents = newValue }
    }
    @ObservationIgnored private var histories: [UUID: HistoryState] = [:]
    @ObservationIgnored private var pendingSelectedCommitID: String?
    @ObservationIgnored private var pendingHistorySelectionIDs: Set<String>?
    @ObservationIgnored private var historyRestoreID = UUID()
    @ObservationIgnored weak var nativeWindow: NSWindow?
    var error: String?
    var isOpening = false
    var mainWorkspaceMounted = false
    var mainWindowRequested = false
    var menuBarPresented = false
    var menuBarRequestID = UUID()
    var windowContentWidth: CGFloat = 1360
    private var initialRestoreCompleted = false
    var clonePresented = false
    private(set) var clone: CloneViewModel
    var cloneRunning: Bool { clone.isBusy }
    var initializationPresented = false
    private(set) var initialization: RepositoryInitializationViewModel
    var anyOperationRunning: Bool {
        runtime.hasOperations
    }
    var activityPresented = false
    var palettePresented = false
    var pendingPaletteCommand: WorkspaceCommand?
    var pendingPaletteSession: RepositorySession?
    var pendingPaletteBranch: String?
    var branchPresented = false
    var remoteManagementPresented = false
    var tagCreationRequest: TagCreationRequest?
    var singleCommitRequest: SingleCommitRequest?
    var commitQueueRequest: CommitQueueRequest?
    var taskSwitchRequest: TaskSwitchRequest?
    var stashBranchRequest: StashBranchRequest?
    var signatureRequest: SignatureRequest?
    var commitMessageRequest: CommitMessageRequest?
    var pendingSignatureAfterReader: SignatureRequest?
    var resetRequest: ResetRequest?
    var recoveryBrowserRequest: RecoveryBrowserRequest?
    var pendingRecoveryAfterReset: RecoveryBrowserRequest?

    func resetDidDismiss() {
        guard let request = pendingRecoveryAfterReset else { return }
        pendingRecoveryAfterReset = nil
        if request.session === session { recoveryBrowserRequest = request }
    }
    var selectedLinesRequest: SelectedLinesRequest?
    var fileModificationRequest: FileModificationRequest?
    var ignoreRuleRequest: IgnoreRuleRequest?
    var patchImportRequest: PatchImportRequest?
    var mailPatchRequest: MailPatchRequest?
    var pendingRecoveryAfterPatch: RecoveryBrowserRequest?

    func patchImportDidDismiss() {
        guard let request = pendingRecoveryAfterPatch else { return }
        pendingRecoveryAfterPatch = nil
        if request.session === session { recoveryBrowserRequest = request }
    }
    var pendingFileModificationAfterReader: FileModificationRequest?
    var pendingRecoveryAfterFileModification: RecoveryBrowserRequest?

    func restoreFileAfterReader(_ request: FileModificationRequest) {
        guard request.session === session else { return }
        pendingFileModificationAfterReader = request
        if referenceComparisonRequest != nil {
            referenceComparisonRequest = nil
        } else if fileHistoryRequest != nil {
            fileHistoryRequest = nil
        } else if blameRequest != nil {
            blameRequest = nil
        } else {
            fileReaderDidDismiss()
        }
    }

    func fileReaderDidDismiss() {
        if let request = pendingFileModificationAfterReader {
            pendingFileModificationAfterReader = nil
            if request.session === session { fileModificationRequest = request }
        } else if let request = pendingSignatureAfterReader {
            pendingSignatureAfterReader = nil
            if request.session === session { signatureRequest = request }
        }
    }

    func presentSignature(_ request: SignatureRequest) {
        guard request.session === session else { return }
        pendingFileModificationAfterReader = nil
        pendingSignatureAfterReader = request
        if referenceComparisonRequest != nil {
            referenceComparisonRequest = nil
        } else if fileHistoryRequest != nil {
            fileHistoryRequest = nil
        } else if blameRequest != nil {
            blameRequest = nil
        } else {
            fileReaderDidDismiss()
        }
    }

    func fileModificationDidDismiss() {
        guard let request = pendingRecoveryAfterFileModification else { return }
        pendingRecoveryAfterFileModification = nil
        if request.session === session { recoveryBrowserRequest = request }
    }
    var conflictEditorRequest: ConflictEditorRequest?
    var blameRequest: BlameRequest?
    var fileHistoryRequest: FileHistoryRequest?
    var branchSwitchRequest: BranchSwitchRequest?
    var syncRequest: SyncRequest?
    var historyDepthRequest: HistoryDepthRequest?
    var referenceComparisonRequest: ReferenceComparisonRequest?
    var searchRequest: RepositorySearchRequest?
    var pendingSearchResult: RepositoryQueryResult?
    var pendingSearchSession: RepositorySession?
    var tagSearchTarget: GitTag?
    var stashSearchTarget: GitStash?
    var workspaceSaveError: String?
    var worktreeManagementRequest: WorktreeManagementRequest?
    var themeImportRequest: ThemeImportPayload?
    private var themeImportReady = false

    /// Includes queued sheet-to-sheet transitions so an external request cannot
    /// take the presentation slot between a reader and its follow-up action.
    var hasWorkspacePresentation: Bool {
        clonePresented || initializationPresented || activityPresented || palettePresented
            || branchPresented || remoteManagementPresented || repositoryPickerPresented
            || tagCreationRequest != nil || singleCommitRequest != nil || commitQueueRequest != nil
            || taskSwitchRequest != nil || stashBranchRequest != nil || signatureRequest != nil
            || commitMessageRequest != nil || resetRequest != nil || recoveryBrowserRequest != nil
            || selectedLinesRequest != nil || fileModificationRequest != nil || ignoreRuleRequest != nil
            || patchImportRequest != nil || mailPatchRequest != nil || conflictEditorRequest != nil
            || blameRequest != nil || fileHistoryRequest != nil || branchSwitchRequest != nil
            || syncRequest != nil || searchRequest != nil || worktreeManagementRequest != nil
            || referenceComparisonRequest != nil || historyDepthRequest != nil || themeImportRequest != nil
            || pendingRecoveryAfterReset != nil || pendingRecoveryAfterPatch != nil
            || pendingFileModificationAfterReader != nil || pendingSignatureAfterReader != nil
            || pendingRecoveryAfterFileModification != nil || pendingSearchResult != nil
            || pendingPaletteCommand != nil || pendingPaletteBranch != nil
            || pendingRepositoryPickerAction != nil
    }

    var canPresentThemeImport: Bool {
        themeImportReady && mainWorkspaceMounted && !isOpening && !anyOperationRunning
            && !isMigrationBlocked && !runtime.updateHandoffInProgress
            && authentication.request == nil && error == nil && !hasWorkspacePresentation
    }

    func receiveThemeURL(_ url: URL) {
        do {
            let payload = try ThemeImportPayload.parse(url)
            guard !runtime.liveStates.contains(where: { $0.themeImportRequest?.id == payload.id }),
                !runtime.pendingThemeImports.contains(where: { $0.payload.id == payload.id })
            else { return }
            guard runtime.pendingThemeImports.count < 8 else {
                throw ModelFailure.unsupported(L10n.text("待处理的主题请求已满，请先完成当前导入。"))
            }
            runtime.pendingThemeImports.append(.init(payload: payload, windowID: windowID))
            mainWindowRequested = true
            runtime.windowCoordinator?.showActiveWindow()
            drainThemeImports()
        } catch { self.error = error.localizedDescription }
    }

    func drainThemeImports() {
        guard let pending = runtime.pendingThemeImports.first,
            !runtime.liveStates.contains(where: { $0.themeImportRequest != nil })
        else { return }
        let target =
            runtime.liveStates.first {
                $0.windowID == pending.windowID && $0.mainWorkspaceMounted
            } ?? runtime.activeState.flatMap { $0.mainWorkspaceMounted ? $0 : nil }
            ?? runtime.liveStates.first(where: \.mainWorkspaceMounted)
        guard let target else { return }
        guard target === self else {
            target.drainThemeImports()
            return
        }
        guard canPresentThemeImport, nativeWindow?.attachedSheet == nil else { return }
        themeImportRequest = runtime.pendingThemeImports.removeFirst().payload
    }

    func workspaceSheetDidDismiss(_ continuation: () -> Void = {}) {
        continuation()
        // SwiftUI has released the old sheet before it gives the next request
        // the same window; follow-up repository actions keep priority.
        DispatchQueue.main.async { [weak self] in self?.drainThemeImports() }
    }
    @ObservationIgnored private var worktreeFocusRestoration: WorktreeFocusRestoration?
    var settingsRequestID = UUID()
    var sidebarRequestID = UUID()
    var sidebarVisible = true
    var repositoryPickerPresented = false
    var pendingRepositoryPickerAction: RepositoryPickerAction?
    var appearance: String {
        get { preferences.appearance }
        set { preferences.appearance = newValue }
    }
    var gitVersion = L10n.text("检测中…")
    var codeSize: Double {
        get { preferences.codeSize }
        set { preferences.codeSize = newValue }
    }
    private let container: ModelContainer?
    private var openingID = UUID()
    private var diffRequestID = UUID()
    private var diffReadTask: Task<Void, Never>?

    static var isUITesting: Bool {
        #if DEBUG || WEGIT_PERFORMANCE
            ProcessInfo.processInfo.arguments.contains("--uitesting")
                || (ProcessInfo.processInfo.environment["WEGIT_UI_TEST_PREVIEW"] == "1"
                    && ProcessInfo.processInfo.environment["WEGIT_UI_TEST_PREFERENCE_DOMAIN"]?
                        .hasPrefix("com.willxue.wegit.UITests.") == true)
        #else
            false
        #endif
    }

    /// Standalone model checks can own a private preference domain.
    init(
        defaultsOverride: UserDefaults? = nil, sharedWith parent: AppState? = nil, windowID: UUID? = nil,
        migrationOverride: ApplicationMigrationState? = nil
    ) {
        let testing = Self.isUITesting
        var testingDomain = "com.willxue.wegit.UITests"
        #if DEBUG
            if testing,
                let requested = ProcessInfo.processInfo.environment["WEGIT_UI_TEST_PREFERENCE_DOMAIN"],
                requested.hasPrefix(testingDomain + "."), requested.count <= 128,
                requested.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
            {
                testingDomain = requested
            }
        #endif
        let preparedMigration: ApplicationMigrationState?
        let migrationError: String?
        if let parent {
            preparedMigration = parent.migrationState
            migrationError = parent.migrationFailure
        } else if let migrationOverride {
            preparedMigration = migrationOverride
            migrationError = nil
        } else if !testing, defaultsOverride == nil {
            do {
                guard let identifier = Bundle.main.bundleIdentifier,
                    let support = FileManager.default.urls(
                        for: .applicationSupportDirectory, in: .userDomainMask
                    ).first
                else { throw ApplicationMigrationFailure.invalid }
                preparedMigration = try ApplicationMigrationState.prepareStandard(
                    defaults: .standard, applicationSupportDirectory: support,
                    applicationIdentifier: identifier)
                migrationError = nil
            } catch {
                preparedMigration = nil
                migrationError = error.localizedDescription
            }
        } else {
            preparedMigration = nil
            migrationError = nil
        }
        migrationState = preparedMigration
        migrationFailure = migrationError
        defaults =
            parent?.defaults ?? preparedMigration?.currentDefaults
            ?? (migrationError == nil ? nil : FailedMigrationPreferences()) ?? defaultsOverride
            ?? (testing ? UserDefaults(suiteName: testingDomain)! : .standard)
        #if DEBUG
            let preserveTestPreferences =
                testing && ProcessInfo.processInfo.arguments.contains("--uitesting-keep-preferences")
        #else
            let preserveTestPreferences = false
        #endif
        if testing && !preserveTestPreferences && defaultsOverride == nil && parent == nil {
            defaults.removePersistentDomain(forName: testingDomain)
        }
        runtime =
            parent?.runtime
            ?? ApplicationWorkspaceRuntime(
                defaults: defaults,
                domainName: defaultsOverride == nil
                    ? (testing ? testingDomain : preparedMigration?.storage.configuration.currentDomain) : nil
            )
        self.windowID = windowID ?? (parent == nil ? runtime.persistence?.primaryID ?? UUID() : UUID())
        preferences = parent?.preferences ?? AppPreferences(defaults: defaults)
        let authentication = parent?.authentication ?? AuthenticationController()
        authentication.presentationPreferences = preferences
        self.authentication = authentication
        let bridge = AskPassBridge(
            helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/WeGitAskPass")
        ) {
            try await authentication.respond(to: $0)
        }
        let git =
            parent?.engine
            ?? GitEngine(
                executable: URL(fileURLWithPath: defaults.string(forKey: "gitExecutable") ?? "/usr/bin/git"),
                activity: ActivityStore(
                    limit: preferences.activityLimit, retention: Double(preferences.activityHours) * 3600),
                authentication: bridge)
        engine = git
        let cloneModel = CloneViewModel(coordinator: CloneCoordinator(engine: git))
        cloneModel.parentPath = preferences.defaultDirectory
        clone = cloneModel
        initialization = RepositoryInitializationViewModel(
            coordinator: RepositoryInitializationCoordinator(engine: git))
        if let parent {
            container = parent.container
        } else if migrationError != nil || preparedMigration?.canUseVersion2 == false {
            container = nil
        } else {
            do {
                let configuration: ModelConfiguration
                if let migrationState {
                    configuration = ModelConfiguration(
                        url: migrationState.currentStoreURL, cloudKitDatabase: .none)
                } else if testing {
                    if let path = ProcessInfo.processInfo.environment["WEGIT_UI_TEST_PERSISTENCE_DIRECTORY"],
                        !path.isEmpty
                    {
                        let directory = URL(fileURLWithPath: path, isDirectory: true)
                        try FileManager.default.createDirectory(
                            at: directory, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700])
                        configuration = ModelConfiguration(
                            url: directory.appending(path: "Repositories.store"), cloudKitDatabase: .none)
                    } else {
                        configuration = ModelConfiguration(
                            isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                    }
                } else {
                    guard let storeURL = migrationState?.currentStoreURL else {
                        throw ApplicationMigrationFailure.invalid
                    }
                    configuration = ModelConfiguration(
                        url: storeURL, cloudKitDatabase: .none)
                }
                container = try ModelContainer(for: RecentRepository.self, configurations: configuration)
            } catch {
                container = nil
                self.error = L10n.text("无法读取最近仓库记录：\(error.localizedDescription)")
            }
        }
        runtime.register(self)
        if parent == nil { runtime.services.configureUpdates(app: self) }
        if let migrationFailure {
            self.error = migrationFailure
        } else if migrationState?.canUseVersion2 == false {
            self.error = L10n.text("数据已恢复为旧格式。v2 数据保留在独立目录，请明确选择后再继续。")
        }
        if let parent { gitVersion = parent.gitVersion }
        if let error = runtime.persistenceError { self.error = error }
        reloadRecents()
        applyDefaultDiffPreferences()
        if parent == nil {
            preferences.onDiffChange = { [weak runtime] in
                for state in runtime?.liveStates ?? [] { state.applyDefaultDiffPreferences() }
            }
            preferences.onActivityChange = { [weak self] in
                guard let self else { return }
                let limit = preferences.activityLimit
                let retention = Double(preferences.activityHours) * 3600
                Task { await self.engine.activity.configure(limit: limit, retention: retention) }
            }
        }
    }

    func reloadRecents() {
        guard let context = container?.mainContext else { return }
        do {
            recents = try context.fetch(
                FetchDescriptor<RecentRepository>(sortBy: [SortDescriptor(\.openedAt, order: .reverse)]))
        } catch { self.error = error.localizedDescription }
    }

    func openPanel() {
        guard !isMigrationBlocked, !runtime.updateHandoffInProgress else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L10n.text("打开仓库")
        panel.message = L10n.text("选择本地 Git 仓库文件夹")
        panel.directoryURL = URL(fileURLWithPath: preferences.defaultDirectory)
        if panel.runModal() == .OK, let url = panel.url { Task { await open(url) } }
    }

    func flushPersistentState() throws {
        try container?.mainContext.save()
        guard defaults.synchronize() else { throw WindowSessionPersistence.Failure.changed }
    }

    func showOriginalDataBackup() {
        guard let migrationState else { return }
        do {
            _ = try migrationState.originalPreferencesSnapshot()
            NSWorkspace.shared.activateFileViewerSelecting([migrationState.originalBackupURL])
        } catch { self.error = error.localizedDescription }
    }

    func restoreOriginalData() {
        guard let migrationState, migrationState.canUseVersion2, !runtime.hasOperations,
            !runtime.updateHandoffInProgress,
            !NSWorkspace.shared.runningApplications.contains(where: {
                [
                    "com.willxue.wegit", "com.willxue.wegit.development", "com.willxue.WeGit",
                    "org.weopen.WeGit", "org.weopen.WeGit.development",
                ].contains($0.bundleIdentifier ?? "")
                    && $0.processIdentifier != getpid()
            })
        else {
            error = L10n.text("请先关闭其他 WeGit 实例并完成当前任务。")
            return
        }
        do {
            try flushPersistentState()
            guard runtime.windowCoordinator?.saveAllWindows(forceForUpdate: true) == true else {
                throw UpdateFailure.busy
            }
            let plan = try migrationState.prepareOriginalRestore()
            guard
                confirm(
                    title: L10n.text("恢复旧格式数据？"),
                    message: L10n.text("将恢复升级前的设置和最近仓库记录。当前 v2 数据会保留在独立目录；恢复后请退出，再安装旧版。"),
                    action: L10n.text("恢复旧格式数据"))
            else { return }
            try migrationState.restoreOriginalData(plan)
            migrationRestartRequired = true
            for session in runtime.sessions.values { session.suspendForUpdate(true) }
            error = L10n.text("旧格式数据已恢复。请退出 WeGit，再安装旧版；v2 数据已保留。")
        } catch { self.error = error.localizedDescription }
    }

    func resumeVersion2Data() {
        guard let migrationState, !runtime.hasOperations else { return }
        do {
            try migrationState.resumeVersion2()
            migrationRestartRequired = true
            error = L10n.text("v2 数据已启用。请退出并重新打开 WeGit。")
        } catch { self.error = error.localizedDescription }
    }

    func open(_ url: URL) async {
        guard !isMigrationBlocked, !runtime.updateHandoffInProgress else { return }
        let request = UUID()
        openingID = request
        ViewPerformanceJournal.begin("shell", id: request)
        isOpening = true
        error = nil
        defer { if openingID == request { isOpening = false } }
        do {
            let location = try await RepositoryService.discover(url, engine: engine)
            guard openingID == request else { return }
            if let current = session, current.location != location, preferences.confirmRepositorySwitch,
                !confirm(
                    title: L10n.text("切换仓库？"),
                    message: L10n.text(
                        "将从 \(current.location.name) 切换到 \(location.name)。现有 Git 操作仍会保留并可在原仓库中查看。"),
                    action: L10n.text("切换仓库"), destructive: false)
            {
                return
            }
            let cached = sessions[location.id]
            let matching = sessions.values.first { $0.location.isSameRepository(as: location) }
            let value: RepositorySession
            if let cached, cached.location == location {
                value = cached
            } else {
                guard ![cached, matching].compactMap({ $0 }).contains(where: \.isBusy) else {
                    throw ModelFailure.unsupported(L10n.text("仓库路径或身份已变化。请等待当前操作结束后重新打开。"))
                }
                value = RepositorySession(
                    service: RepositoryService(
                        location: location, engine: engine,
                        queue: matching?.service.queue),
                    defaults: defaults, preferences: preferences,
                    persistence: runtime.persistence, allowLegacyPersistence: false)
                if let matching, matching.location.id != location.id {
                    value.copyDraftIfEmpty(matching.message)
                    if !matching.isActive { sessions.removeValue(forKey: matching.location.id) }
                }
            }
            saveCurrentWorkspace()
            if session !== value { session?.deactivate(owner: windowID) }
            sessions[location.id] = value
            session = value
            value.onIdle = { [weak runtime] in runtime?.trimSessions() }
            value.activate(owner: windowID)
            diffRequestID = UUID()
            diffReadTask?.cancel()
            diffReadTask = nil
            workspace.loadingDiff = false
            workspace.diffDisplay?.cancelAll()
            workspace.diskDisplay?.cancelAll()
            restoreWorkspace(for: location)
            workspace.shellRenderID = request
            saveCurrentWorkspace()
            if let context = container?.mainContext {
                if let record = recents.first(where: { $0.path == location.root.path }) {
                    record.openedAt = Date()
                } else {
                    context.insert(RecentRepository(path: location.root.path, name: location.name))
                }
                try context.save()
                reloadRecents()
            }
            if !value.hasLoaded || value.isStale { await value.refresh() }
            trimSessionCache()
        } catch { self.error = error.localizedDescription }
    }

    private func trimSessionCache() {
        runtime.trimSessions()
    }

    func closeRepository() {
        guard let session else { return }
        guard !session.isBusy, !preferences.configurationWriteInProgress else {
            session.error = L10n.text("Git 操作或配置保存仍在进行，请等待完成或取消操作后再关闭仓库。")
            return
        }
        saveCurrentWorkspace()
        session.deactivate(owner: windowID)
        cancelDiffRead()
        workspace.diffDisplay?.cancelAll()
        workspace.diskDisplay?.cancelAll()
        workspace = WorkspaceState()
        self.session = nil
        saveCurrentWorkspace()
        trimSessionCache()
    }

    #if DEBUG
        var canRecoverTrashFixture: Bool {
            Self.isUITesting
                && session?.location.root.lastPathComponent.hasPrefix("WeGitActualTrashUI-") == true
                && session?.lastTrashedFile != nil && session?.canWrite == true
        }

        /// Uses the recycling process's existing file access; does not request broad
        /// Trash access for the UI runner. Compiled out of every Release build.
        func recoverTrashFixture() {
            guard canRecoverTrashFixture, let session, let source = session.lastTrashedFile else { return }
            let name = source.lastPathComponent
            guard
                source.deletingLastPathComponent().standardizedFileURL.path
                    == FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
                    .standardizedFileURL.path,
                name.hasPrefix("WeGit-disposable-"), name.hasSuffix(".txt"),
                UUID(uuidString: String(name.dropFirst("WeGit-disposable-".count).dropLast(4))) != nil
            else { return }
            let destination = session.location.root.appending(path: name)
            session.performResult(
                L10n.text("核对回收夹具"), onSuccess: { session.lastTrashedFile = nil },
                operation: { service in
                    try await service.queue.perform {
                        try service.location.validateIdentity()
                        try await Task.detached {
                            let expected = Data("Only this fixture may be recycled and restored.\n".utf8)
                            let values = try source.resourceValues(forKeys: [
                                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                            ])
                            guard values.isRegularFile == true, values.isSymbolicLink != true,
                                values.fileSize == expected.count,
                                try Data(contentsOf: source) == expected,
                                !FileManager.default.fileExists(atPath: destination.path)
                            else { throw ModelFailure.changed }
                            try FileManager.default.moveItem(at: source, to: destination)
                        }.value
                    }
                    return .completed(message: L10n.text("回收夹具已核对并恢复"))
                })
        }
    #endif

    func forget(_ record: RecentRepository) {
        guard let context = container?.mainContext else { return }
        context.delete(record)
        do {
            try context.save()
            reloadRecents()
        } catch { self.error = error.localizedDescription }
    }

    func pin(_ record: RecentRepository) {
        record.pinned.toggle()
        do {
            try container?.mainContext.save()
            reloadRecents()
        } catch { self.error = error.localizedDescription }
    }

    func restore() async {
        guard !isMigrationBlocked else { return }
        if initialRestoreCompleted {
            session?.activate(owner: windowID)
            if let session, !session.isBusy, !preferences.configurationWriteInProgress {
                if !session.hasLoaded || session.isStale { await session.refresh() }
            }
            return
        }
        defer {
            themeImportReady = true
            drainThemeImports()
        }
        do { try await DiffSnapshotStorage.removeAbandoned() } catch {
            self.error = error.localizedDescription
        }
        if !runtime.installationReady {
            do {
                let preferred = defaults.string(forKey: "gitExecutable").map { URL(fileURLWithPath: $0) }
                let installation = try await GitInstallation.detect(preferred: preferred)
                gitVersion = installation.version
                if installation.executable != engine.executable, sessions.isEmpty, !clone.isBusy,
                    !initialization.isBusy
                {
                    engine = GitEngine(
                        executable: installation.executable, activity: engine.activity,
                        authentication: engine.authentication, environment: engine.environment)
                    clone = CloneViewModel(coordinator: CloneCoordinator(engine: engine))
                    clone.parentPath = preferences.defaultDirectory
                    initialization = RepositoryInitializationViewModel(
                        coordinator: RepositoryInitializationCoordinator(engine: engine))
                    for peer in runtime.liveStates where peer !== self { peer.engine = engine }
                }
                runtime.installationReady = true
            } catch {
                self.error = error.localizedDescription
                gitVersion = L10n.text("不可用")
                return
            }
        }
        initialRestoreCompleted = true
        #if DEBUG || WEGIT_PERFORMANCE
            if Self.isUITesting, windowID == runtime.primaryWindowID,
                let path = ProcessInfo.processInfo.environment["WEGIT_UI_TEST_REPOSITORY"]
            {
                await open(URL(fileURLWithPath: path))
                return
            }
        #endif
        let savedPath =
            runtime.persistence?.snapshot(windowID)?.repository
            ?? (windowID == runtime.primaryWindowID ? defaults.string(forKey: "lastRepository") : nil)
        if preferences.restoreRepository, let path = savedPath {
            await open(URL(fileURLWithPath: path))
        }
    }

    var allowsMenuBarExtra: Bool {
        #if DEBUG || WEGIT_PERFORMANCE
            if Self.isUITesting {
                return ProcessInfo.processInfo.arguments.contains("--uitesting-menu-bar")
            }
        #endif
        return true
    }

    func loadDiff(loadLarge: Bool = false) async {
        // A replaced SwiftUI task can reach this actor after its cancellation.
        // It must not cancel the current read or clear its visible result.
        guard !Task.isCancelled else { return }
        diffReadTask?.cancel()
        let previous = workspace.diffDisplay
        let previousDisk = workspace.diskDisplay
        let selected = workspace.selectedFile
        let canPreserve =
            !loadLarge && workspace.diffBranch == session?.status.branch
            && (previous.map {
                !$0.loading && $0.document != nil && selected == $0.diff.layer.rawValue + "|" + $0.diff.path
                    && $0.diff.options == workspace.diffOptions && $0.diff.head == session?.status.head
            } ?? false
                || previousDisk.map {
                    !$0.loading && $0.page != nil
                        && selected == $0.snapshot.layer.rawValue + "|" + $0.snapshot.path
                        && $0.snapshot.options == workspace.diffOptions
                        && $0.snapshot.head == session?.status.head
                } ?? false)
        let request = UUID()
        diffRequestID = request
        defer {
            if diffRequestID == request {
                workspace.loadingDiff = false
                workspace.refreshingDiff = false
            }
        }
        if !canPreserve { clearDiffDisplay() }
        workspace.diffError = nil
        workspace.diffCancelled = false
        workspace.diffReadNotice = nil
        if !loadLarge {
            workspace.diffSummary = nil
            workspace.diffLimit = nil
        }
        guard let session, let selection = workspace.selectedFile,
            let split = selection.firstIndex(of: "|"),
            let layer = DiffLayer(rawValue: String(selection[..<split]))
        else {
            return
        }
        let path = String(selection[selection.index(after: split)...])
        guard session.hasLoaded, !session.isStale else { return }
        guard let file = session.status.files.first(where: { $0.path == path }) else {
            workspace.selectedFile = nil
            return
        }
        if !file.layers.contains(layer) {
            workspace.selectedFile = file.layers.first(where: {
                workspace.fileFilter.matches(file, layer: $0)
            }).map { $0.rawValue + "|" + path }
            // A stage/unstage can remap selection while the task for the old
            // layer is being cancelled. Start a fresh unstructured read as well
            // as changing the task key, so that coalescing that key change cannot
            // leave a selected row with an empty Diff. The normal request token
            // still cancels/suppresses any duplicate or superseded read.
            if let remappedSelection = workspace.selectedFile {
                Task {
                    guard self.session === session, self.workspace.route == .changes,
                        self.workspace.selectedFile == remappedSelection
                    else { return }
                    await self.loadDiff()
                }
            }
            return
        }
        guard workspace.fileFilter.matches(file, layer: layer) else {
            workspace.selectedFile = nil
            return
        }
        ViewPerformanceJournal.begin("diff", id: request, preservingSelection: true)
        let generation = session.diffGeneration
        let options = workspace.diffOptions
        workspace.loadingDiff = !canPreserve
        workspace.refreshingDiff = canPreserve
        workspace.diffError = nil
        let work = Task {
            do {
                let result = try await session.service.readDiff(
                    path: path, layer: layer, options: options,
                    loadLarge: loadLarge || canPreserve && previousDisk != nil)
                guard diffRequestID == request, self.session === session, workspace.selectedFile == selection,
                    workspace.diffOptions == options, session.diffGeneration == generation, !Task.isCancelled
                else { return }
                switch result {
                case .disk(let snapshot):
                    if canPreserve, let previousDisk,
                        previousDisk.snapshot.digest == snapshot.digest,
                        previousDisk.snapshot.byteCount == snapshot.byteCount,
                        previousDisk.snapshot.head == snapshot.head
                    {
                        return
                    }
                    clearDiffDisplay()
                    workspace.diffBranch = session.status.branch
                    workspace.diffSummary = nil
                    workspace.diffLimit = nil
                    let display = DiskDiffDisplayState(
                        snapshot: snapshot, service: session.service, renderID: request)
                    workspace.diskDisplay = display
                    workspace.loadingDiff = false
                    await display.prepare(split: workspace.splitDiff)
                case .loaded(let diff):
                    if canPreserve, let previous, previous.diff.raw == diff.raw,
                        previous.diff.head == diff.head, previous.diff.indexTree == diff.indexTree
                    {
                        return
                    }
                    clearDiffDisplay()
                    workspace.diffBranch = session.status.branch
                    workspace.diffSummary = nil
                    workspace.diffLimit = nil
                    workspace.diff = diff
                    let display = DiffDisplayState(diff: diff, service: session.service, renderID: request)
                    workspace.diffDisplay = display
                    workspace.loadingDiff = false
                    await display.prepare(split: workspace.splitDiff)
                case .deferred(let summary, let limit):
                    clearDiffDisplay()
                    workspace.diffSummary = summary
                    workspace.diffLimit = limit
                }
            } catch {
                guard diffRequestID == request, self.session === session, workspace.selectedFile == selection,
                    workspace.diffOptions == options, session.diffGeneration == generation
                else { return }
                if Task.isCancelled || error is CancellationError {
                    workspace.diffCancelled = true
                } else {
                    workspace.diffError = error.localizedDescription
                }
            }
        }
        diffReadTask = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func cancelDiffRead() {
        diffRequestID = UUID()
        diffReadTask?.cancel()
        diffReadTask = nil
        workspace.loadingDiff = false
        workspace.refreshingDiff = false
        workspace.diffCancelled = workspace.diffDisplay == nil && workspace.diskDisplay == nil
        if !workspace.diffCancelled { workspace.diffReadNotice = L10n.text("已取消核对，仍显示此前读取的差异。写操作会重新校验内容。") }
    }

    private func clearDiffDisplay() {
        workspace.diffDisplay?.cancelAll()
        workspace.diskDisplay?.cancelAll()
        workspace.diff = nil
        workspace.diffDisplay = nil
        workspace.diskDisplay = nil
        workspace.diffBranch = nil
    }

    func confirm(title: String, message: String, action: String = L10n.text("继续"), destructive: Bool = true)
        -> Bool
    {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        AppPresentation.configure(
            alert, appearance: AppPresentation.appearance(for: preferences.resolvedAppearance))
        alert.addButton(withTitle: L10n.text("取消"))
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }

    func presentWorktreeManagement(_ session: RepositorySession) {
        guard self.session === session, worktreeManagementRequest == nil else { return }
        worktreeFocusRestoration = WorktreeFocusRestoration(sessionID: session.id)
        worktreeManagementRequest = WorktreeManagementRequest(session: session)
    }

    func discardWorktreeManagementFocus() { worktreeFocusRestoration = nil }

    func restoreWorktreeManagementFocus() {
        guard worktreeManagementRequest == nil else { return }
        let saved = worktreeFocusRestoration
        worktreeFocusRestoration = nil
        guard !isOpening else { return }
        saved?.restore(sessionID: session?.id)
    }

    var nativeFrameStorageKey: String { "v2.window-frame:" + windowID.uuidString }
    var nativeWindowStateName: String {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if Self.isUITesting, let index = arguments.firstIndex(of: "--uitesting-window-state"),
                index + 1 < arguments.count, let id = UUID(uuidString: arguments[index + 1])
            {
                return "WeGit.UITests." + id.uuidString
                    + (windowID == runtime.primaryWindowID ? "" : "." + windowID.uuidString)
            }
        #endif
        if let migrationState { return migrationState.nativeWindowStateName(windowID) }
        return windowID == runtime.primaryWindowID ? "WeGit.main" : "WeGit.window." + windowID.uuidString
    }
    var nativeSplitStatePrefix: String {
        Self.isUITesting ? nativeWindowStateName + ".columns" : nativeWindowStateName + ".columns"
    }
    var savesWindowState: Bool {
        preferences.restoreWindow && (!Self.isUITesting || nativeWindowStateName.hasPrefix("WeGit.UITests."))
    }

    func applyDefaultDiffPreferences() {
        workspace.splitDiff = preferences.splitDiff
        workspace.wordDiff = preferences.wordDiff
        workspace.diffOptions.contextLines = preferences.contextLines
        workspace.diffOptions.ignoreWhitespace = preferences.ignoreWhitespace
    }

    @discardableResult func saveCurrentWorkspace(open: Bool? = nil, forceForUpdate: Bool = false) -> Bool {
        guard !isMigrationBlocked else { return true }
        if runtime.updateHandoffInProgress { return true }
        guard initialRestoreCompleted, session != nil || !isOpening,
            preferences.restoreWindow || forceForUpdate
        else {
            return true
        }
        guard let persistence = runtime.persistence else {
            workspaceSaveError = runtime.persistenceError ?? L10n.text("窗口设置无法保存，原始数据已保留。")
            error = workspaceSaveError
            return false
        }
        let history = session.map { historyState(for: $0) }
        let reading = history.map {
            WindowHistoryReading(
                scope: $0.scope.rawValue, query: $0.query, field: $0.searchField.rawValue,
                selected: Array(pendingHistorySelectionIDs ?? $0.selectedIDs).sorted())
        }
        do {
            let snapshot = WindowReadingSnapshot(
                id: windowID, repository: session?.location.root.path,
                workspaceID: session?.location.persistenceID,
                view: try JSONEncoder().encode(workspace.savedView),
                history: try reading.map { try JSONEncoder().encode($0) },
                selectedCommit: workspace.selectedCommit?.id ?? pendingSelectedCommitID,
                open: open ?? mainWorkspaceMounted)
            guard runtime.persistenceGeneration < UInt64.max else {
                throw WindowSessionPersistence.Failure.exceeded
            }
            if let window = nativeWindow, !runtime.updateHandoffInProgress {
                defaults.set(NSStringFromRect(window.frame), forKey: nativeFrameStorageKey)
            }
            try persistence.save(snapshot, active: runtime.activeWindowID == windowID)
            if let id = snapshot.workspaceID {
                defaults.set(try JSONEncoder().encode(snapshot), forKey: workspaceReadingKey(id))
            }
            workspaceSaveError = nil
            runtime.persistenceGeneration += 1
            return true
        } catch {
            workspaceSaveError = error.localizedDescription
            self.error = error.localizedDescription
            return false
        }
    }

    private func restoreWorkspace(for location: RepositoryLocation) {
        cancelPendingHistoryRestore()
        workspace = WorkspaceState()
        applyDefaultDiffPreferences()
        let windowSnapshot = runtime.persistence?.snapshot(windowID).flatMap {
            $0.workspaceID == location.persistenceID ? $0 : nil
        }
        let readingSnapshot = workspaceSnapshot(location.persistenceID) ?? windowSnapshot
        guard preferences.restoreWindow,
            let data = readingSnapshot?.view
                ?? defaults.data(forKey: "workspace:" + location.persistenceID),
            let saved = try? JSONDecoder().decode(RepositoryViewPreferences.self, from: data)
        else { return }
        workspace.route = WorkspaceRoute(rawValue: saved.route) ?? .changes
        workspace.selectedFile = saved.selectedFile
        workspace.inspector = saved.inspector
        workspace.filter = saved.filter
        workspace.changeFilter = ChangeKindFilter(rawValue: saved.changeFilter ?? "") ?? .all
        workspace.changesByFolder = saved.changesByFolder ?? false
        workspace.branchFilter = saved.branchFilter
        workspace.splitDiff = saved.splitDiff
        workspace.wordDiff = saved.wordDiff
        workspace.diffOptions.contextLines =
            [3, 20, 80, 200].contains(saved.contextLines) ? saved.contextLines : 3
        workspace.diffOptions.ignoreWhitespace = saved.ignoreWhitespace
        if let session,
            let data = readingSnapshot?.history,
            let reading = try? JSONDecoder().decode(WindowHistoryReading.self, from: data),
            reading.query.utf8.count <= 4096, reading.selected.count <= 100
        {
            let history = historyState(for: session)
            history.scope = HistoryScope(rawValue: reading.scope) ?? .all
            history.query = reading.query
            history.searchField = HistorySearchField(rawValue: reading.field) ?? .message
            pendingHistorySelectionIDs = Set(
                reading.selected.filter {
                    [40, 64].contains($0.utf8.count)
                        && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                })
        }
        pendingSelectedCommitID = readingSnapshot?.selectedCommit
    }

    func cancelPendingHistoryRestore() {
        historyRestoreID = UUID()
        pendingSelectedCommitID = nil
        pendingHistorySelectionIDs = nil
    }

    /// Persist an explicit table selection at the same boundary as its model
    /// mutation; selecting a commit does not change workspace.savedView.
    func applyHistorySelection(_ ids: Set<String>, for session: RepositorySession) {
        guard self.session === session else { return }
        let history = historyState(for: session)
        let current =
            !history.selectedIDs.isEmpty
            ? history.selectedIDs : Set(workspace.selectedCommit.map { [$0.id] } ?? [])
        guard ids != current else { return }
        cancelPendingHistoryRestore()
        history.selectedIDs = ids
        if workspace.selectedCommit.map({ ids.contains($0.id) }) != true {
            workspace.selectedCommit = history.commits.first { ids.contains($0.id) }
        }
        saveCurrentWorkspace()
    }

    func restoreSelectedCommit(for session: RepositorySession) async {
        guard self.session === session else { return }
        let token = historyRestoreID
        let targetWorkspace = workspace
        let history = historyState(for: session)
        let selection = pendingHistorySelectionIDs
        guard let oid = pendingSelectedCommitID else {
            if let selection {
                history.selectedIDs = selection
                pendingHistorySelectionIDs = nil
            }
            return
        }
        do {
            let commit: GitCommit
            if let loaded = history.commits.first(where: { $0.id == oid }) {
                commit = loaded
            } else {
                commit = try await session.service.readCommit(oid)
            }
            try Task.checkCancellation()
            guard self.session === session, workspace === targetWorkspace, historyRestoreID == token,
                pendingSelectedCommitID == oid, workspace.selectedCommit == nil
            else { return }
            workspace.selectedCommit = commit
            if let selection { history.selectedIDs = selection }
            pendingSelectedCommitID = nil
            pendingHistorySelectionIDs = nil
        } catch {
            if !Task.isCancelled, self.session === session, historyRestoreID == token {
                self.error = L10n.text("无法恢复所选提交：\(error.localizedDescription)")
            }
        }
    }

    func historyState(for session: RepositorySession) -> HistoryState {
        if session.historyOwner == nil { session.historyOwner = windowID }
        if session.historyOwner == windowID { return session.historyState }
        if let existing = histories[session.id] { return existing }
        let state = HistoryState(service: session.service)
        histories[session.id] = state
        return state
    }

    private func workspaceReadingKey(_ id: String) -> String {
        "v2.workspace-view:" + windowID.uuidString + ":" + id
    }
    private func workspaceSnapshot(_ id: String) -> WindowReadingSnapshot? {
        guard let bytes = defaults.data(forKey: workspaceReadingKey(id)), bytes.count <= 160 * 1024,
            let saved = try? JSONDecoder().decode(WindowReadingSnapshot.self, from: bytes),
            saved.id == windowID, saved.workspaceID == id
        else { return nil }
        return saved
    }

    func prepareWindowClose() -> Bool {
        guard !runtime.updateHandoffInProgress else { return false }
        guard !cloneRunning, !initialization.isBusy, session?.draftSaveError == nil else { return false }
        guard saveCurrentWorkspace(open: false) else { return false }
        do {
            // Closing during initial restoration must preserve the saved route,
            // while still marking the existing window record as closed.
            if runtime.persistence?.snapshot(windowID)?.open == true {
                try runtime.persistence?.setClosed(windowID)
            }
            try runtime.persistence?.flush()
            workspaceSaveError = nil
            return true
        } catch {
            workspaceSaveError = error.localizedDescription
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult func windowDidClose() -> Bool {
        let saved = prepareWindowClose()
        mainWorkspaceMounted = false
        if saved {
            themeImportRequest = nil
            workspaceSheetDidDismiss()
        }
        session?.deactivate(owner: windowID)
        cancelDiffRead()
        if let session { historyState(for: session).releaseCache() }
        trimSessionCache()
        return saved
    }

    func resetInterface() {
        preferences.resetInterface()
        workspace.inspector = false
        workspace.filter = ""
        workspace.changeFilter = .all
        workspace.changesByFolder = false
        workspace.collapsedChangeGroups = []
        workspace.collapsedChangeFolders = []
        workspace.branchFilter = ""
        workspace.route = .changes
        if !Self.isUITesting {
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame WeGit.main")
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("NSSplitView Subview Frames WeGit.columns.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
