import AppKit
import SwiftUI
import WeGitCore

struct HistoryView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @Bindable var history: HistoryState
    @State private var reloadTask: Task<Void, Never>?
    @State private var parent: String?
    @State private var createBranch = false
    @State private var branchStart: String?

    init(app: AppState, session: RepositorySession) {
        self.app = app
        self.session = session
        history = session.historyState
    }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PanelHeader(title: L10n.text("提交历史"), symbol: "clock.arrow.circlepath") {
                    Spacer()
                    CountBadge(value: L10n.count("%lld 个提交", history.commits.count))
                        .accessibilityIdentifier("history-count")
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        scopePicker
                        searchFieldPicker
                        searchInput.frame(minWidth: 160)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            scopePicker
                            searchFieldPicker
                            Spacer(minLength: 0)
                        }
                        searchInput
                    }
                }.padding(.horizontal, 12).padding(.bottom, 10).background(colors.chrome)
                if history.stale {
                    HStack {
                        Text(L10n.text("引用已更新，当前仍显示此前的历史。")).font(.caption).foregroundStyle(
                            colors.secondaryText)
                        Button(L10n.text("读取最新历史")) { reload() }
                    }.padding(10).accessibilityIdentifier("history-stale")
                }
                Divider()
                if history.commits.isEmpty {
                    if history.loading {
                        ProgressView(L10n.text("读取提交历史…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EmptyPanel(
                            title: history.cancelled
                                ? L10n.text("已取消读取")
                                : history.error != nil
                                    ? L10n.text("无法读取历史")
                                    : history.anchor == nil
                                        ? L10n.text("尚未读取历史")
                                        : history.query.isEmpty ? L10n.text("暂无提交") : L10n.text("没有匹配提交"),
                            symbol: "clock.arrow.circlepath",
                            message: history.error
                                ?? (history.anchor == nil
                                    ? L10n.text("点击重试读取当前仓库的提交。") : L10n.text("选择其他浏览范围，或调整搜索条件。")))
                    }
                } else {
                    HistoryTableView(app: app, session: session, history: history)
                }
                HStack {
                    if history.loading {
                        ProgressView().controlSize(.small)
                        Button(L10n.text("取消读取")) { history.cancel(userInitiated: true) }
                    } else if history.error != nil || history.anchor == nil {
                        Button(L10n.text("重试")) {
                            if history.hasMore { history.loadMore() } else { reload() }
                        }
                    } else if history.hasMore {
                        Button(L10n.text("加载更多提交")) { history.loadMore() }.accessibilityIdentifier(
                            "history-load-more")
                    }
                    if !history.query.isEmpty {
                        Text(L10n.text("筛选结果；清除搜索可查看完整提交图。")).font(.caption).foregroundStyle(
                            colors.secondaryText)
                    }
                }.padding(10)
            }.frame(minWidth: 280, idealWidth: 590)
                .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("历史浏览与筛选"))
            VStack(alignment: .leading, spacing: 0) {
                if let commit = app.workspace.selectedCommit {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(commit.subject).font(.title3.weight(.semibold))
                        HStack {
                            Text(L10n.text("作者：\(commit.author) <\(commit.authorEmail)>"))
                            Text(
                                commit.date.formatted(
                                    Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)
                                ))
                        }.font(.caption).foregroundStyle(colors.secondaryText)
                        Text(
                            L10n.text(
                                "提交者：\(commit.committer) <\(commit.committerEmail)> · \(commit.committedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))"
                            )
                        )
                        .font(.caption).foregroundStyle(colors.secondaryText)
                        DisclosureGroup(L10n.text("完整提交消息")) {
                            ScrollView {
                                Text(commit.message).textSelection(.enabled).frame(
                                    maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 120)
                        }.font(.caption)
                        HStack {
                            Text(commit.id).font(.caption.monospaced()).textSelection(.enabled)
                            Button(L10n.text("复制 SHA"), systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(commit.id, forType: .string)
                            }.labelStyle(.iconOnly).accessibilityIdentifier("history-copy-sha")
                            Spacer()
                            Menu(L10n.text("操作")) {
                                Button(L10n.text("从此提交新建分支…")) {
                                    branchStart = commit.id
                                    createBranch = true
                                }
                                Button(L10n.text("检出此提交…")) {
                                    let head = session.status.head
                                    if app.confirm(
                                        title: L10n.text("检出 \(commit.id.prefix(12))？"),
                                        message:
                                            L10n.text(
                                                "将进入 Detached HEAD。后续提交不会自动归属现有分支；需要继续开发时可先从此提交新建分支。Git 会拒绝覆盖冲突的本地改动。"
                                            ),
                                        action: L10n.text("检出提交"), destructive: false)
                                    {
                                        session.perform(L10n.text("检出提交")) {
                                            try await $0.checkoutCommit(commit.id, expectedHead: head)
                                        }
                                    }
                                }
                            }.fixedSize().disabled(!session.canWrite)
                                .tint(colors.accentText)
                                .accessibilityIdentifier("history-operations")
                                .accessibilityLabel(L10n.text("所选提交的操作"))
                        }
                        if commit.parents.count > 1 {
                            Picker(L10n.text("比较父提交"), selection: $parent) {
                                ForEach(Array(commit.parents.enumerated()), id: \.element) { index, oid in
                                    Text(L10n.text("父提交 \(index + 1) · \(oid.prefix(7))")).tag(Optional(oid))
                                }
                            }.tint(colors.accentText).accessibilityIdentifier("history-parent")
                        } else {
                            Text(
                                commit.parents.isEmpty
                                    ? L10n.text("根提交 · 相对于空树")
                                    : L10n.text("父提交：\(commit.parents[0].prefix(12))")
                            )
                            .font(.caption).foregroundStyle(colors.secondaryText)
                        }
                    }.padding(18).background(colors.chrome)
                    Divider()
                    CommitFilesView(app: app, session: session, detail: history.detail)

                } else {
                    EmptyPanel(
                        title: L10n.text("选择一次提交"), symbol: "clock.arrow.circlepath",
                        message: L10n.text("查看提交消息、父子关系和代码差异。"))
                }
            }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("提交详情"))
        }.background(colors.canvas)
            .task(id: "\(session.id):\(session.historyGeneration)") { await session.loadHistory() }
            .onChange(of: history.scope) { _, _ in reload() }
            .onChange(of: history.query) { _, _ in reload(delayed: true) }
            .onChange(of: history.searchField) { _, _ in reload(delayed: true) }
            .onChange(of: history.commits.first?.id) { _, _ in
                if history.searchField == .sha && !history.query.isEmpty && history.commits.count == 1 {
                    app.workspace.selectedCommit = history.commits.first
                }
            }
            .onChange(of: app.workspace.selectedCommit?.id) { _, _ in
                parent = app.workspace.selectedCommit?.parents.first
            }
            .task(id: "\(session.location.id):\(app.workspace.selectedCommit?.id ?? ""):\(parent ?? "")") {
                await history.detail.select(app.workspace.selectedCommit, parent: parent)
            }
            .onDisappear {
                reloadTask?.cancel()
                history.cancel()
                history.detail.cancel()
            }
            .sheet(isPresented: $createBranch) { NewBranchView(app: app, startCommit: branchStart) }
    }

    private var scopePicker: some View {
        Picker(L10n.text("浏览范围"), selection: $history.scope) {
            Text(L10n.text("全部引用")).tag(HistoryScope.all)
            Text(L10n.text("当前分支")).tag(HistoryScope.currentBranch)
        }.labelsHidden().fixedSize().tint(colors.accentText).accessibilityIdentifier("history-scope")
    }

    private var searchFieldPicker: some View {
        Picker(L10n.text("搜索字段"), selection: $history.searchField) {
            ForEach(HistorySearchField.allCases, id: \.self) { Text($0.title).tag($0) }
        }.labelsHidden().fixedSize().tint(colors.accentText).accessibilityIdentifier("history-search-field")
    }

    private var searchInput: some View {
        WorkbenchSearchField(
            prompt: L10n.text("搜索提交\(history.searchField.title)"),
            text: $history.query, identifier: "history-search")
    }

    private func reload(delayed: Bool = false) {
        reloadTask?.cancel()
        reloadTask = Task {
            if delayed { do { try await Task.sleep(for: .milliseconds(250)) } catch { return } }
            await history.reload()
        }
    }

}

struct BranchesView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @State private var editor: BranchEditRequest?
    @State private var deletion: BranchDeletionPlan?
    @State private var preparing = false
    @State private var prepareTask: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: L10n.text("分支"), symbol: "arrow.triangle.branch") {
                if preparing { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.text("新建分支…"), systemImage: "plus") { app.branchPresented = true }.disabled(
                    !session.canWrite || session.status.head == nil)
            }
            WorkbenchSearchField(
                prompt: L10n.text("筛选分支名称或上游"), text: $app.workspace.branchFilter,
                identifier: "branches-filter"
            )
            .padding(.horizontal, 14).padding(.bottom, 12).background(colors.chrome)
            Divider()
            List {
                ForEach([false, true], id: \.self) { remote in
                    Text(remote ? L10n.text("远端跟踪分支") : L10n.text("本地分支"))
                        .font(.caption.weight(.semibold)).foregroundStyle(colors.secondaryText)
                        .listRowSeparator(.hidden).accessibilityAddTraits(.isHeader)
                    Group {
                        ForEach(
                            session.branches.filter {
                                $0.remote == remote
                                    && (app.workspace.branchFilter.isEmpty
                                        || $0.name.localizedCaseInsensitiveContains(
                                            app.workspace.branchFilter)
                                        || $0.upstream.localizedCaseInsensitiveContains(
                                            app.workspace.branchFilter))
                            }
                        ) { branch in
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.triangle.branch").foregroundStyle(
                                    branch.current ? colors.text : colors.secondaryText)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(branch.name).font(.headline).lineLimit(1)
                                            .truncationMode(.middle).help(branch.name)
                                        if branch.current { CountBadge(value: L10n.text("当前")) }
                                    }
                                    Text("\(branch.oid.prefix(7)) · \(trackingText(branch))").font(.caption)
                                        .foregroundStyle(colors.secondaryText)
                                        .lineLimit(1).truncationMode(.middle).help(trackingText(branch))
                                    if let commit = session.branchTips[branch.oid] {
                                        Text(
                                            "\(commit.subject) · \(commit.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale)))"
                                        )
                                        .font(.caption).foregroundStyle(colors.secondaryText).lineLimit(1)
                                    }
                                    if let path = branch.worktreePath, !branch.current {
                                        Text(L10n.text("正在工作树中使用：\(path)")).font(.caption2).foregroundStyle(
                                            colors.secondaryText
                                        )
                                        .lineLimit(1).help(path)
                                    }
                                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                Spacer(minLength: 8)
                                if !branch.current && !branch.remote && branch.worktreePath == nil
                                    && branch.symbolicTarget == nil
                                {
                                    Button(L10n.text("切换")) {
                                        app.switchBranch(branch, in: session)
                                    }.disabled(app.branchSwitchReason(branch, in: session) != nil)
                                }
                                if !branch.current && branch.symbolicTarget == nil {
                                    Button(L10n.text("合并…")) {
                                        let head = session.status.head
                                        if app.confirm(
                                            title: L10n.text("合并到 \(session.status.displayBranch)？"),
                                            message: L10n.text(
                                                "来源：\(branch.name)\n目标：\(session.status.displayBranch)"),
                                            action: L10n.text("合并"), destructive: false)
                                        {
                                            session.perform(L10n.text("合并")) {
                                                try await $0.merge(branch, expectedHead: head)
                                            }
                                        }
                                    }.disabled(app.mergeReason(branch, in: session) != nil)
                                        .help(
                                            app.mergeReason(branch, in: session) ?? L10n.text("将所选分支合并到当前分支")
                                        )
                                        .accessibilityIdentifier("branch-merge:" + branch.id)
                                }
                                Menu {
                                    if branch.remote {
                                        Button(L10n.text("创建本地跟踪分支…")) {
                                            editor = BranchEditRequest(branch: branch, mode: .tracking)
                                        }
                                    } else {
                                        Button(L10n.text("重命名…")) {
                                            editor = BranchEditRequest(branch: branch, mode: .rename)
                                        }
                                        .disabled(
                                            branch.symbolicTarget != nil
                                                || (branch.worktreePath != nil && !branch.current))
                                        Button(L10n.text("设置上游…")) {
                                            editor = BranchEditRequest(branch: branch, mode: .upstream)
                                        }
                                        .disabled(
                                            branch.symbolicTarget != nil
                                                || (branch.worktreePath != nil && !branch.current))
                                        Button(L10n.text("删除本地分支…"), role: .destructive) {
                                            prepareDeletion(branch)
                                        }
                                        .disabled(
                                            branch.current || branch.worktreePath != nil
                                                || branch.symbolicTarget != nil || preparing)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .workbenchGlassMenu(icon: true).accessibilityIdentifier(
                                    "branch-actions:" + branch.id
                                )
                                .accessibilityLabel(L10n.text("更多分支操作：") + branch.name)
                            }.padding(.vertical, app.preferences.density == "compact" ? 3 : 8).disabled(
                                !session.canWrite
                            )
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("branch-row:" + branch.id)
                            .task(id: branch.oid) { await session.loadBranchTip(branch.oid) }
                        }
                    }
                }
            }.listStyle(.inset).scrollContentBackground(.hidden).background(colors.canvas)
                .accessibilityIdentifier("branches-list")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colors.canvas)
        .sheet(item: $editor) { BranchEditorSheet(app: app, session: session, request: $0) }
        .sheet(item: $deletion) { BranchDeletionSheet(app: app, session: session, plan: $0) }
        .onDisappear { prepareTask?.cancel() }
    }

    private func trackingText(_ branch: GitBranch) -> String {
        if branch.remote { return L10n.text("远端跟踪分支") }
        guard branch.upstreamRef != nil else { return L10n.text("未设置上游") }
        guard let ahead = branch.ahead, let behind = branch.behind else {
            return L10n.text("上游：\(branch.upstream)（引用不可用）")
        }
        return L10n.text("上游：\(branch.upstream) · 领先 \(ahead) · 落后 \(behind)")
    }

    private func prepareDeletion(_ branch: GitBranch) {
        guard !preparing && !session.isBusy else { return }
        preparing = true
        let head = session.status.head
        prepareTask = Task {
            defer {
                preparing = false
                prepareTask = nil
            }
            do {
                let plan = try await session.service.prepareBranchDeletion(branch, expectedHead: head)
                if app.session === session && !Task.isCancelled { deletion = plan }
            } catch {
                if app.session === session && !Task.isCancelled { session.show(error) }
            }
        }
    }
}
