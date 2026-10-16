import SwiftUI
import WeGitCore

struct RepositorySearchRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let route: WorkspaceRoute
}

private enum RepositorySearchScope: String, CaseIterable {
    case files = "更改文件"
    case commits = "提交"
    case branches = "分支"
    var title: String { L10n.key(rawValue) }
}

private enum RepositorySearchResult: Identifiable {
    case file(FileChange)
    case commit(GitCommit)
    case branch(GitBranch)
    var id: String {
        switch self {
        case .file(let value): "file:" + value.id
        case .commit(let value): "commit:" + value.id
        case .branch(let value): "branch:" + value.id
        }
    }
    var title: String {
        switch self {
        case .file(let value): value.path
        case .commit(let value): value.subject
        case .branch(let value): value.name
        }
    }
    var subtitle: String {
        switch self {
        case .file(let value):
            value.conflict
                ? L10n.text("存在冲突")
                : value.untracked ? L10n.text("未跟踪") : value.staged ? L10n.text("已暂存") : L10n.text("未暂存")
        case .commit(let value): "\(value.id.prefix(12)) · \(value.author)"
        case .branch(let value):
            "\(value.oid.prefix(12)) · \(value.remote ? L10n.text("远端跟踪分支") : L10n.text("本地分支"))"
        }
    }
}

struct RepositorySearchView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    let request: RepositorySearchRequest
    @Environment(\.dismiss) private var dismiss
    @State private var scope: RepositorySearchScope
    @State private var query = ""
    @State private var field = HistorySearchField.message
    @State private var commits: [GitCommit] = []
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    @State private var selected: String?
    @FocusState private var searchFocused: Bool

    init(app: AppState, request: RepositorySearchRequest) {
        self.app = app
        self.request = request
        _scope = State(
            initialValue: request.route == .changes
                ? .files : request.route == .branches ? .branches : .commits)
    }

    private var results: [RepositorySearchResult] {
        switch scope {
        case .files:
            request.session.status.files.filter {
                query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)
            }.prefix(100).map { .file($0) }
        case .branches:
            request.session.branches.filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
            }.prefix(100).map { .branch($0) }
        case .commits: commits.map { .commit($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetTitle(title: L10n.text("搜索 \(request.session.location.name)"), symbol: "magnifyingglass")
            WorkbenchGlassTabs(
                title: L10n.text("搜索范围"), selection: $scope,
                tabs: RepositorySearchScope.allCases.map { GlassTab(value: $0, title: $0.title) },
                height: 36, identifier: "repository-search-scope")
            HStack {
                if scope == .commits {
                    Picker(L10n.text("提交字段"), selection: $field) {
                        ForEach(HistorySearchField.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 110).accessibilityIdentifier("repository-search-field")
                }
                WorkbenchSearchField(
                    prompt: scope == .commits ? L10n.text("搜索提交\(field.title)") : L10n.text("输入名称或路径"),
                    text: $query, identifier: "repository-search-query", focus: $searchFocused
                )
                .onSubmit { openSelected() }
                .onKeyPress(.downArrow) {
                    move(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(-1)
                    return .handled
                }
            }
            if loading { ProgressView(L10n.text("搜索提交…")).controlSize(.small) }
            if let error { Text(error).font(.callout).foregroundStyle(colors.negative) }
            List(selection: $selected) {
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title).lineLimit(1).truncationMode(.middle)
                        Text(result.subtitle).font(.caption).foregroundStyle(colors.secondaryText)
                    }.padding(.vertical, 3).tag(result.id).contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            selected = result.id
                            openSelected()
                        }
                }
            }.overlay {
                if results.isEmpty && !loading && error == nil {
                    Text(
                        scope == .commits && query.isEmpty
                            ? L10n.text("输入提交消息、作者或 SHA 开始搜索") : L10n.text("没有匹配结果")
                    )
                    .foregroundStyle(colors.secondaryText)
                }
            }.accessibilityIdentifier("repository-search-results")
            HStack {
                Text(
                    scope == .commits
                        ? (more ? L10n.text("显示前 50 项，可在历史页面继续搜索") : L10n.text("\(results.count) 项结果"))
                        : L10n.text("最多显示 100 项；更改文件仅包含当前未提交内容")
                )
                .font(.caption).foregroundStyle(colors.secondaryText)
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("打开结果")) { openSelected() }.keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || app.session !== request.session)
            }
        }.padding(22).frame(width: 630, height: 490)
            .task {
                searchFocused = true
                selected = results.first?.id
            }
            .task(id: "\(scope.rawValue):\(field.rawValue):\(query):\(request.session.historyGeneration)") {
                await search()
            }
            .onChange(of: results.map(\.id)) { _, ids in
                if !ids.contains(selected ?? "") { selected = ids.first }
            }
    }

    private func search() async {
        commits = []
        more = false
        error = nil
        guard scope == .commits && !query.isEmpty else {
            loading = false
            return
        }
        loading = true
        do {
            try await Task.sleep(for: .milliseconds(200))
            let anchor = try await request.session.service.historyAnchor(query: query, searchField: field)
            let page = try await request.session.service.historyPage(anchor, count: 50)
            try Task.checkCancellation()
            commits = page.commits
            more = page.next != nil
            loading = false
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    private func move(_ step: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selected } ?? 0
        selected = results[min(max(index + step, 0), results.count - 1)].id
    }

    private func openSelected() {
        guard app.session === request.session, let result = results.first(where: { $0.id == selected }) else {
            return
        }
        switch result {
        case .file(let file):
            app.workspace.route = .changes
            app.workspace.filter = ""
            app.workspace.changeFilter = .all
            app.workspace.selectedFile = file.layers.first.map { $0.rawValue + "|" + file.path }
        case .branch(let branch):
            app.workspace.route = .branches
            app.workspace.branchFilter = branch.name
        case .commit(let commit):
            request.session.historyState.searchField = .sha
            request.session.historyState.query = commit.id
            app.workspace.route = .history
        }
        dismiss()
    }
}
