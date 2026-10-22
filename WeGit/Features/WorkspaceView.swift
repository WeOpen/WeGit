import AppKit
import SwiftUI
import WeGitCore

struct WorkspaceView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private var workspaceWidth: CGFloat { app.windowContentWidth }
    var body: some View {
        Group {
            if let session = app.session {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar(session)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 270)
                } detail: {
                    // A native auxiliary split avoids SwiftUI Inspector's constraint-update
                    // cycle when restored beside a nested HSplitView on macOS 27.
                    HSplitView {
                        GeometryReader { column in
                            GeometryReader { geometry in
                                let leadingInset = max(
                                    0, column.frame(in: .global).minX - geometry.frame(in: .global).minX)
                                VStack(spacing: 0) {
                                    statusBanner(session).padding(.leading, leadingInset)
                                    switch app.workspace.route {
                                    case .changes:
                                        ChangesView(
                                            app: app, session: session,
                                            leadingInset: leadingInset)
                                    case .history: HistoryView(app: app, session: session)
                                    case .branches: BranchesView(app: app, session: session)
                                    case .stashes: StashView(app: app, session: session)
                                    }
                                }
                                // The native split already owns the horizontal edges.
                                // Only compensate for toolbar/bottom safe areas here.
                                .padding(.top, geometry.safeAreaInsets.top)
                                .padding(.bottom, geometry.safeAreaInsets.bottom)
                                .frame(
                                    width: geometry.size.width,
                                    height: geometry.size.height + geometry.safeAreaInsets.top
                                        + geometry.safeAreaInsets.bottom
                                )
                                .ignoresSafeArea(.container, edges: .vertical)
                            }
                            // Native splits fill the horizontal safe area. Pure SwiftUI
                            // banners and the composer reserve its leading inset so
                            // that their content cannot extend under the sidebar.
                            .ignoresSafeArea(
                                .container, edges: app.workspace.route == .branches ? [] : .horizontal
                            )
                        }
                        .background(colors.canvas)
                        if app.workspace.inspector {
                            inspector(session)
                                .background(colors.sidebar)
                                .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel(L10n.text("检查器"))
                                .accessibilityIdentifier("repository-inspector")
                        }
                        // Native dividers can be transparent in a textured window.
                        // Give the gap a semantic surface without covering its drag area.
                    }.background(colors.border.allowsHitTesting(false))
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
        // Reserve both work panes and the widest optional columns without adding
        // another minimum inside the detail area's safe-inset compensation.
        .frame(minWidth: app.workspace.inspector ? 1292 : 980, minHeight: 640)
        .animation(nil, value: app.appearance)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("WeGit 工作区"))
        .background(
            WindowStateBridge(
                app: app, sidebarVisible: columnVisibility != .detailOnly,
                toggleSidebar: {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            ).frame(width: 0, height: 0).accessibilityHidden(true)
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    app.repositoryPickerPresented = true
                } label: {
                    Label(
                        app.session?.location.name ?? L10n.text("打开仓库"), systemImage: "folder.badge.gearshape"
                    )
                }
                .workbenchIconButton(toolbar: true).accessibilityIdentifier("toolbar-repository")
                .help(L10n.text("\(app.session?.location.root.path ?? L10n.text("打开仓库"))\n切换仓库 ⌘K"))
            }.sharedBackgroundVisibility(.hidden)
            if let session = app.session {
                ToolbarItem(placement: .primaryAction) { branchMenu(session) }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                if workspaceWidth < 1180 {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            RepositoryFetchMenu(session: session)
                            Divider()
                            RepositorySyncButtons(app: app, session: session)
                        } label: {
                            Label(L10n.text("同步"), systemImage: "arrow.triangle.2.circlepath")
                        }.workbenchGlassMenu(toolbar: true).labelStyle(.titleAndIcon)
                            .accessibilityLabel(L10n.text("同步")).accessibilityIdentifier("toolbar-sync")
                            .help(L10n.text("获取、拉取与推送"))
                    }.sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItemGroup(placement: .primaryAction) {
                        RepositoryFetchMenu(session: session, inToolbar: true).labelStyle(.titleAndIcon)
                        RepositorySyncButtons(app: app, session: session, inToolbar: true).labelStyle(
                            .titleAndIcon)
                    }.sharedBackgroundVisibility(.hidden)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    if session.isBusy {
                        ProgressView().controlSize(.small).help(session.activityLabel)
                        Button(L10n.text("取消"), systemImage: "stop.circle") { session.cancel() }
                            .workbenchIconButton(toolbar: true)
                    }
                    Button {
                        Task { await session.refresh() }
                    } label: {
                        Label {
                            Text(L10n.text("刷新"))
                        } icon: {
                            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                                .symbolEffect(
                                    .rotate,
                                    isActive: session.isRefreshing && !reduceMotion
                                        && app.preferences.interfaceMotion)
                        }
                    }.workbenchIconButton(toolbar: true).help(L10n.text("刷新 ⌘R")).accessibilityLabel(
                        L10n.text("刷新"))
                    Button(L10n.text("搜索仓库"), systemImage: "magnifyingglass", action: app.presentSearch).help(
                        L10n.text("搜索当前仓库 ⌘⇧F")
                    ).workbenchIconButton(toolbar: true).accessibilityIdentifier("toolbar-search")
                    Button(L10n.text("检查器"), systemImage: "sidebar.right") {
                        app.workspace.inspector.toggle()
                    }
                    .workbenchIconButton(toolbar: true)
                    .accessibilityValue(app.workspace.inspector ? L10n.text("已打开") : L10n.text("已关闭"))
                    .foregroundStyle(colors.text)
                    .help(app.workspace.inspector ? L10n.text("隐藏检查器") : L10n.text("显示检查器"))
                    .accessibilityIdentifier("toolbar-inspector")
                    Menu {
                        if app.preferences.showMenuBar {
                            Button(L10n.text("菜单栏快捷面板"), systemImage: "menubar.rectangle") {
                                app.menuBarRequestID = UUID()
                            }
                            Divider()
                        }
                        Button(L10n.text("远端管理…"), systemImage: "network") {
                            app.remoteManagementPresented = true
                        }
                        .accessibilityIdentifier("remote-management")
                        Button(L10n.text("活动记录"), systemImage: "clock") { app.activityPresented = true }
                        Button(L10n.text("命令面板…"), systemImage: "command") { app.palettePresented = true }
                        Button(L10n.text("切换仓库…"), systemImage: "folder") {
                            app.repositoryPickerPresented = true
                        }
                        Divider()
                        Button(L10n.text("在 Terminal 中打开"), systemImage: "terminal", action: app.openTerminal)
                        Button(L10n.text("复制仓库路径"), systemImage: "doc.on.doc", action: app.copyRepositoryPath)
                        Divider()
                        Button(L10n.text("设置…"), systemImage: "gearshape") { app.settingsRequestID = UUID() }
                    } label: {
                        Label(L10n.text("更多操作"), systemImage: "ellipsis")
                    }.workbenchGlassMenu(icon: true, toolbar: true).accessibilityIdentifier("toolbar-more")
                        .help(L10n.text("活动记录、命令面板与更多操作"))
                }.sharedBackgroundVisibility(.hidden)
            }
        }
        .sheet(isPresented: $app.clonePresented) { CloneView(app: app) }
        .sheet(isPresented: $app.remoteManagementPresented) {
            if let session = app.session { RemoteManagementSheet(app: app, session: session).id(session.id) }
        }
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
        .onChange(of: app.sidebarRequestID) { _, _ in
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
        .onChange(of: app.workspace.savedView) { _, _ in app.saveCurrentWorkspace() }
        .onAppear {
            app.mainWorkspaceMounted = true
            app.mainWindowRequested = false
            app.session?.activate()
        }
        .onDisappear {
            app.mainWorkspaceMounted = false
            app.saveCurrentWorkspace()
            if !app.menuBarPresented && !app.mainWindowRequested { app.session?.deactivate() }
        }
        .alert(
            L10n.text("操作未完成"),
            isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })
        ) {
            Button(L10n.text("好"), role: .cancel) { app.error = nil }
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
            Section {
                ForEach(WorkspaceRoute.allCases) { route in
                    HStack(spacing: 10) {
                        WorkbenchGlyph(symbol: route.icon, selected: app.workspace.route == route, size: 26)
                        Text(route.title).font(
                            .system(size: 13, weight: app.workspace.route == route ? .semibold : .regular))
                        Spacer()
                        if route == .changes {
                            CountBadge(
                                value: "\(session.status.files.count)",
                                tint: app.workspace.route == route
                                    ? colors.selectionText : colors.secondaryText)
                        }
                    }.padding(.horizontal, 8)
                        .frame(height: app.preferences.density == "compact" ? 34 : 42)
                        .foregroundStyle(app.workspace.route == route ? colors.selectionText : colors.text)
                        .background(
                            app.workspace.route == route ? colors.selectionBackground : Color.clear,
                            in: .rect(cornerRadius: AppStyle.controlRadius)
                        )
                        .tag(route).accessibilityIdentifier("route-\(route.id)")
                }
            } header: {
                Text(L10n.text("工作区")).foregroundStyle(colors.secondaryText)
            }
            Section {
                ForEach(app.recents.sorted { $0.pinned && !$1.pinned }) { record in
                    Button {
                        Task { await app.open(URL(fileURLWithPath: record.path)) }
                    } label: {
                        HStack(spacing: 9) {
                            WorkbenchGlyph(symbol: "folder", size: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.name).lineLimit(1)
                                if record.path == session.location.root.path {
                                    Text(session.status.displayBranch).font(.caption2).foregroundStyle(
                                        colors.secondaryText)
                                }
                            }
                            Spacer(minLength: 0)
                            if record.pinned {
                                Image(systemName: "pin.fill").font(.caption2)
                            }
                        }.padding(.vertical, app.preferences.density == "compact" ? 1 : 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .workbenchHoverRow()
                            .contentShape(.rect(cornerRadius: AppStyle.controlRadius))
                    }.buttonStyle(.plain)
                        .accessibilityIdentifier("sidebar-repository:" + record.path)
                        .contextMenu {
                            RepositoryContextMenu(app: app, record: record)
                        }
                }
            } header: {
                Text(L10n.text("仓库")).foregroundStyle(colors.secondaryText)
            }
        }.listStyle(.sidebar).tint(colors.accent).scrollContentBackground(.hidden).background(colors.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarBrandCard(openPanel: app.openPanel)
            }
    }

    @ViewBuilder private func statusBanner(_ session: RepositorySession) -> some View {
        if let error = session.refreshError {
            HStack {
                Label(
                    L10n.text("仓库状态未更新：\(error)"),
                    systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                Spacer()
                Button(L10n.text("重试刷新")) { Task { await session.refresh() } }.disabled(session.isRefreshing)
                Button(L10n.text("重新打开")) { Task { await app.open(session.location.root) } }.disabled(
                    session.isBusy)
            }.font(.callout).modifier(BannerSurface(tint: colors.modified))
        }
        if let warning = session.observationWarning {
            Text(L10n.text("\(warning) 当前使用手动刷新。")).font(.caption).foregroundStyle(colors.secondaryText)
                .padding(10)
        }
        if let commit = session.pendingPushCommit, !session.isBusy {
            HStack {
                let uncertain = session.pendingPush?.verification != nil
                Label(
                    uncertain
                        ? L10n.text("提交 \(commit.prefix(12)) 的远端结果待核对")
                        : L10n.text("本地提交 \(commit.prefix(12)) 已完成，推送待完成"),
                    systemImage: uncertain ? "exclamationmark.triangle" : "checkmark.circle")
                Spacer()
                Button(uncertain ? L10n.text("核对远端结果…") : L10n.text("继续推送…")) { app.presentSync(.push) }
                    .disabled(!session.canSync && !session.canVerifyPendingPush)
                    .accessibilityIdentifier("pending-push-action")
                Button(L10n.text("标记已处理")) {
                    if !uncertain
                        || app.confirm(
                            title: L10n.text("已手动核对推送目标？"),
                            message: L10n.text("此前推送没有完整结果。确认已自行核对原目标后，可关闭此提示。"),
                            action: L10n.text("标记已处理"), destructive: false)
                    {
                        session.pendingPush = nil
                    }
                }.help(L10n.text("只关闭这条恢复提示，不修改 Git 数据"))
            }.font(.callout).modifier(BannerSurface(tint: colors.accent))
        }
        if let error = session.error {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button(L10n.text("关闭")) { session.error = nil }
                }
                if !session.details.isEmpty {
                    DisclosureGroup(L10n.text("查看详情")) {
                        ScrollView {
                            Text(session.details).font(.caption.monospaced()).textSelection(.enabled).frame(
                                maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 140)
                    }
                }
            }.font(.callout).modifier(BannerSurface(tint: colors.negative))
        }
        if session.status.sequencer != .none {
            HStack {
                Label(
                    L10n.text("正在\(session.status.sequencer.title) · \(session.status.conflicts.count) 个冲突"),
                    systemImage: "arrow.triangle.merge")
                Spacer()
                if [.merge, .rebase].contains(session.status.sequencer) {
                    Button(L10n.text("中止…")) {
                        let expected = session.status.sequencer
                        if app.confirm(
                            title: L10n.text("中止 \(expected.rawValue)？"),
                            message: L10n.text("将撤回本次操作，操作中的手工编辑可能无法恢复。"),
                            action: L10n.text("中止"))
                        {
                            session.perform(L10n.text("中止")) {
                                try await $0.sequencer(continueOperation: false, expected: expected)
                            }
                        }
                    }.disabled(!session.canWrite).accessibilityIdentifier("sequencer-abort")
                    Button(L10n.text("继续")) {
                        let expected = session.status.sequencer
                        session.perform(L10n.text("继续")) {
                            try await $0.sequencer(continueOperation: true, expected: expected)
                        }
                    }
                    .disabled(!session.status.conflicts.isEmpty || !session.canWrite)
                    .accessibilityIdentifier("sequencer-continue")
                } else {
                    Text(L10n.text("请在 Terminal 完成当前操作")).foregroundStyle(colors.secondaryText)
                }
            }.font(.callout).modifier(BannerSurface(tint: colors.modified))
        }
    }

    private func branchMenu(_ session: RepositorySession) -> some View {
        Menu {
            Button(L10n.text("查找并切换分支…"), action: app.presentBranchSwitcher)
            Divider()
            ForEach(Array(session.branches.filter { !$0.remote }.prefix(20))) { branch in
                Button(branch.current ? "✓ \(branch.name)" : branch.name) {
                    app.switchBranch(branch, in: session)
                }.disabled(app.branchSwitchReason(branch, in: session) != nil)
                    .help(app.branchSwitchReason(branch, in: session) ?? L10n.text("切换到这个分支"))
            }
            Divider()
            Button(L10n.text("新建分支…")) { app.branchPresented = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text(session.status.displayBranch + " · " + RepositorySyncSummary(session: session).summary)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: workspaceWidth < 1180 ? 176 : 238)
            }
        }
        .workbenchGlassMenu(toolbar: true)
        .disabled(!session.canWrite)
        .accessibilityIdentifier("current-branch")
        .accessibilityLabel(
            (session.status.isDetached ? L10n.text("当前提交：") : L10n.text("当前分支："))
                + session.status.displayBranch
        )
        .accessibilityValue(L10n.text("同步状态：") + RepositorySyncSummary(session: session).summary)
    }

    private func inspector(_ session: RepositorySession) -> some View {
        ThemedForm(backgroundRole: .sidebar) {
            Section(L10n.text("仓库")) {
                LabeledContent(L10n.text("名称"), value: session.location.name)
                Text(session.location.root.path).font(.caption).textSelection(.enabled)
                Button(L10n.text("在 Finder 中显示")) { NSWorkspace.shared.open(session.location.root) }
                Button(L10n.text("在 Terminal 中打开"), action: app.openTerminal)
                if app.xcodeURL != nil {
                    Button(L10n.text("在 Xcode 中打开…"), action: app.openRepositoryInXcode)
                }
                Button(L10n.text("复制仓库路径"), action: app.copyRepositoryPath)
            }
            Section(L10n.text("分支")) {
                LabeledContent(L10n.text("当前"), value: session.status.displayBranch)
                LabeledContent(L10n.text("上游"), value: session.status.upstream ?? L10n.text("未设置"))
                LabeledContent(
                    L10n.text("领先 / 落后"),
                    value:
                        "\(session.status.ahead.map(String.init) ?? "—") / \(session.status.behind.map(String.init) ?? "—")"
                )
            }
            if app.workspace.route != .stashes, let diff = app.workspace.diff {
                Section(L10n.text("文件")) {
                    Text(diff.path).textSelection(.enabled)
                    LabeledContent(L10n.text("新增"), value: "\(diff.additions)")
                    LabeledContent(L10n.text("删除"), value: "\(diff.deletions)")
                }
            }
        }.formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(colors.sidebar)
    }
}

/// A quiet floating footer leaves repository state in the work panes and menu panel.
private struct SidebarBrandCard: View {
    @Environment(\.themeColors) private var colors
    let openPanel: @MainActor () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                content.background(colors.canvas, in: .rect(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(colors.border, lineWidth: contrast == .increased ? 2 : 0.5)
                            .allowsHitTesting(false)
                    }
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)
    }

    private var content: some View {
        HStack(spacing: 8) {
            BrandMark(tint: colors.brandBlue).frame(width: 48, height: 48).frame(width: 28, height: 28)
            Text("WeGit").font(.system(size: 14, weight: .medium))
                .accessibilityIdentifier("sidebar-brand")
            Spacer(minLength: 0)
            Button(action: openPanel) {
                Image(systemName: "plus").frame(width: 26, height: 26)
            }.accessibilityLabel(L10n.text("打开仓库"))
                .workbenchIconButton().controlSize(.regular)
                .accessibilityIdentifier("sidebar-add-repository").help(L10n.text("打开仓库 ⌘O"))
        }.padding(12).frame(maxWidth: .infinity)
    }
}

struct WelcomeView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            WelcomeIdentity()
            VStack(spacing: 8) {
                Text("WeGit").font(.system(size: 36, weight: .medium))
                Text(L10n.text("专注每一次改动。")).font(.title3).foregroundStyle(colors.secondaryText)
            }
            HStack(spacing: 12) {
                Button(L10n.text("打开仓库…"), systemImage: "folder", action: app.openPanel)
                    .workbenchPrimaryAction()
                    .tint(colors.primaryAction)
                    .controlSize(.large).accessibilityIdentifier("open-repository")
                Button(L10n.text("克隆仓库…"), systemImage: "arrow.down.to.line", action: app.presentClone)
                    .workbenchControlFamily().controlSize(.large)
            }
            if app.isOpening { ProgressView(L10n.text("正在打开仓库…")) }
            if app.recents.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("从这里开始")).font(.caption.weight(.medium))
                        .foregroundStyle(colors.secondaryText)
                    ForEach(
                        [
                            L10n.text("打开本地仓库，或从远端克隆一份"),
                            L10n.text("逐文件暂存，提交前看清每一处改动"),
                            L10n.text("⌘K 切换仓库，⌘⇧F 搜索当前仓库"),
                        ], id: \.self
                    ) { text in
                        HStack(spacing: 10) {
                            Text(text).foregroundStyle(colors.text)
                            Spacer(minLength: 0)
                        }
                    }
                }.frame(width: 520).padding(12).workbenchSurface(radius: AppStyle.controlRadius + 12)
                    .accessibilityIdentifier("welcome-first-run")
            }
            if !app.recents.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(L10n.text("最近打开"), systemImage: "clock").font(.caption.weight(.medium))
                            .foregroundStyle(colors.secondaryText)
                        Spacer()
                        Text(L10n.text("⌘O 打开")).font(.caption).foregroundStyle(colors.secondaryText)
                    }
                    ForEach(app.recents.prefix(5)) { record in
                        Button {
                            Task { await app.open(URL(fileURLWithPath: record.path)) }
                        } label: {
                            HStack {
                                Image(systemName: "folder").foregroundStyle(colors.text)
                                Text(record.name)
                                Spacer()
                                Text(record.path).foregroundStyle(colors.secondaryText).lineLimit(1)
                                    .truncationMode(
                                        .middle)
                            }
                        }.buttonStyle(.plain).workbenchHoverRow()
                            .contextMenu { RepositoryContextMenu(app: app, record: record) }
                    }
                }.frame(width: 520).padding(12).workbenchSurface(radius: AppStyle.controlRadius + 12)
            }
            Spacer()
            HStack(spacing: 16) {
                WorkflowStep(title: L10n.text("浏览改动"), symbol: "doc.text.magnifyingglass")
                Image(systemName: "chevron.right").font(.system(size: 8)).accessibilityHidden(true)
                WorkflowStep(title: L10n.text("整理暂存"), symbol: "tray")
                Image(systemName: "chevron.right").font(.system(size: 8)).accessibilityHidden(true)
                WorkflowStep(title: L10n.text("记录提交"), symbol: "checkmark.circle")
            }.font(.caption).foregroundStyle(colors.secondaryText).padding(.bottom, 28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(colors.canvas)
    }
}
