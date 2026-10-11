import AppKit
import SwiftUI
import WeGitCore

struct WorkspaceView: View {
    @Bindable var app: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    var body: some View {
        Group {
            if let session = app.session {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar(session)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 270)
                } detail: {
                    GeometryReader { geometry in
                        // Resolve the detail area's safe bounds once. Nested AppKit
                        // split panes must not each add the sidebar inset to their
                        // minimum width and push the workspace outside its window.
                        VStack(spacing: 0) {
                            statusBanner(session)
                            switch app.workspace.route {
                            case .changes: ChangesView(app: app, session: session)
                            case .history: HistoryView(app: app, session: session)
                            case .branches: BranchesView(app: app, session: session)
                            }
                        }
                        .padding(geometry.safeAreaInsets)
                        .frame(
                            width: geometry.size.width + geometry.safeAreaInsets.leading
                                + geometry.safeAreaInsets.trailing,
                            height: geometry.size.height + geometry.safeAreaInsets.top
                                + geometry.safeAreaInsets.bottom
                        )
                        .ignoresSafeArea()
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .inspector(isPresented: $app.workspace.inspector) {
                        inspector(session).inspectorColumnWidth(min: 240, ideal: 260, max: 320)
                    }
                }
                .background(
                    ViewPerformanceProbe(spans: [
                        ViewPerformanceSpan(name: "shell", id: app.workspace.shellRenderID)
                    ])
                )
                .navigationTitle(session.location.name)
                .navigationSubtitle(session.status.displayBranch)
            } else {
                WelcomeView(app: app)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("WeGit 工作区")
        .background(WindowStateBridge(app: app).frame(width: 0, height: 0).accessibilityHidden(true))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    app.repositoryPickerPresented = true
                } label: {
                    Label(app.session?.location.name ?? "打开仓库", systemImage: "folder.badge.gearshape")
                }
                .help("切换仓库 ⌘K")
            }
            if let session = app.session {
                ToolbarItem { branchMenu(session) }
                ToolbarItemGroup {
                    Menu {
                        ForEach(session.remotes, id: \.self) { remote in
                            Button("获取 \(remote)") {
                                session.perform("获取") { try await $0.fetch(remote: remote) }
                            }
                        }
                    } label: {
                        Label("获取", systemImage: "arrow.clockwise")
                    }
                    .disabled(session.isBusy || session.remotes.isEmpty)
                    .help(session.remotes.isEmpty ? "尚未配置 Remote" : "选择要获取的远端")
                    Button {
                        app.presentSync(.pull)
                    } label: {
                        Label("拉取", systemImage: "arrow.down")
                    }
                    .help(session.syncReason).disabled(!session.canSync).accessibilityIdentifier(
                        "toolbar-pull")
                    Button {
                        app.presentSync(.push)
                    } label: {
                        Label("推送", systemImage: "arrow.up")
                    }
                    .help(session.syncReason).disabled(!session.canSync).accessibilityIdentifier(
                        "toolbar-push")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if session.isBusy {
                        ProgressView().controlSize(.small).help(session.activityLabel)
                        Button("取消", systemImage: "stop.circle") { session.cancel() }
                    }
                    Button("刷新", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                        Task { await session.refresh() }
                    }.help("刷新 ⌘R")
                    Button("活动记录", systemImage: "clock") { app.activityPresented = true }
                    Button("搜索仓库", systemImage: "magnifyingglass", action: app.presentSearch).help(
                        "搜索当前仓库 ⌘⇧F")
                    Button("检查器", systemImage: "sidebar.right") { app.workspace.inspector.toggle() }
                }
            }
        }
        .sheet(isPresented: $app.clonePresented) { CloneView(app: app) }
        .sheet(isPresented: $app.branchPresented) { NewBranchView(app: app) }
        .sheet(item: $app.branchSwitchRequest) { BranchSwitcherView(app: app, request: $0) }
        .sheet(isPresented: $app.activityPresented) { ActivityView(app: app) }
        .sheet(isPresented: $app.repositoryPickerPresented, onDismiss: app.repositoryPickerDidDismiss) {
            RepositoryPicker(app: app)
        }
        .sheet(isPresented: $app.palettePresented, onDismiss: app.paletteDidDismiss) {
            CommandPalette(app: app)
        }
        .sheet(item: $app.syncRequest) { SyncSheet(app: app, request: $0) }
        .sheet(item: $app.searchRequest) { RepositorySearchView(app: app, request: $0) }
        .onChange(of: app.settingsRequestID) { _, _ in openSettings() }
        .onChange(of: app.workspace.savedView) { _, _ in app.saveCurrentWorkspace() }
        .onDisappear {
            app.saveCurrentWorkspace()
            app.session?.deactivate()
        }
        .alert("操作未完成", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } }))
        {
            Button("好", role: .cancel) { app.error = nil }
        } message: {
            Text(app.error ?? "")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in await app.open(url) } }
            }
            return true
        }
    }

    private func sidebar(_ session: RepositorySession) -> some View {
        List(selection: $app.workspace.route) {
            Section("工作区") {
                ForEach(WorkspaceRoute.allCases) { route in
                    HStack {
                        Label(route.rawValue, systemImage: route.icon)
                        Spacer()
                        if route == .changes {
                            Text("\(session.status.files.count)").font(.caption.monospacedDigit())
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }.tag(route).accessibilityIdentifier("route-\(route.id)")
                }
            }
            Section("仓库") {
                ForEach(app.recents.sorted { $0.pinned && !$1.pinned }) { record in
                    Button {
                        Task { await app.open(URL(fileURLWithPath: record.path)) }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.name).lineLimit(1)
                                if record.path == session.location.root.path {
                                    Text(session.status.displayBranch).font(.caption2).foregroundStyle(
                                        AppColors.secondaryText)
                                }
                            }
                            if record.pinned {
                                Spacer()
                                Image(systemName: "pin.fill").font(.caption2)
                            }
                        }.padding(.vertical, app.preferences.density == "compact" ? 1 : 4)
                    }.buttonStyle(.plain)
                        .contextMenu {
                            RepositoryContextMenu(app: app, record: record)
                        }
                }
            }
        }.listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("打开仓库", systemImage: "plus", action: app.openPanel).labelStyle(.iconOnly)
                    Spacer()
                    Text("WeGit").font(.caption).foregroundStyle(AppColors.secondaryText)
                }.padding(12)
            }
    }

    @ViewBuilder private func statusBanner(_ session: RepositorySession) -> some View {
        if let error = session.refreshError {
            HStack {
                Label(
                    "仓库状态未更新：\(error)",
                    systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                Spacer()
                Button("重试刷新") { Task { await session.refresh() } }.disabled(session.isRefreshing)
                Button("重新打开") { Task { await app.open(session.location.root) } }.disabled(session.isBusy)
            }.font(.callout).padding(12).background(.orange.opacity(0.1))
        }
        if let warning = session.observationWarning {
            Text("\(warning) 当前使用手动刷新。").font(.caption).foregroundStyle(AppColors.secondaryText).padding(10)
        }
        if let commit = session.pendingPushCommit, !session.isBusy {
            HStack {
                let uncertain = session.pendingPush?.verification != nil
                Label(
                    uncertain
                        ? "提交 \(commit.prefix(12)) 的远端结果待核对"
                        : "本地提交 \(commit.prefix(12)) 已完成，推送待完成",
                    systemImage: uncertain ? "exclamationmark.triangle" : "checkmark.circle")
                Spacer()
                Button(uncertain ? "核对远端结果…" : "继续推送…") { app.presentSync(.push) }
                    .disabled(!session.canSync && !session.canVerifyPendingPush)
                    .accessibilityIdentifier("pending-push-action")
                Button("标记已处理") {
                    if !uncertain
                        || app.confirm(
                            title: "已手动核对推送目标？",
                            message: "此前推送没有完整结果。确认已自行核对原目标后，可关闭此提示。",
                            action: "标记已处理", destructive: false)
                    {
                        session.pendingPush = nil
                    }
                }.help("只关闭这条恢复提示，不修改 Git 数据")
            }.font(.callout).padding(12).background(.blue.opacity(0.08))
        }
        if let error = session.error {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("关闭") { session.error = nil }
                }
                if !session.details.isEmpty {
                    DisclosureGroup("查看详情") {
                        ScrollView {
                            Text(session.details).font(.caption.monospaced()).textSelection(.enabled).frame(
                                maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 140)
                    }
                }
            }.font(.callout).padding(12).background(.red.opacity(0.08))
        }
        if session.status.sequencer != .none {
            HStack {
                Label(
                    "正在\(session.status.sequencer.title) · \(session.status.conflicts.count) 个冲突",
                    systemImage: "arrow.triangle.merge")
                Spacer()
                if [.merge, .rebase].contains(session.status.sequencer) {
                    Button("中止…") {
                        let expected = session.status.sequencer
                        if app.confirm(
                            title: "中止 \(expected.rawValue)？", message: "将撤回本次操作，操作中的手工编辑可能无法恢复。",
                            action: "中止")
                        {
                            session.perform("中止") {
                                try await $0.sequencer(continueOperation: false, expected: expected)
                            }
                        }
                    }.disabled(!session.canWrite).accessibilityIdentifier("sequencer-abort")
                    Button("继续") {
                        let expected = session.status.sequencer
                        session.perform("继续") {
                            try await $0.sequencer(continueOperation: true, expected: expected)
                        }
                    }
                    .disabled(!session.status.conflicts.isEmpty || !session.canWrite)
                    .accessibilityIdentifier("sequencer-continue")
                } else {
                    Text("请在 Terminal 完成当前操作").foregroundStyle(AppColors.secondaryText)
                }
            }.font(.callout).padding(12).background(.orange.opacity(0.10))
        }
    }

    private func branchMenu(_ session: RepositorySession) -> some View {
        Menu {
            Button("查找并切换分支…", action: app.presentBranchSwitcher)
            Divider()
            ForEach(Array(session.branches.filter { !$0.remote }.prefix(20))) { branch in
                Button(branch.current ? "✓ \(branch.name)" : branch.name) {
                    app.switchBranch(branch, in: session)
                }.disabled(app.branchSwitchReason(branch, in: session) != nil)
                    .help(app.branchSwitchReason(branch, in: session) ?? "切换到这个分支")
            }
            Divider()
            Button("新建分支…") { app.branchPresented = true }
        } label: {
            Label(session.status.displayBranch, systemImage: "arrow.triangle.branch")
        }
        .disabled(!session.canWrite)
        .accessibilityIdentifier("current-branch")
        .accessibilityLabel((session.status.isDetached ? "当前提交：" : "当前分支：") + session.status.displayBranch)
    }

    private func inspector(_ session: RepositorySession) -> some View {
        Form {
            Section("仓库") {
                LabeledContent("名称", value: session.location.name)
                Text(session.location.root.path).font(.caption).textSelection(.enabled)
                Button("在 Finder 中显示") { NSWorkspace.shared.open(session.location.root) }
                Button("在 Terminal 中打开", action: app.openTerminal)
                if app.xcodeURL != nil { Button("在 Xcode 中打开…", action: app.openRepositoryInXcode) }
                Button("复制仓库路径", action: app.copyRepositoryPath)
            }
            Section("分支") {
                LabeledContent("当前", value: session.status.displayBranch)
                LabeledContent("上游", value: session.status.upstream ?? "未设置")
                LabeledContent(
                    "领先 / 落后",
                    value:
                        "\(session.status.ahead.map(String.init) ?? "—") / \(session.status.behind.map(String.init) ?? "—")"
                )
            }
            if let diff = app.workspace.diff {
                Section("文件") {
                    Text(diff.path).textSelection(.enabled)
                    LabeledContent("新增", value: "\(diff.additions)")
                    LabeledContent("删除", value: "\(diff.deletions)")
                }
            }
        }.formStyle(.grouped)
    }
}

struct WelcomeView: View {
    @Bindable var app: AppState
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "arrow.triangle.branch").font(.system(size: 62, weight: .light))
                .foregroundStyle(.blue)
            VStack(spacing: 8) {
                Text("WeGit").font(.system(size: 40, weight: .semibold))
                Text("专注每一次改动。").font(.title3).foregroundStyle(AppColors.secondaryText)
            }
            HStack(spacing: 12) {
                Button("打开仓库…", systemImage: "folder", action: app.openPanel).buttonStyle(.borderedProminent)
                    .controlSize(.large).accessibilityIdentifier("open-repository")
                Button("克隆仓库…", systemImage: "arrow.down.to.line", action: app.presentClone).controlSize(
                    .large)
            }
            if app.isOpening { ProgressView("正在打开仓库…") }
            if !app.recents.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("最近打开").font(.caption).foregroundStyle(AppColors.secondaryText)
                    ForEach(app.recents.prefix(5)) { record in
                        Button {
                            Task { await app.open(URL(fileURLWithPath: record.path)) }
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(record.name)
                                Spacer()
                                Text(record.path).foregroundStyle(AppColors.secondaryText).lineLimit(1)
                                    .truncationMode(
                                        .middle)
                            }
                        }.buttonStyle(.plain).padding(.vertical, 5)
                            .contextMenu { RepositoryContextMenu(app: app, record: record) }
                    }
                }.frame(width: 520).padding(20).background(
                    .quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
            }
            Spacer()
            Text("SwiftUI 原生工作区 · Git CLI 驱动").font(.caption).foregroundStyle(.tertiary).padding(.bottom, 28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
