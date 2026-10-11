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
            value.conflict ? "存在冲突" : value.untracked ? "未跟踪" : value.staged ? "已暂存" : "未暂存"
        case .commit(let value): "\(value.id.prefix(12)) · \(value.author)"
        case .branch(let value): "\(value.oid.prefix(12)) · \(value.remote ? "远端跟踪分支" : "本地分支")"
        }
    }
}

struct RepositorySearchView: View {
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
            Text("搜索 \(request.session.location.name)").font(.title2.weight(.semibold))
            Picker("搜索范围", selection: $scope) {
                ForEach(RepositorySearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("repository-search-scope")
            HStack {
                if scope == .commits {
                    Picker("提交字段", selection: $field) {
                        ForEach(HistorySearchField.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 110).accessibilityIdentifier("repository-search-field")
                }
                TextField(scope == .commits ? "搜索提交\(field.title)" : "输入名称或路径", text: $query)
                    .textFieldStyle(.roundedBorder).focused($searchFocused).onSubmit { openSelected() }
                    .accessibilityIdentifier("repository-search-query")
                    .onKeyPress(.downArrow) {
                        move(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        move(-1)
                        return .handled
                    }
            }
            if loading { ProgressView("搜索提交…").controlSize(.small) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            List(selection: $selected) {
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title).lineLimit(1).truncationMode(.middle)
                        Text(result.subtitle).font(.caption).foregroundStyle(AppColors.secondaryText)
                    }.padding(.vertical, 3).tag(result.id).contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            selected = result.id
                            openSelected()
                        }
                }
            }.overlay {
                if results.isEmpty && !loading && error == nil {
                    Text(scope == .commits && query.isEmpty ? "输入提交消息、作者或 SHA 开始搜索" : "没有匹配结果")
                        .foregroundStyle(AppColors.secondaryText)
                }
            }.accessibilityIdentifier("repository-search-results")
            HStack {
                Text(
                    scope == .commits
                        ? (more ? "显示前 50 项，可在历史页面继续搜索" : "\(results.count) 项结果")
                        : "最多显示 100 项；更改文件仅包含当前未提交内容"
                )
                .font(.caption).foregroundStyle(AppColors.secondaryText)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("打开结果") { openSelected() }.keyboardShortcut(.defaultAction)
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
