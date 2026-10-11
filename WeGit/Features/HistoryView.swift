import AppKit
import SwiftUI
import WeGitCore

struct HistoryView: View {
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
                HStack {
                    Text("提交历史").font(.headline)
                    Spacer()
                    Text("\(history.commits.count) 个提交").font(.caption).foregroundStyle(
                        AppColors.secondaryText
                    )
                    .accessibilityIdentifier("history-count")
                }.padding(14)
                HStack {
                    Picker("浏览范围", selection: $history.scope) {
                        Text("全部引用").tag(HistoryScope.all)
                        Text("当前分支").tag(HistoryScope.currentBranch)
                    }.labelsHidden().frame(width: 100).accessibilityIdentifier("history-scope")
                    Picker("搜索字段", selection: $history.searchField) {
                        ForEach(HistorySearchField.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 70).accessibilityIdentifier("history-search-field")
                    TextField("搜索\(history.searchField.title)", text: $history.query).textFieldStyle(
                        .roundedBorder
                    )
                    .accessibilityIdentifier("history-search")
                    .accessibilityLabel("搜索提交" + history.searchField.title)
                }.padding(.horizontal, 12).padding(.bottom, 10)
                if history.stale {
                    HStack {
                        Text("引用已更新，当前仍显示此前的历史。").font(.caption).foregroundStyle(AppColors.secondaryText)
                        Button("读取最新历史") { reload() }
                    }.padding(10).accessibilityIdentifier("history-stale")
                }
                Divider()
                if history.commits.isEmpty {
                    if history.loading {
                        ProgressView("读取提交历史…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EmptyPanel(
                            title: history.cancelled
                                ? "已取消读取"
                                : history.error != nil
                                    ? "无法读取历史"
                                    : history.anchor == nil
                                        ? "尚未读取历史"
                                        : history.query.isEmpty ? "暂无提交" : "没有匹配提交",
                            symbol: "clock.arrow.circlepath",
                            message: history.error
                                ?? (history.anchor == nil ? "点击重试读取当前仓库的提交。" : "选择其他浏览范围，或调整搜索条件。"))
                    }
                } else {
                    HistoryTableView(app: app, session: session, history: history)
                }
                HStack {
                    if history.loading {
                        ProgressView().controlSize(.small)
                        Button("取消读取") { history.cancel(userInitiated: true) }
                    } else if history.error != nil || history.anchor == nil {
                        Button("重试") { if history.hasMore { history.loadMore() } else { reload() } }
                    } else if history.hasMore {
                        Button("加载更多提交") { history.loadMore() }.accessibilityIdentifier("history-load-more")
                    }
                    if !history.query.isEmpty {
                        Text("筛选结果；清除搜索可查看完整提交图。").font(.caption).foregroundStyle(AppColors.secondaryText)
                    }
                }.padding(10)
            }.frame(minWidth: 280, idealWidth: 590)
                .accessibilityElement(children: .contain).accessibilityLabel("历史浏览与筛选")
            VStack(alignment: .leading, spacing: 0) {
                if let commit = app.workspace.selectedCommit {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(commit.subject).font(.title3.weight(.semibold))
                        HStack {
                            Text("作者：\(commit.author) <\(commit.authorEmail)>")
                            Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                        }.font(.caption).foregroundStyle(AppColors.secondaryText)
                        Text(
                            "提交者：\(commit.committer) <\(commit.committerEmail)> · \(commit.committedAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                        DisclosureGroup("完整提交消息") {
                            ScrollView {
                                Text(commit.message).textSelection(.enabled).frame(
                                    maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 120)
                        }.font(.caption)
                        HStack {
                            Text(commit.id).font(.caption.monospaced()).textSelection(.enabled)
                            Button("复制 SHA", systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(commit.id, forType: .string)
                            }.labelStyle(.iconOnly)
                            Spacer()
                            Menu("操作") {
                                Button("从此提交新建分支…") {
                                    branchStart = commit.id
                                    createBranch = true
                                }
                                Button("检出此提交…") {
                                    let head = session.status.head
                                    if app.confirm(
                                        title: "检出 \(commit.id.prefix(12))？",
                                        message:
                                            "将进入 Detached HEAD。后续提交不会自动归属现有分支；需要继续开发时可先从此提交新建分支。Git 会拒绝覆盖冲突的本地改动。",
                                        action: "检出提交", destructive: false)
                                    {
                                        session.perform("检出提交") {
                                            try await $0.checkoutCommit(commit.id, expectedHead: head)
                                        }
                                    }
                                }
                            }.fixedSize().disabled(!session.canWrite)
                        }
                        if commit.parents.count > 1 {
                            Picker("比较父提交", selection: $parent) {
                                ForEach(Array(commit.parents.enumerated()), id: \.element) { index, oid in
                                    Text("父提交 \(index + 1) · \(oid.prefix(7))").tag(Optional(oid))
                                }
                            }.accessibilityIdentifier("history-parent")
                        } else {
                            Text(
                                commit.parents.isEmpty ? "根提交 · 相对于空树" : "父提交：\(commit.parents[0].prefix(12))"
                            )
                            .font(.caption).foregroundStyle(AppColors.secondaryText)
                        }
                    }.padding(18)
                    Divider()
                    CommitFilesView(app: app, session: session, detail: history.detail)

                } else {
                    EmptyPanel(
                        title: "选择一次提交", symbol: "clock.arrow.circlepath", message: "查看提交消息、父子关系和代码差异。")
                }
            }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain).accessibilityLabel("提交详情")
        }
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

    private func reload(delayed: Bool = false) {
        reloadTask?.cancel()
        reloadTask = Task {
            if delayed { do { try await Task.sleep(for: .milliseconds(250)) } catch { return } }
            await history.reload()
        }
    }

}

struct BranchesView: View {
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @State private var editor: BranchEditRequest?
    @State private var deletion: BranchDeletionPlan?
    @State private var preparing = false
    @State private var prepareTask: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("分支").font(.title3.weight(.semibold))
                if preparing { ProgressView().controlSize(.small) }
                Spacer()
                Button("新建分支…", systemImage: "plus") { app.branchPresented = true }.disabled(
                    !session.canWrite || session.status.head == nil)
            }.padding(18)
            TextField("筛选分支名称或上游", text: $app.workspace.branchFilter).textFieldStyle(.roundedBorder)
                .padding(.horizontal, 18).padding(.bottom, 12).accessibilityIdentifier("branches-filter")
            Divider()
            List {
                ForEach([false, true], id: \.self) { remote in
                    Section(remote ? "远端跟踪分支" : "本地分支") {
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
                                    branch.current ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(branch.name).font(.headline)
                                        if branch.current { Text("当前").font(.caption).foregroundStyle(.blue) }
                                    }
                                    Text("\(branch.oid.prefix(7)) · \(trackingText(branch))").font(.caption)
                                        .foregroundStyle(AppColors.secondaryText)
                                    if let commit = session.branchTips[branch.oid] {
                                        Text(
                                            "\(commit.subject) · \(commit.date.formatted(date: .abbreviated, time: .omitted))"
                                        )
                                        .font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(1)
                                    }
                                    if let path = branch.worktreePath, !branch.current {
                                        Text("正在工作树中使用：\(path)").font(.caption2).foregroundStyle(
                                            AppColors.secondaryText
                                        )
                                        .lineLimit(1).help(path)
                                    }
                                }
                                Spacer()
                                if !branch.current && !branch.remote && branch.worktreePath == nil
                                    && branch.symbolicTarget == nil
                                {
                                    Button("切换") {
                                        app.switchBranch(branch, in: session)
                                    }.disabled(app.branchSwitchReason(branch, in: session) != nil)
                                }
                                if !branch.current && branch.symbolicTarget == nil {
                                    Button("合并…") {
                                        let head = session.status.head
                                        if app.confirm(
                                            title: "合并到 \(session.status.displayBranch)？",
                                            message: "来源：\(branch.name)\n目标：\(session.status.displayBranch)",
                                            action: "合并", destructive: false)
                                        {
                                            session.perform("合并") {
                                                try await $0.merge(branch, expectedHead: head)
                                            }
                                        }
                                    }.disabled(app.mergeReason(branch, in: session) != nil)
                                        .help(app.mergeReason(branch, in: session) ?? "将所选分支合并到当前分支")
                                        .accessibilityIdentifier("branch-merge:" + branch.id)
                                }
                                Menu {
                                    if branch.remote {
                                        Button("创建本地跟踪分支…") {
                                            editor = BranchEditRequest(branch: branch, mode: .tracking)
                                        }
                                    } else {
                                        Button("重命名…") {
                                            editor = BranchEditRequest(branch: branch, mode: .rename)
                                        }
                                        .disabled(
                                            branch.symbolicTarget != nil
                                                || (branch.worktreePath != nil && !branch.current))
                                        Button("设置上游…") {
                                            editor = BranchEditRequest(branch: branch, mode: .upstream)
                                        }
                                        .disabled(
                                            branch.symbolicTarget != nil
                                                || (branch.worktreePath != nil && !branch.current))
                                        Button("删除本地分支…", role: .destructive) { prepareDeletion(branch) }
                                            .disabled(
                                                branch.current || branch.worktreePath != nil
                                                    || branch.symbolicTarget != nil || preparing)
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier(
                                    "branch-actions:" + branch.id
                                )
                                .accessibilityLabel("更多分支操作：" + branch.name)
                            }.padding(.vertical, app.preferences.density == "compact" ? 3 : 8).disabled(
                                !session.canWrite
                            )
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("branch-row:" + branch.id)
                            .task(id: branch.oid) { await session.loadBranchTip(branch.oid) }
                        }
                    }
                }
            }.listStyle(.inset)
        }
        .sheet(item: $editor) { BranchEditorSheet(app: app, session: session, request: $0) }
        .sheet(item: $deletion) { BranchDeletionSheet(app: app, session: session, plan: $0) }
        .onDisappear { prepareTask?.cancel() }
    }

    private func trackingText(_ branch: GitBranch) -> String {
        if branch.remote { return "远端跟踪分支" }
        guard branch.upstreamRef != nil else { return "未设置上游" }
        guard let ahead = branch.ahead, let behind = branch.behind else {
            return "上游：\(branch.upstream)（引用不可用）"
        }
        return "上游：\(branch.upstream) · 领先 \(ahead) · 落后 \(behind)"
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
