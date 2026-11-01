import AppKit
import SwiftUI
import WeGitCore

struct NewBranchView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    var startCommit: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var switchAfterCreation = true
    @State private var startingRef = ""
    @State private var trackRemote = true
    @State private var attempted = false
    private let targetLocation: RepositoryLocation?

    init(app: AppState, startCommit: String? = nil) {
        self.app = app
        self.startCommit = startCommit
        targetLocation = app.session?.location
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetTitle(title: L10n.text("新建分支"), symbol: "arrow.triangle.branch")
            Text(startCommit == nil ? L10n.text("从当前提交创建新分支。") : L10n.text("从所选历史提交创建新分支。")).foregroundStyle(
                colors.secondaryText)
            TextField(L10n.text("分支名称"), text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier(
                "branch-name"
            ).disabled(app.session?.isBusy == true)
            if startCommit == nil {
                Picker(L10n.text("起点"), selection: $startingRef) {
                    Text(L10n.text("当前 HEAD")).tag("")
                    ForEach(app.session?.branches.filter { $0.symbolicTarget == nil } ?? []) { branch in
                        Text("\(branch.name) · \(branch.oid.prefix(7))").tag(branch.id)
                    }
                }.disabled(app.session?.isBusy == true).accessibilityIdentifier("branch-start")
                if app.session?.branches.first(where: { $0.id == startingRef })?.remote == true {
                    Toggle(L10n.text("跟踪所选远端分支"), isOn: $trackRemote).toggleStyle(.checkbox).disabled(
                        app.session?.isBusy == true)
                }
            }
            Text(
                L10n.text(
                    "起点：\(startCommit.map { String($0.prefix(12)) } ?? app.session?.status.displayBranch ?? "")"
                )
            )
            .font(.caption).foregroundStyle(colors.secondaryText)
            Toggle(L10n.text("创建后立即切换"), isOn: $switchAfterCreation).toggleStyle(.checkbox).disabled(
                app.session?.isBusy == true)
            if attempted, let error = app.session?.error {
                Text(error).font(.callout).foregroundStyle(colors.negative)
            }
            HStack {
                Spacer()
                Button(app.session?.isBusy == true ? L10n.text("取消操作") : L10n.text("取消")) {
                    if app.session?.isBusy == true { app.session?.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button(switchAfterCreation ? L10n.text("创建并切换") : L10n.text("创建分支")) {
                    guard let session = app.session, session.location == targetLocation else {
                        app.error = ModelFailure.repositoryReplaced.localizedDescription
                        return
                    }
                    let name = name
                    let head = session.status.head
                    let source = session.branches.first { $0.id == startingRef }
                    guard startCommit != nil || startingRef.isEmpty || source != nil else {
                        session.show(ModelFailure.changed)
                        attempted = true
                        return
                    }
                    let start = startCommit ?? source?.oid
                    let switchTo = switchAfterCreation
                    attempted = true
                    if startCommit == nil, let source, source.remote && trackRemote {
                        session.perform(L10n.text("创建跟踪分支"), onSuccess: { dismiss() }) {
                            try await $0.createTrackingBranch(
                                from: source, name: name, switchTo: switchTo, expectedHead: head)
                        }
                    } else {
                        session.perform(L10n.text("创建分支"), onSuccess: { dismiss() }) {
                            try await $0.createBranch(
                                name, start: start, switchTo: switchTo, expectedHead: head)
                        }
                    }
                }.workbenchPrimaryAction().tint(colors.primaryAction).disabled(
                    name.isEmpty || app.session?.isBusy == true)
            }
        }.padding(24).frame(width: 460).interactiveDismissDisabled(app.session?.isBusy == true)
    }
}

enum RepositoryPickerAction {
    case open(URL)
    case browse, clone
}

struct RepositoryPicker: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedPath: String?
    @FocusState private var searchFocused: Bool
    private var records: [RecentRepository] {
        app.recents.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.localizedCaseInsensitiveContains(query)
        }.sorted { $0.pinned && !$1.pinned }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle(title: L10n.text("切换仓库"), symbol: "folder")
            WorkbenchSearchField(
                prompt: L10n.text("搜索仓库名称或路径"), text: $query, identifier: "repository-switch-search",
                focus: $searchFocused
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
            List(selection: $selectedPath) {
                ForEach(records) { record in
                    Button {
                        selectedPath = record.path
                        openSelected()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name)
                            Text(record.path).font(.caption).foregroundStyle(colors.secondaryText)
                                .lineLimit(2).truncationMode(.middle).help(record.path)
                        }
                    }.buttonStyle(.plain).padding(.vertical, 6).tag(record.path)
                        .accessibilityIdentifier("repository:" + record.path)
                        .contextMenu { RepositoryContextMenu(app: app, record: record) }
                }
            }.frame(height: 230).accessibilityLabel(L10n.text("匹配的最近仓库"))
            HStack {
                Button(L10n.text("打开仓库…")) { app.dismissRepositoryPicker(perform: .browse) }
                Button(L10n.text("克隆仓库…")) { app.dismissRepositoryPicker(perform: .clone) }
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("打开所选仓库")) { openSelected() }.keyboardShortcut(.defaultAction)
                    .disabled(selectedPath == nil).accessibilityIdentifier("repository-switch-open")
            }
        }.padding(22).frame(width: 550)
            .task {
                selectedPath = records.first?.path
                searchFocused = true
            }
            .onChange(of: query) { _, _ in selectedPath = records.first?.path }
    }

    private func move(_ step: Int) {
        guard !records.isEmpty else { return }
        let index = records.firstIndex { $0.path == selectedPath } ?? 0
        selectedPath = records[min(max(index + step, 0), records.count - 1)].path
    }

    private func openSelected() {
        guard let selectedPath, records.contains(where: { $0.path == selectedPath }) else { return }
        app.dismissRepositoryPicker(perform: .open(URL(fileURLWithPath: selectedPath)))
    }
}

struct ActivityView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [GitActivity] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SheetTitle(title: L10n.text("Git 活动"), symbol: "clock")
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L10n.text("仅记录脱敏命令摘要，不保存代码、补丁、提交消息或凭证。")).font(.caption).foregroundStyle(
                colors.secondaryText)
            List(entries) { entry in
                HStack {
                    Image(
                        systemName: entry.state == .succeeded ? "checkmark.circle" : "exclamationmark.circle"
                    )
                    .foregroundStyle(entry.state == .succeeded ? colors.positive : colors.modified)
                    Text(entry.command).monospaced()
                    if let repository = entry.repository {
                        Text(repository.lastPathComponent).lineLimit(1).help(repository.path)
                    } else {
                        Text(L10n.text("系统 Git")).foregroundStyle(colors.secondaryText)
                    }
                    Text(entry.state.title).foregroundStyle(colors.secondaryText)
                    Spacer()
                    Text(entry.date, style: .time)
                    Text(String(format: "%.0f ms", entry.duration * 1000)).monospacedDigit().frame(
                        width: 75, alignment: .trailing)
                }.font(.caption).padding(.vertical, 5)
            }
        }.padding(22).frame(width: 640, height: 440).task { entries = await app.engine.activity.all() }
    }
}
