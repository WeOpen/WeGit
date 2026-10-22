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
    var id: String { rawValue }
    var title: String { L10n.key(rawValue) }
    var icon: String {
        switch self {
        case .changes: "square.and.pencil"
        case .history: "clock.arrow.circlepath"
        case .branches: "arrow.triangle.branch"
        case .stashes: "archivebox"
        }
    }
}

@Observable @MainActor
final class WorkspaceState {
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
    var activityLabel = ""
    var error: String?
    var details = ""
    var notice: String?
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
    var message: String { didSet { if preferences.saveDrafts { defaults.set(message, forKey: draftKey) } } }
    var amend = false
    private var refreshID = UUID()
    private var watcher: RepositoryWatcher?
    private var debounce: Task<Void, Never>?
    private var pendingRefresh: RepositoryRefreshScope = .all
    private var refreshTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let preferences: AppPreferences
    private var draftKey: String { "draft-v2:" + service.location.persistenceID }

    init(service: RepositoryService, defaults: UserDefaults, preferences: AppPreferences) {
        self.service = service
        historyState = HistoryState(service: service)
        self.defaults = defaults
        self.preferences = preferences
        message =
            preferences.saveDrafts
            ? defaults.string(forKey: "draft-v2:" + service.location.persistenceID) ?? "" : ""
        legacyDraft = defaults.string(forKey: "draft:" + service.location.id).flatMap {
            $0.isEmpty ? nil : $0
        }
        pendingPush = defaults.data(forKey: "pending-push:" + service.location.persistenceID)
            .flatMap { try? JSONDecoder().decode(PendingPushRecord.self, from: $0) }
    }
    var location: RepositoryLocation { service.location }
    var canWrite: Bool { hasLoaded && !isStale && !isBusy && !preferences.configurationWriteInProgress }
    var writeReason: String {
        if preferences.configurationWriteInProgress { return L10n.text("正在保存 Git 配置") }
        if isBusy { return L10n.text("正在执行 \(activityLabel)") }
        if isStale { return L10n.text("仓库状态已过期，请先刷新") }
        if !hasLoaded { return L10n.text("请先读取仓库状态") }
        return ""
    }
    var canCommit: Bool {
        canWrite && status.conflicts.isEmpty && status.sequencer == .none
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (amend ? status.head != nil : status.files.contains(where: \.staged))
    }
    var canSync: Bool {
        canWrite && status.head != nil && !status.isDetached
            && status.sequencer == .none && status.conflicts.isEmpty && !remotes.isEmpty
    }
    var canCommitAndPush: Bool {
        canCommit && !status.isDetached && !remotes.isEmpty && pendingPush?.verification == nil
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
        if status.sequencer != .none { return L10n.text("请先完成当前 Git 操作") }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10n.text("填写提交消息") }
        return L10n.text("选择需要提交的内容并暂存")
    }

    func activate() {
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

    func deactivate() {
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
            return nil
        }
    }

    func performResult(
        _ name: String, onSuccess: (@MainActor () -> Void)? = nil,
        operation: @escaping @Sendable (RepositoryService) async throws -> String?
    ) {
        guard !isBusy else { return }
        guard canWrite else {
            error = L10n.text("仓库状态已过期，请刷新后再操作。")
            return
        }
        suspendRefresh()
        isBusy = true
        activityLabel = name
        error = nil
        notice = nil
        let pinned = service.expectingBranch(status.branch)
        operationTask = Task {
            var succeeded = false
            do {
                notice = try await operation(pinned) ?? L10n.text("\(name)完成")
                succeeded = true
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
        let amend = amend
        let head = status.head
        let pinned = service.expectingBranch(status.branch)
        suspendRefresh()
        isBusy = true
        activityLabel = L10n.text("提交")
        error = nil
        operationTask = Task {
            do {
                _ = try await pinned.commit(message: text, amend: amend, expectedHead: head)
                completeCommit(message: text)
                notice = L10n.text("提交完成")
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
    func completeCommit(message text: String) {
        if message == text { message = "" }
        if defaults.string(forKey: draftKey) == text { defaults.removeObject(forKey: draftKey) }
        amend = false
    }
    func show(_ error: any Error) {
        self.error = error.localizedDescription
        details =
            (error as? GitFailure)?.details ?? (error as? PullFailure)?.details
            ?? (error as? CommitOutcomeUnknown)?.details ?? (error as? PushOutcomeUnknown)?.details ?? ""
        if let path = (error as? UntrackedTrashFailure)?.trashURL, path.isFileURL { lastTrashedFile = path }
    }
}

@Observable @MainActor
final class AppState {
    var workspace = WorkspaceState()
    let defaults: UserDefaults
    let preferences: AppPreferences
    private(set) var engine: GitEngine
    let authentication: AuthenticationController
    var session: RepositorySession?
    var sessions: [String: RepositorySession] = [:]
    var recents: [RecentRepository] = []
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
    var activityPresented = false
    var palettePresented = false
    var pendingPaletteCommand: WorkspaceCommand?
    var pendingPaletteSession: RepositorySession?
    var pendingPaletteBranch: String?
    var branchPresented = false
    var remoteManagementPresented = false
    var branchSwitchRequest: BranchSwitchRequest?
    var syncRequest: SyncRequest?
    var searchRequest: RepositorySearchRequest?
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

    private static var isUITesting: Bool {
        #if DEBUG || WEGIT_PERFORMANCE
            ProcessInfo.processInfo.arguments.contains("--uitesting")
        #else
            false
        #endif
    }

    init() {
        let testing = Self.isUITesting
        if !testing { PreferenceMigration.migrateStandardPreferences() }
        defaults = testing ? UserDefaults(suiteName: "com.willxue.wegit.UITests")! : .standard
        #if DEBUG
            let preserveTestPreferences =
                testing && ProcessInfo.processInfo.arguments.contains("--uitesting-keep-preferences")
        #else
            let preserveTestPreferences = false
        #endif
        if testing && !preserveTestPreferences {
            defaults.removePersistentDomain(forName: "com.willxue.wegit.UITests")
        }
        preferences = AppPreferences(defaults: defaults)
        let authentication = AuthenticationController()
        authentication.presentationPreferences = preferences
        self.authentication = authentication
        let bridge = AskPassBridge(
            helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/WeGitAskPass")
        ) {
            try await authentication.respond(to: $0)
        }
        let git = GitEngine(
            executable: URL(fileURLWithPath: defaults.string(forKey: "gitExecutable") ?? "/usr/bin/git"),
            activity: ActivityStore(
                limit: preferences.activityLimit, retention: Double(preferences.activityHours) * 3600),
            authentication: bridge)
        engine = git
        let cloneModel = CloneViewModel(coordinator: CloneCoordinator(engine: git))
        cloneModel.parentPath = preferences.defaultDirectory
        clone = cloneModel
        do {
            let configuration: ModelConfiguration
            if testing {
                configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            } else {
                let directory = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appending(path: "WeGit", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                configuration = ModelConfiguration(
                    url: directory.appending(path: "Repositories.store"), cloudKitDatabase: .none)
            }
            container = try ModelContainer(for: RecentRepository.self, configurations: configuration)
        } catch {
            container = nil
            self.error = L10n.text("无法读取最近仓库记录：\(error.localizedDescription)")
        }
        reloadRecents()
        applyDefaultDiffPreferences()
        preferences.onDiffChange = { [weak self] in self?.applyDefaultDiffPreferences() }
        preferences.onActivityChange = { [weak self] in
            guard let self else { return }
            let limit = preferences.activityLimit
            let retention = Double(preferences.activityHours) * 3600
            Task { await self.engine.activity.configure(limit: limit, retention: retention) }
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L10n.text("打开仓库")
        panel.message = L10n.text("选择本地 Git 仓库文件夹")
        panel.directoryURL = URL(fileURLWithPath: preferences.defaultDirectory)
        if panel.runModal() == .OK, let url = panel.url { Task { await open(url) } }
    }

    func open(_ url: URL) async {
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
                        queue: matching?.service.queue ?? RepositoryOperationQueue()),
                    defaults: defaults, preferences: preferences)
                if let matching, matching.location.id != location.id {
                    if value.message.isEmpty { value.message = matching.message }
                    sessions.removeValue(forKey: matching.location.id)
                }
            }
            saveCurrentWorkspace()
            if session !== value { session?.deactivate() }
            sessions[location.id] = value
            session = value
            value.onIdle = { [weak self] in self?.trimSessionCache() }
            value.activate()
            diffRequestID = UUID()
            diffReadTask?.cancel()
            diffReadTask = nil
            workspace.loadingDiff = false
            workspace.diffDisplay?.cancelAll()
            workspace.diskDisplay?.cancelAll()
            restoreWorkspace(for: location)
            workspace.shellRenderID = request
            defaults.set(location.root.path, forKey: "lastRepository")
            if let context = container?.mainContext {
                if let record = recents.first(where: { $0.path == location.root.path }) {
                    record.openedAt = Date()
                } else {
                    context.insert(RecentRepository(path: location.root.path, name: location.name))
                }
                try context.save()
                reloadRecents()
            }
            await value.refresh()
            trimSessionCache()
        } catch { self.error = error.localizedDescription }
    }

    private func trimSessionCache() {
        let removable = sessions.values.filter { $0 !== session && !$0.isBusy }
            .sorted { $0.lastUsed < $1.lastUsed }
        for cached in removable where sessions.count > 8 {
            cached.deactivate()
            sessions.removeValue(forKey: cached.location.id)
        }
    }

    func closeRepository() {
        guard let session else { return }
        guard !session.isBusy, !preferences.configurationWriteInProgress else {
            session.error = L10n.text("Git 操作或配置保存仍在进行，请等待完成或取消操作后再关闭仓库。")
            return
        }
        saveCurrentWorkspace()
        session.deactivate()
        cancelDiffRead()
        workspace.diffDisplay?.cancelAll()
        workspace.diskDisplay?.cancelAll()
        workspace = WorkspaceState()
        self.session = nil
        defaults.removeObject(forKey: "lastRepository")
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
                    return L10n.text("回收夹具已核对并恢复")
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
        if initialRestoreCompleted {
            session?.activate()
            if let session, !session.isBusy, !preferences.configurationWriteInProgress {
                await session.refresh()
            }
            return
        }
        do { try await DiffSnapshotStorage.removeAbandoned() } catch {
            self.error = error.localizedDescription
        }
        do {
            let preferred = defaults.string(forKey: "gitExecutable").map { URL(fileURLWithPath: $0) }
            let installation = try await GitInstallation.detect(preferred: preferred)
            gitVersion = installation.version
            if installation.executable != engine.executable, sessions.isEmpty, !clone.isBusy {
                engine = GitEngine(
                    executable: installation.executable, activity: engine.activity,
                    authentication: engine.authentication, environment: engine.environment)
                clone = CloneViewModel(coordinator: CloneCoordinator(engine: engine))
                clone.parentPath = preferences.defaultDirectory
            }
        } catch {
            self.error = error.localizedDescription
            gitVersion = L10n.text("不可用")
            return
        }
        initialRestoreCompleted = true
        #if DEBUG || WEGIT_PERFORMANCE
            if Self.isUITesting, let path = ProcessInfo.processInfo.environment["WEGIT_UI_TEST_REPOSITORY"] {
                await open(URL(fileURLWithPath: path))
                return
            }
        #endif
        if !Self.isUITesting, preferences.restoreRepository,
            let path = defaults.string(forKey: "lastRepository")
        {
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

    var nativeWindowStateName: String {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if Self.isUITesting, let index = arguments.firstIndex(of: "--uitesting-window-state"),
                index + 1 < arguments.count, let id = UUID(uuidString: arguments[index + 1])
            {
                return "WeGit.UITests." + id.uuidString
            }
        #endif
        return "WeGit.main"
    }
    var nativeSplitStatePrefix: String {
        Self.isUITesting ? nativeWindowStateName + ".columns" : "WeGit.columns"
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

    func saveCurrentWorkspace() {
        guard let session, let bytes = try? JSONEncoder().encode(workspace.savedView) else { return }
        defaults.set(bytes, forKey: "workspace:" + session.location.persistenceID)
    }

    private func restoreWorkspace(for location: RepositoryLocation) {
        workspace = WorkspaceState()
        applyDefaultDiffPreferences()
        guard preferences.restoreWindow,
            let data = defaults.data(forKey: "workspace:" + location.persistenceID),
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
