import SwiftUI
import WeGitCore

struct TagCreationSheet: View {
    @Environment(\.themeColors) private var colors
    let app: AppState
    let request: TagCreationRequest
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = TagKind.lightweight
    @State private var message = ""
    @State private var signing: Bool?
    @State private var error: String?
    @State private var attempted = false
    private var session: RepositorySession { request.session }
    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("创建标签"), symbol: "tag")
            Text(request.target).font(.caption.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("tag-create-target")
            Form {
                TextField(L10n.text("名称"), text: $name).accessibilityIdentifier("tag-name")
                Picker(L10n.text("类型"), selection: $kind) {
                    ForEach(TagKind.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("tag-kind").disabled(signing == true)
                if kind == .annotated {
                    LabeledContent(L10n.text("附注")) {
                        TextEditor(text: $message).frame(height: 100).accessibilityIdentifier("tag-message")
                    }
                }
            }.textFieldStyle(.roundedBorder).disabled(session.isBusy)
            if signing == true { Text(L10n.text("沿用当前 Git 配置签名")).foregroundStyle(colors.secondaryText) }
            if let error { Text(error).foregroundStyle(colors.negative) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel,
                    result: session.operationFeedback, context: session.operationFeedbackContext, fallback: ""
                )
            }
            HStack {
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : L10n.text("取消")) {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button(L10n.text("创建")) { create() }.keyboardShortcut(.defaultAction)
                    .disabled(
                        signing == nil || !session.canWrite || name.isEmpty
                            || (kind == .annotated
                                && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                    .accessibilityIdentifier("tag-save")
            }.workbenchControlFamily()
        }.padding(24).frame(width: 560).interactiveDismissDisabled(session.isBusy)
            .task {
                do {
                    let required = try await session.service.tagSigningRequired()
                    guard !Task.isCancelled else { return }
                    signing = required
                    if required { kind = .annotated }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
    }
    private func create() {
        guard app.session === session else { return }
        attempted = true
        let name = name
        let kind = kind
        let message = message
        let target = request.target
        let head = session.status.head
        session.perform(
            L10n.text("创建标签"), onSuccess: { dismiss() },
            operation: {
                let plan = try await $0.prepareTagCreation(
                    name: name, target: target, kind: kind, message: message, expectedHead: head)
                _ = try await $0.createTag(plan)
            })
    }
}

struct TagPushSheet: View {
    @Environment(\.themeColors) private var colors
    let app: AppState
    @Bindable var session: RepositorySession
    let tag: GitTag
    @Environment(\.dismiss) private var dismiss
    @State private var remotes: [GitRemote] = []
    @State private var remote = ""
    @State private var endpoint = 0
    @State private var plan: TagPushPlan?
    @State private var error: String?
    @State private var preparing = false
    @State private var attempted = false
    @State private var prepareTask: Task<Void, Never>?
    private var selected: GitRemote? { remotes.first { $0.name == remote } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("推送标签"), symbol: "tag")
            Text(tag.name).font(.headline)
            Text(tag.objectID).font(.caption.monospaced()).textSelection(.enabled)
            if let plan {
                Text(plan.tag.reference).font(.body.monospaced())
                LabeledContent(plan.remote.name) {
                    Text(plan.remote.displayPushURLs[plan.pushURLIndex]).textSelection(.enabled)
                }
            } else {
                Form {
                    Picker(L10n.text("远端"), selection: $remote) {
                        ForEach(remotes) { Text($0.name).tag($0.name) }
                    }.accessibilityIdentifier("tag-push-remote")
                    if let selected {
                        Picker(L10n.text("推送地址"), selection: $endpoint) {
                            ForEach(Array(selected.displayPushURLs.enumerated()), id: \.offset) {
                                index, url in Text(url).tag(index)
                            }
                        }.accessibilityIdentifier("tag-push-endpoint")
                    }
                }.disabled(preparing)
            }
            if preparing { ProgressView(L10n.text("核对远端标签…")) }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel,
                    result: session.operationFeedback, context: session.operationFeedbackContext, fallback: ""
                )
            }
            HStack {
                if plan != nil { Button(L10n.text("返回")) { plan = nil }.disabled(session.isBusy) }
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : L10n.text("取消")) {
                    prepareTask?.cancel()
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button(plan == nil ? L10n.text("下一步") : L10n.text("推送")) {
                    if let plan { push(plan) } else { prepare() }
                }.keyboardShortcut(.defaultAction).disabled(
                    !session.canWrite || preparing || selected == nil || session.pendingTagPush != nil
                )
                .accessibilityIdentifier("tag-push-confirm")
            }.workbenchControlFamily()
        }.padding(24).frame(width: 600).interactiveDismissDisabled(session.isBusy)
            .task {
                do {
                    let values = try await session.service.remoteDetails()
                    guard !Task.isCancelled else { return }
                    remotes = values
                    remote = values.first?.name ?? ""
                    if values.isEmpty { error = L10n.text("尚未配置远端，请先添加 Remote") }
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .onChange(of: remote) { _, _ in endpoint = 0 }
            .onDisappear { prepareTask?.cancel() }
    }
    private func prepare() {
        guard app.session === session else { return }
        let name = remote
        let index = endpoint
        let head = session.status.head
        preparing = true
        error = nil
        prepareTask = Task {
            defer { preparing = false }
            do {
                let value = try await session.service.prepareTagPush(
                    tag, remote: name, pushURLIndex: index, expectedHead: head)
                guard !Task.isCancelled, app.session === session else { return }
                plan = value
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func push(_ plan: TagPushPlan) {
        guard app.session === session else { return }
        let session = session
        attempted = true
        session.perform(
            L10n.text("推送标签"), onSuccess: { dismiss() },
            operation: { service in
                do { _ = try await service.pushTag(plan) } catch let unknown as TagPushOutcomeUnknown {
                    await MainActor.run {
                        session.pendingTagPush = unknown.plan
                        session.tagPushFeedback = .from(unknown)
                    }
                    throw unknown
                }
            })
    }
}
