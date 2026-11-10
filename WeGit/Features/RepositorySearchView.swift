import SwiftUI
import WeGitCore

struct RepositorySearchRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let route: WorkspaceRoute
    /// The app records this destination and opens it after the search sheet dismisses.
    var openResult: (@MainActor (RepositoryQueryResult) -> Void)? = nil
}

struct RepositorySearchView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    let request: RepositorySearchRequest
    @Environment(\.dismiss) private var dismiss
    @State private var scope = RepositoryQueryScope.all
    @State private var query = ""
    @State private var field = HistorySearchField.message
    @State private var results: [RepositoryQueryResult] = []
    @State private var anchor: RepositoryQueryAnchor?
    @State private var cursor: RepositoryQueryCursor?
    @State private var loading = false
    @State private var error: String?
    @State private var selected: String?
    @State private var readID = UUID()
    @State private var nextTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var readKey: String {
        "\(scope.rawValue):\(field.rawValue):\(query):\(request.session.historyGeneration):\(request.session.generation):\(L10n.language.rawValue)"
    }
    private var selectedResult: RepositoryQueryResult? { results.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetTitle(title: L10n.text("搜索 \(request.session.location.name)"), symbol: "magnifyingglass")
            HStack(spacing: 10) {
                Picker(L10n.text("搜索范围"), selection: $scope) {
                    ForEach(RepositoryQueryScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 140).accessibilityIdentifier("repository-search-scope")
                WorkbenchSearchField(
                    prompt: L10n.text("输入名称、路径或命令"), text: $query,
                    identifier: "repository-search-query", focus: $searchFocused
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
                if scope == .commits || scope == .all {
                    Picker(L10n.text("提交字段"), selection: $field) {
                        ForEach(HistorySearchField.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 105).accessibilityIdentifier("repository-search-field")
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(colors.negative) }
            List(selection: $selected) {
                ForEach(results) { result in
                    HStack(spacing: 12) {
                        Image(systemName: symbol(result)).frame(width: 20).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.title).lineLimit(1).truncationMode(.middle)
                            if !result.detail.isEmpty {
                                Text(result.detail).font(.caption).foregroundStyle(
                                    selected == result.id ? colors.selectionText : colors.secondaryText
                                )
                                .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 12)
                        if scope == .all {
                            Text(result.scope.title).font(.caption).foregroundStyle(
                                selected == result.id ? colors.selectionText : colors.secondaryText)
                        }
                    }
                    .foregroundStyle(
                        selected == result.id
                            ? colors.selectionText : result.enabled ? colors.text : colors.secondaryText
                    )
                    .accessibilityIdentifier("repository-search-result:" + result.id)
                    .padding(.vertical, 3).tag(result.id).contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        selected = result.id
                        openSelected()
                    }
                }
            }.overlay {
                if results.isEmpty && !loading && error == nil {
                    Text(L10n.text("没有匹配结果")).foregroundStyle(colors.secondaryText)
                }
            }.accessibilityIdentifier("repository-search-results")
            HStack(spacing: 12) {
                if loading { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("搜索中")) }
                Text(L10n.text("\(results.count) 项结果")).font(.caption).foregroundStyle(colors.secondaryText)
                if cursor != nil {
                    Button(L10n.text("加载更多")) { loadNext() }.disabled(loading)
                        .accessibilityIdentifier("repository-search-more")
                }
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("打开结果")) { openSelected() }.keyboardShortcut(.defaultAction)
                    .disabled(selectedResult?.enabled != true || app.session !== request.session)
            }
        }.padding(22).frame(width: 720, height: 520)
            .task { searchFocused = true }
            .task(id: readKey) { await search() }
            .onChange(of: results.map(\.id)) { _, ids in
                if !ids.contains(selected ?? "") {
                    selected = results.first(where: \.enabled)?.id ?? ids.first
                }
            }
            .onDisappear { nextTask?.cancel() }
    }

    private func search() async {
        nextTask?.cancel()
        let current = UUID()
        readID = current
        anchor = nil
        cursor = nil
        results = []
        error = nil
        loading = true
        do {
            try await Task.sleep(for: .milliseconds(180))
            let commands = app.commands.map {
                RepositoryQueryCommand(
                    id: $0.id, title: $0.title, symbol: $0.symbol, enabled: $0.enabled,
                    reason: $0.reason, shortcut: $0.shortcut)
            }
            let value = try await request.session.service.repositoryQueryAnchor(
                scope: scope, query: query, commitField: field, commands: commands)
            let page = try await request.session.service.repositoryQueryPage(value)
            try Task.checkCancellation()
            guard readID == current else { return }
            anchor = value
            results = page.results
            cursor = page.next
            loading = false
        } catch {
            if !Task.isCancelled && readID == current {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    private func loadNext() {
        guard !loading, let anchor, let cursor else { return }
        let current = readID
        loading = true
        error = nil
        nextTask = Task {
            do {
                let page = try await request.session.service.repositoryQueryPage(anchor, after: cursor)
                try Task.checkCancellation()
                guard current == readID else { return }
                results += page.results
                self.cursor = page.next
                loading = false
            } catch {
                if !Task.isCancelled && current == readID {
                    self.error = error.localizedDescription
                    loading = false
                }
            }
        }
    }

    private func symbol(_ result: RepositoryQueryResult) -> String {
        switch result {
        case .commit: "clock.arrow.circlepath"
        case .trackedPath: "doc"
        case .branch: "arrow.triangle.branch"
        case .tag: "tag"
        case .stash: "archivebox"
        case .worktree: "folder"
        case .command(let command): command.symbol
        }
    }

    private func move(_ step: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selected } ?? 0
        selected = results[min(max(index + step, 0), results.count - 1)].id
    }

    private func openSelected() {
        guard app.session === request.session, let result = selectedResult, result.enabled else { return }
        if let openResult = request.openResult {
            openResult(result)
        } else {
            switch result {
            case .commit(let commit):
                app.historyState(for: request.session).searchField = .sha
                app.historyState(for: request.session).query = commit.id
                app.workspace.route = .history
            case .branch(let branch):
                app.workspace.route = .branches
                app.workspace.branchFilter = branch.name
            case .trackedPath(let path):
                app.workspace.route = .changes
                app.workspace.filter = path
            case .tag: app.workspace.route = .tags
            case .stash: app.workspace.route = .stashes
            case .worktree, .command: return
            }
        }
        dismiss()
    }
}
