import SwiftUI
import WeGitCore

private struct RemoteEditorRequest: Identifiable {
    let id = UUID()
    let snapshot: RemoteManagementSnapshot
    let remote: ManagedRemote?
}
private struct RemoteRemovalRequest: Identifiable {
    let id = UUID()
    let snapshot: RemoteManagementSnapshot
    let remote: ManagedRemote
    let head: String?
}

struct RemoteManagementSheet: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: RemoteManagementSnapshot?
    @State private var selection: String?
    @State private var error: String?
    @State private var editor: RemoteEditorRequest?
    @State private var removal: RemoteRemovalRequest?
    @State private var reload = UUID()
    private var selected: ManagedRemote? { snapshot?.remotes.first { $0.name == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("远端管理"), symbol: "network")
            HSplitView {
                List(snapshot?.remotes ?? [], selection: $selection) { remote in
                    Text(remote.name).tag(remote.name).accessibilityIdentifier(
                        "managed-remote:" + remote.name)
                }.frame(minWidth: 160, idealWidth: 180, maxWidth: 220).accessibilityIdentifier(
                    "managed-remotes")
                ScrollView {
                    if let remote = selected {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(remote.name).font(.headline)
                            LabeledContent(L10n.text("获取地址")) {
                                Text(remote.displayFetchURLs.joined(separator: "\n")).textSelection(.enabled)
                                    .accessibilityValue(remote.displayFetchURLs.joined(separator: "\n"))
                                    .accessibilityIdentifier("remote-fetch-value")
                            }
                            LabeledContent(L10n.text("推送地址")) {
                                Text(remote.displayPushURLs.joined(separator: "\n")).textSelection(.enabled)
                                    .accessibilityValue(remote.displayPushURLs.joined(separator: "\n"))
                                    .accessibilityIdentifier("remote-push-value")
                            }
                            if !remote.upstreamBranches.isEmpty {
                                LabeledContent(L10n.text("关联分支")) {
                                    Text(remote.upstreamBranches.joined(separator: ", "))
                                }
                            }
                            if !remote.canEdit {
                                Text(L10n.text("多地址、继承或包含凭据的配置仅供查看，请在 Terminal 中修改。"))
                                    .font(.callout).foregroundStyle(colors.secondaryText)
                            }
                            DisclosureGroup(L10n.text("配置来源")) {
                                ForEach(Array(remote.values.enumerated()), id: \.offset) { _, value in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(value.key + " = " + value.displayValue).textSelection(.enabled)
                                        Text(value.scope + " · " + value.origin).font(.caption)
                                            .foregroundStyle(colors.secondaryText)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            Button(L10n.text("在 Terminal 中打开"), action: app.openTerminal)
                        }.padding(12)
                    } else {
                        Text(L10n.text("选择或添加远端")).foregroundStyle(colors.secondaryText).padding(24)
                    }
                }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }.frame(height: 300)
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if let error = session.error {
                Text(error).foregroundStyle(colors.negative).textSelection(.enabled)
            }
            HStack {
                Button(L10n.text("新增远端…")) {
                    if let snapshot { editor = RemoteEditorRequest(snapshot: snapshot, remote: nil) }
                }.disabled(snapshot == nil || !session.canWrite).accessibilityIdentifier("remote-add")
                Button(L10n.text("编辑…")) {
                    if let snapshot, let selected {
                        editor = RemoteEditorRequest(snapshot: snapshot, remote: selected)
                    }
                }.disabled(!session.canWrite || selected?.canEdit != true).accessibilityIdentifier(
                    "remote-edit")
                Button(L10n.text("删除…"), role: .destructive) {
                    if let snapshot, let selected {
                        removal = RemoteRemovalRequest(
                            snapshot: snapshot, remote: selected, head: session.status.head)
                    }
                }.disabled(!session.canWrite || selected?.canDelete != true).accessibilityIdentifier(
                    "remote-delete"
                )
                .help(selected?.canDelete == false ? L10n.text("继承或复杂配置请在 Terminal 中修改。") : L10n.text("删除远端"))
                Button(L10n.text("刷新")) { reload = UUID() }.disabled(session.isBusy)
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(session.isBusy)
            }.workbenchControlFamily()
        }.padding(24).frame(width: 760).interactiveDismissDisabled(session.isBusy)
            .task(id: "\(session.statusRenderID):\(reload)") { await read() }
            .sheet(item: $editor) { request in
                RemoteEditorSheet(app: app, session: session, request: request).workbenchSheet(
                    app.preferences)
            }
            .alert(
                L10n.text("删除远端配置？"),
                isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                presenting: removal
            ) { request in
                Button(L10n.text("取消"), role: .cancel) { removal = nil }
                Button(L10n.text("删除"), role: .destructive) {
                    removal = nil
                    guard app.session === session else { return }
                    session.perform(L10n.text("删除远端")) {
                        try await $0.changeRemote(
                            .remove(name: request.remote.name), in: request.snapshot,
                            expectedHead: request.head)
                    }
                }.accessibilityIdentifier("remote-delete-confirm")
            } message: { request in
                Text(
                    request.remote.name + "\n" + request.remote.upstreamBranches.joined(separator: ", ")
                        + "\n" + L10n.text("关联分支将失去此远端配置；本地跟踪引用和工作区文件仍保留。"))
            }
    }
    private func read() async {
        do {
            let value = try await session.service.remoteManagement()
            guard !Task.isCancelled else { return }
            snapshot = value
            error = nil
            if !value.remotes.contains(where: { $0.name == selection }) {
                selection = value.remotes.first?.name
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

private struct RemoteEditorSheet: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    let request: RemoteEditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var fetch: String
    @State private var push: String
    @State private var separatePush: Bool
    @State private var attempted = false
    init(app: AppState, session: RepositorySession, request: RemoteEditorRequest) {
        self.app = app
        self.session = session
        self.request = request
        _name = State(initialValue: request.remote?.name ?? "")
        _fetch = State(initialValue: request.remote?.fetchURLs.first ?? "")
        _push = State(initialValue: request.remote?.pushURLs.first ?? "")
        _separatePush = State(initialValue: request.remote?.pushURLs.isEmpty == false)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(
                title: request.remote == nil ? L10n.text("新增远端") : L10n.text("编辑远端"), symbol: "network")
            Form {
                TextField(L10n.text("名称"), text: $name).disabled(request.remote != nil)
                    .accessibilityIdentifier("remote-name")
                TextField(L10n.text("获取地址"), text: $fetch).accessibilityIdentifier("remote-fetch-url")
                Toggle(L10n.text("使用独立推送地址"), isOn: $separatePush).accessibilityIdentifier(
                    "remote-separate-push")
                if separatePush {
                    TextField(L10n.text("推送地址"), text: $push).accessibilityIdentifier("remote-push-url")
                }
            }.textFieldStyle(.roundedBorder).disabled(session.isBusy)
            if attempted, let error = session.error {
                Text(error).foregroundStyle(colors.negative).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : L10n.text("取消")) {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button(L10n.text("保存")) { save() }.keyboardShortcut(.defaultAction)
                    .disabled(
                        !session.canWrite || name.isEmpty || fetch.isEmpty || (separatePush && push.isEmpty)
                    )
                    .accessibilityIdentifier("remote-save")
            }.workbenchControlFamily()
        }.padding(24).frame(width: 560).interactiveDismissDisabled(session.isBusy)
    }
    private func save() {
        guard app.session === session else { return }
        attempted = true
        let change: RemoteChange =
            request.remote == nil
            ? .add(name: name, fetchURL: fetch, pushURL: separatePush ? push : nil)
            : .update(name: name, fetchURL: fetch, pushURL: separatePush ? push : nil)
        let snapshot = request.snapshot
        let head = session.status.head
        session.perform(
            L10n.text("保存远端配置"), onSuccess: { dismiss() },
            operation: {
                try await $0.changeRemote(change, in: snapshot, expectedHead: head)
            })
    }
}
