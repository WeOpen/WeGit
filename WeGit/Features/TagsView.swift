import SwiftUI
import WeGitCore

struct TagCreationRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let target: String
}

private struct TagDeletionRequest: Identifiable {
    let id = UUID()
    let tag: GitTag
    let head: String?
}

struct TagsView: View {
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @Environment(\.themeColors) private var colors
    @State private var query = ""
    @State private var limit = 200
    @State private var entries: [GitTag] = []
    @State private var hasMore = false
    @State private var selection: String?
    @State private var loading = false
    @State private var error: String?
    @State private var reload = UUID()
    @State private var deletion: TagDeletionRequest?
    @State private var pushing: GitTag?
    private var selected: GitTag? { entries.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            if let pending = session.pendingTagPush {
                HStack {
                    OperationFeedback(
                        busy: session.isBusy, activity: session.activityLabel,
                        result: session.tagPushFeedback
                            ?? .needsReview(
                                message: L10n.text("标签推送结果尚未确认"), details: pending.feedbackTargetDetails),
                        fallback: "")
                    Text(pending.tag.name).font(.body.monospaced()).textSelection(.enabled)
                        .help(pending.feedbackTargetDetails)
                        .accessibilityValue(pending.feedbackTargetDetails)
                        .accessibilityIdentifier("tag-push-target")
                    Spacer()
                    Button(L10n.text("核对远端")) { verify(pending) }.disabled(!session.canWrite)
                        .accessibilityIdentifier("tag-verify-push")
                    Button(L10n.text("关闭提示")) {
                        session.pendingTagPush = nil
                        session.tagPushFeedback = nil
                    }.disabled(session.isBusy).accessibilityIdentifier("tag-dismiss-push-notice")
                }.padding(12).background(colors.chrome).accessibilityIdentifier("tag-push-pending")
            }
            HSplitView {
                VStack(spacing: 0) {
                    PanelHeader(title: L10n.text("标签"), symbol: "tag") {
                        Spacer()
                        Button(L10n.text("创建标签…"), systemImage: "plus") {
                            if let head = session.status.head {
                                app.tagCreationRequest = TagCreationRequest(session: session, target: head)
                            }
                        }.disabled(!session.canWrite || session.status.head == nil)
                            .accessibilityIdentifier("tag-create")
                    }
                    WorkbenchSearchField(prompt: L10n.text("搜索标签名称"), text: $query, identifier: "tag-search")
                        .padding(12)
                    List(entries, selection: $selection) { tag in
                        HStack {
                            Image(systemName: "tag").foregroundStyle(colors.tone(.violet))
                            Text(tag.name).lineLimit(1)
                            Spacer()
                            Text(String((tag.targetCommit ?? tag.objectID).prefix(7))).font(
                                .caption.monospaced()
                            )
                            .foregroundStyle(colors.secondaryText)
                        }.tag(tag.id).accessibilityIdentifier("tag-row:" + tag.name)
                    }.scrollContentBackground(.hidden).background(colors.canvas)
                        .accessibilityIdentifier("tag-list")
                    HStack {
                        if loading { ProgressView().controlSize(.small) }
                        if hasMore {
                            Button(L10n.text("加载更多")) { limit = min(10_000, limit + 200) }
                                .disabled(loading || limit >= 10_000).accessibilityIdentifier("tag-load-more")
                        }
                        Spacer()
                        Button(L10n.text("刷新")) { reload = UUID() }.disabled(loading)
                    }.padding(10)
                    if let error {
                        Text(error).foregroundStyle(colors.negative).padding(12).textSelection(.enabled)
                    }
                    if !loading, entries.isEmpty, error == nil {
                        Text(query.isEmpty ? L10n.text("暂无标签") : L10n.text("没有匹配标签"))
                            .foregroundStyle(colors.secondaryText).padding(12)
                    }
                }.frame(minWidth: 260, idealWidth: 330, maxWidth: 380)
                VStack(spacing: 0) {
                    if let tag = selected {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(tag.name).font(.title3.weight(.semibold)).lineLimit(2).textSelection(
                                    .enabled)
                                Spacer()
                                Button(L10n.text("推送标签…")) { pushing = tag }
                                    .disabled(
                                        !session.canWrite || tag.targetCommit == nil
                                            || tag.symbolicTarget != nil || session.pendingTagPush != nil
                                    )
                                    .accessibilityIdentifier("tag-push")
                                Button(L10n.text("删除本地标签…"), role: .destructive) {
                                    deletion = TagDeletionRequest(tag: tag, head: session.status.head)
                                }.disabled(!session.canWrite || tag.symbolicTarget != nil)
                                    .accessibilityIdentifier("tag-delete")
                            }
                            Text(tag.annotated ? L10n.text("附注标签") : L10n.text("轻量标签"))
                                .foregroundStyle(colors.secondaryText)
                            if tag.annotated {
                                LabeledContent(L10n.text("标签对象")) {
                                    Text(tag.objectID).font(.caption.monospaced()).textSelection(.enabled)
                                }
                            }
                            if let target = tag.targetCommit {
                                HStack {
                                    Text(L10n.text("目标提交"))
                                    Spacer()
                                    Text(target).font(.caption.monospaced()).textSelection(.enabled)
                                }.accessibilityElement(children: .ignore)
                                    .accessibilityLabel(L10n.text("目标提交") + ": " + target)
                                    .accessibilityIdentifier("tag-target")
                            }
                            if tag.symbolicTarget != nil {
                                Text(L10n.text("符号引用标签仅供查看，请在 Git 中处理。"))
                            }
                        }.padding(16).background(colors.chrome)
                        Divider()
                        TagDetailView(app: app, session: session, tag: tag).id(
                            tag.id + tag.objectID + (tag.symbolicTarget ?? ""))
                    } else {
                        EmptyPanel(title: L10n.text("选择一个标签"), symbol: "tag", message: "", artwork: .tally)
                    }
                }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            if session.pendingTagPush == nil, session.isBusy || session.operationFeedback != nil {
                Divider()
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel,
                    result: session.operationFeedback, context: session.operationFeedbackContext, fallback: ""
                ).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }.background(colors.canvas)
            .task(id: "\(query):\(limit):\(session.historyGeneration):\(reload)") { await read() }
            .onChange(of: query) { _, _ in limit = 200 }
            .sheet(item: $pushing) {
                TagPushSheet(app: app, session: session, tag: $0).workbenchSheet(app.preferences)
            }
            .alert(
                L10n.text("删除本地标签？"),
                isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
                presenting: deletion
            ) { request in
                Button(L10n.text("取消"), role: .cancel) { deletion = nil }
                Button(L10n.text("删除"), role: .destructive) {
                    deletion = nil
                    guard app.session === session else { return }
                    session.perform(L10n.text("删除本地标签")) {
                        try await $0.deleteTag(request.tag, expectedHead: request.head)
                    }
                }.accessibilityIdentifier("tag-delete-confirm")
            } message: { request in
                Text(
                    request.tag.name + "\n" + request.tag.objectID + "\n"
                        + L10n.text("只删除本地标签，远端标签和工作区文件保持原状。"))
            }
    }

    private func read() async {
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(200))
            let result = try await session.service.tags(query: query, limit: limit)
            guard !Task.isCancelled else { return }
            entries = result.entries
            hasMore = result.hasMore
            error = nil
            if !entries.contains(where: { $0.id == selection }) { selection = entries.first?.id }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func verify(_ plan: TagPushPlan) {
        guard app.session === session else { return }
        session.performResult(L10n.text("核对标签推送")) { service in
            let result = try await service.verifyTagPush(plan)
            let outcome: OperationFeedbackOutcome
            switch result {
            case .matches:
                outcome = .completed(message: L10n.text("已确认远端包含此标签对象"))
            case .absent:
                outcome = .needsReview(
                    message: L10n.text("远端尚无此标签，可关闭提示后重新确认推送"), details: plan.feedbackTargetDetails)
            case .different:
                outcome = .needsReview(
                    message: L10n.text("远端同名标签指向其他对象，未执行推送。"), details: plan.feedbackTargetDetails)
            }
            await MainActor.run {
                session.tagPushFeedback = outcome.feedback
            }
            return outcome
        }
    }
}

private struct TagDetailView: View {
    @Environment(\.themeColors) private var colors
    let app: AppState
    let session: RepositorySession
    let tag: GitTag
    @State private var detail: CommitDetailState
    @State private var annotation: String?
    @State private var messageError: String?
    @State private var commitError: String?
    @State private var commit: GitCommit?
    @State private var parent: String?
    init(app: AppState, session: RepositorySession, tag: GitTag) {
        self.app = app
        self.session = session
        self.tag = tag
        _detail = State(initialValue: CommitDetailState(service: session.service))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tag.annotated {
                DisclosureGroup(L10n.text("标签附注")) {
                    ScrollView {
                        Text(annotation ?? messageError ?? L10n.text("读取中…")).textSelection(.enabled).frame(
                            maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }.padding(12)
            }
            if tag.targetCommit != nil {
                if let commit {
                    Text(commit.subject).font(.headline).padding(.horizontal, 12).padding(.top, 12)
                    if commit.parents.count > 1 {
                        Picker(L10n.text("比较父提交"), selection: $parent) {
                            ForEach(Array(commit.parents.enumerated()), id: \.element) { index, oid in
                                Text(L10n.text("父提交 \(index + 1) · \(oid.prefix(7))")).tag(Optional(oid))
                            }
                        }.padding(12)
                    }
                }
                if let commitError { Text(commitError).foregroundStyle(colors.negative).padding(12) }
                CommitFilesView(app: app, session: session, detail: detail)
            } else {
                Text(L10n.text("此标签未指向提交对象")).padding(24)
            }
        }
        .task {
            do { annotation = try await session.service.tagMessage(tag) } catch {
                if !Task.isCancelled { messageError = error.localizedDescription }
            }
        }
        .task {
            guard let target = tag.targetCommit else { return }
            do {
                let commit = try await session.service.readCommit(target)
                try Task.checkCancellation()
                parent = commit.parents.first
                self.commit = commit
            } catch { if !Task.isCancelled { commitError = error.localizedDescription } }
        }
        .task(id: "\(commit?.id ?? ""):\(parent ?? "")") {
            await detail.select(commit, parent: parent)
        }
        .onDisappear { detail.releaseCache() }
    }
}
