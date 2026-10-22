import SwiftUI
import WeGitCore

struct FileHistoryRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let path: String
    var tip: String?
}

private struct FileHistoryReadKey: Equatable {
    let query: FileHistoryQuery
    let reload: UUID
}

struct FileHistorySheet: View {
    let app: AppState
    let request: FileHistoryRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors
    @State private var state: FileHistoryState
    @State private var path: String
    @State private var author = ""
    @State private var message = ""
    @State private var follow = true
    @State private var dateRange = false
    @State private var since = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    @State private var until = Date()
    @State private var reload = UUID()
    private var query: FileHistoryQuery {
        FileHistoryQuery(
            path: path, followRenames: follow, author: author, message: message,
            since: dateRange ? Calendar.current.startOfDay(for: since) : nil,
            until: dateRange
                ? Calendar.current.date(
                    byAdding: .second, value: -1,
                    to: Calendar.current.date(
                        byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: until))!) : nil)
    }
    init(app: AppState, request: FileHistoryRequest) {
        self.app = app
        self.request = request
        _path = State(initialValue: request.path)
        _state = State(initialValue: FileHistoryState(service: request.session.service))
    }
    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SheetTitle(title: L10n.text("文件历史"), symbol: "doc.text.magnifyingglass")
                Spacer()
                if state.loading {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("取消读取")) { state.cancel(userInitiated: true) }
                }
                Button(L10n.text("刷新")) { reload = UUID() }.disabled(state.loading || path.isEmpty)
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("file-history-close")
            }
            HStack {
                TextField(L10n.text("仓库相对路径"), text: $path).accessibilityLabel(L10n.text("仓库相对路径"))
                    .accessibilityIdentifier("file-history-path")
                Toggle(L10n.text("跟随重命名"), isOn: $follow).fixedSize().accessibilityIdentifier(
                    "file-history-follow")
            }
            HStack {
                TextField(L10n.text("作者或邮箱"), text: $author).accessibilityLabel(L10n.text("作者或邮箱"))
                    .accessibilityIdentifier("file-history-author")
                TextField(L10n.text("提交消息"), text: $message).accessibilityLabel(L10n.text("提交消息"))
                    .accessibilityIdentifier("file-history-message")
                Toggle(L10n.text("提交时间范围"), isOn: $dateRange).fixedSize().accessibilityIdentifier(
                    "file-history-dates")
            }
            if dateRange {
                HStack {
                    DatePicker(L10n.text("开始"), selection: $since, displayedComponents: .date)
                    DatePicker(L10n.text("结束"), selection: $until, displayedComponents: .date)
                    Spacer()
                }
            }
            HSplitView {
                VStack(spacing: 0) {
                    List(state.entries, selection: $state.selection) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.commit.subject).lineLimit(2)
                            HStack {
                                Text(entry.commit.author).lineLimit(1)
                                Spacer()
                                Text(entry.commit.committedAt, style: .date)
                            }.font(.caption).foregroundStyle(colors.secondaryText)
                        }.tag(entry.id).accessibilityElement(children: .ignore)
                            .accessibilityLabel(entry.commit.subject)
                            .accessibilityValue(entry.commit.author + " · " + entry.commit.id)
                            .accessibilityIdentifier("file-history-commit:" + entry.id)
                    }.accessibilityIdentifier("file-history-list")
                    if let error = state.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled).padding(10)
                        Button(L10n.text("重试")) {
                            if state.hasMore { state.loadMore() } else { reload = UUID() }
                        }.padding(8)
                    } else if !state.loading, state.entries.isEmpty {
                        Text(
                            state.cancelled
                                ? L10n.text("已取消读取")
                                : path.isEmpty ? L10n.text("输入单个文件的相对路径") : L10n.text("没有匹配的文件历史")
                        )
                        .foregroundStyle(colors.secondaryText).padding(12)
                    }
                    if state.hasMore {
                        Button(L10n.text("加载更多提交")) { state.loadMore() }.disabled(state.loading)
                            .padding(10).accessibilityIdentifier("file-history-load-more")
                    }
                }.frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                VStack(alignment: .leading, spacing: 0) {
                    if let entry = state.selected {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.commit.subject).font(.headline)
                            Text(entry.oldPath.map { $0 + " → " + entry.path } ?? entry.path)
                                .textSelection(.enabled).font(.caption.monospaced())
                            Text(entry.commit.id).font(.caption.monospaced()).textSelection(.enabled)
                            if entry.commit.parents.count > 1 {
                                Text(L10n.text("Merge · 相对于第一父提交")).font(.caption).foregroundStyle(
                                    colors.secondaryText)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
                            colors.chrome)
                        Divider()
                        CommitFilesView(
                            app: app, session: request.session, detail: state.detail, allowsFileHistory: false
                        )
                    } else {
                        Text(L10n.text("选择一次提交")).foregroundStyle(colors.secondaryText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if let tip = state.anchor?.tip {
                    Text(L10n.text("起点提交") + " · " + tip.prefix(12)).font(.caption.monospaced())
                }
                Spacer()
                Text(L10n.text("重命名由 Git 检测；未追踪复制关系。")).font(.caption).foregroundStyle(colors.secondaryText)
            }
        }.textFieldStyle(.roundedBorder).padding(20).frame(width: 1080, height: 680).workbenchControlFamily()
            .task(id: FileHistoryReadKey(query: query, reload: reload)) {
                await state.reload(query, tip: request.tip)
            }
            .task(id: state.selection) {
                if let entry = state.selected {
                    await state.detail.select(
                        entry.commit, parent: entry.commit.parents.first,
                        paths: [entry.oldPath, entry.path].compactMap { $0 })
                } else {
                    state.detail.releaseCache()
                }
            }
            .onDisappear { state.release() }
            .onChange(of: app.session?.id) { _, _ in
                if app.session !== request.session {
                    state.release()
                    dismiss()
                }
            }
    }
}
