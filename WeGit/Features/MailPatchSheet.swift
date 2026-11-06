import SwiftUI
import WeGitCore

struct MailPatchRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let sources: [MailPatchSource]
    var record: MailPatchRecord? = nil
}
struct MailPatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors
    let app: AppState
    let request: MailPatchRequest
    @State private var plan: MailPatchPlan?
    @State private var record: MailPatchRecord?
    @State private var loading = false
    @State private var attempted = false
    @State private var error: String?
    @State private var abortConfirmation = false
    @State private var reviewConfirmation = false
    private var session: RepositorySession { request.session }
    init(app: AppState, request: MailPatchRequest) {
        self.app = app
        self.request = request
        _record = State(initialValue: request.record)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("导入提交补丁"), symbol: "envelope")
            Text(session.location.name + " · " + (record?.branch ?? plan?.branch ?? session.status.branch))
                .font(.headline)
            if let record {
                Text(L10n.text("已处理 \(record.next) / \(record.entries.count) 个提交"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("已处理 \(record.next) / \(record.entries.count) 个提交"))
                    .accessibilityIdentifier("mail-patch-progress")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(record?.entries ?? plan?.entries ?? []) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top, spacing: 8) {
                                Group {
                                    if let body = item.body {
                                        DisclosureGroup {
                                            Text(body).font(.callout).textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .accessibilityElement(children: .ignore)
                                                .accessibilityLabel(body)
                                                .accessibilityIdentifier("mail-patch-message:\(item.number)")
                                        } label: {
                                            itemHeading(item)
                                        }.accessibilityElement(children: .contain)
                                            .accessibilityIdentifier("mail-patch-disclosure:\(item.number)")
                                    } else {
                                        itemHeading(item)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if record == nil, let plan {
                                    Button {
                                        move(item, by: -1)
                                    } label: {
                                        Image(systemName: "arrow.up")
                                    }
                                    .workbenchIconButton()
                                    .disabled(item.number == 1 || loading || session.isBusy)
                                    .accessibilityLabel(L10n.text("向前移动"))
                                    .accessibilityIdentifier("mail-patch-up:\(item.number)")
                                    Button {
                                        move(item, by: 1)
                                    } label: {
                                        Image(systemName: "arrow.down")
                                    }
                                    .workbenchIconButton()
                                    .disabled(item.number == plan.entries.count || loading || session.isBusy)
                                    .accessibilityLabel(L10n.text("向后移动"))
                                    .accessibilityIdentifier("mail-patch-down:\(item.number)")
                                }
                            }
                            Text(item.author + " <" + item.email + ">").font(.caption).foregroundStyle(
                                colors.secondaryText)
                            ForEach(item.paths, id: \.self) { Text($0).font(.caption.monospaced()) }
                        }.accessibilityElement(children: .contain)
                            .accessibilityValue(itemStatus(item) ?? "")
                            .accessibilityIdentifier("mail-patch-item:\(item.number)")
                    }
                }
            }.frame(maxHeight: 320)
            if loading || session.isBusy { ProgressView() }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if let details = record?.details {
                DisclosureGroup(L10n.text("查看详情")) {
                    ScrollView {
                        Text(details).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 140)
                }.accessibilityIdentifier("mail-patch-details")
            }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel, result: session.operationFeedback,
                    context: .standard, fallback: "")
            }
            HStack {
                if let record, record.phase.pending, record.nativeToken != nil {
                    Button(L10n.text("跳过本项")) { recover(record, action: "skip") }
                        .disabled(loading || session.isBusy)
                        .accessibilityIdentifier("mail-patch-skip")
                    Button(L10n.text("中止序列…"), role: .destructive) { abortConfirmation = true }.disabled(
                        loading || session.isBusy
                    )
                    .accessibilityIdentifier("mail-patch-abort")
                }
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : L10n.text("关闭")) {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                if let record {
                    if record.phase.pending {
                        if record.nativeToken == nil {
                            Button(L10n.text("重新核对")) { Task { await inspect() } }
                                .disabled(loading || session.isBusy)
                                .accessibilityIdentifier("mail-patch-inspect")
                            if session.status.sequencer == .none {
                                Button(L10n.text("标记已核对并关闭")) { reviewConfirmation = true }
                                    .disabled(loading || session.isBusy)
                                    .accessibilityIdentifier("mail-patch-reviewed-close")
                            }
                        } else if !session.status.conflicts.isEmpty {
                            Button(L10n.text("处理冲突")) {
                                app.workspace.route = .changes
                                dismiss()
                            }.workbenchPrimaryAction().disabled(loading || session.isBusy)
                                .accessibilityIdentifier("mail-patch-resolve")
                        } else {
                            Button(L10n.text("继续序列")) { recover(record, action: "continue") }
                                .workbenchPrimaryAction().disabled(loading || session.isBusy)
                                .accessibilityIdentifier("mail-patch-continue")
                        }
                    } else {
                        Button(L10n.text("结束并关闭序列")) {
                            session.performResult(L10n.text("关闭提交补丁序列"), onSuccess: { dismiss() }) {
                                try await $0.closeMailPatches(record)
                                return .completed(message: L10n.text("提交补丁序列已关闭。"))
                            }
                        }.workbenchPrimaryAction().disabled(loading || session.isBusy)
                            .accessibilityIdentifier("mail-patch-finish")
                    }
                } else {
                    Button(L10n.text("应用并创建提交")) { execute() }.workbenchPrimaryAction()
                        .disabled(plan == nil || loading || session.isBusy).accessibilityIdentifier(
                            "mail-patch-execute")
                }
            }.workbenchControlFamily()
        }.accessibilityElement(children: .contain).padding(24).frame(width: 660)
            .interactiveDismissDisabled(session.isBusy).task {
                if request.record == nil { await prepare() } else { await inspect() }
            }
            .onChange(of: session.status.mailPatch) { _, value in
                if attempted || request.record != nil { record = value }
            }
            .onChange(of: app.session?.id) { _, _ in if app.session !== session { dismiss() } }
            .alert(L10n.text("中止提交补丁序列？"), isPresented: $abortConfirmation) {
                Button(L10n.text("取消"), role: .cancel) {}
                Button(L10n.text("中止序列"), role: .destructive) {
                    if let record { recover(record, action: "abort") }
                }
            } message: {
                Text(L10n.text("当前工作内容先备份，再中止邮件补丁序列并回到原起点。"))
            }
            .alert(L10n.text("关闭待核对序列记录？"), isPresented: $reviewConfirmation) {
                Button(L10n.text("取消"), role: .cancel) {}
                Button(L10n.text("标记已核对并关闭")) {
                    guard let record else { return }
                    session.performResult(L10n.text("关闭提交补丁序列"), onSuccess: { dismiss() }) {
                        try await $0.dismissMailPatches(record)
                        return .completed(message: L10n.text("恢复记录已关闭。"))
                    }
                }
            } message: {
                Text(L10n.text("确认已检查提交历史和工作文件。此操作只关闭恢复记录。"))
            }
    }
    private func prepare() async {
        loading = true
        do { plan = try await session.service.prepareMailPatches(request.sources) } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        loading = false
    }
    private func execute() {
        guard let plan else { return }
        attempted = true
        session.performResult(L10n.text("导入提交补丁")) {
            let result = try await $0.executeMailPatches(plan)
            return result.phase == .completed
                ? .completed(message: L10n.text("提交补丁已应用并创建提交。"))
                : .needsReview(message: L10n.text("提交补丁序列已暂停，请核对并继续、跳过或中止。"))
        }
    }
    private func recover(_ record: MailPatchRecord, action: String) {
        attempted = true
        session.performResult(L10n.text("恢复提交补丁序列")) {
            let result = try await $0.recoverMailPatches(record, action: action)
            return result.phase.pending
                ? .needsReview(message: L10n.text("提交补丁序列已暂停，请核对并继续、跳过或中止。"))
                : .completed(
                    message: result.phase == .aborted
                        ? L10n.text("提交补丁序列已中止，原起点已恢复。") : L10n.text("提交补丁序列已结束。"))
        }
    }

    private func inspect() async {
        guard let record, record.phase.pending else { return }
        loading = true
        do {
            self.record = try await session.service.inspectMailPatches(record)
            await session.refresh()
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        loading = false
    }

    private func itemHeading(_ item: MailPatchEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(item.number). " + item.subject).fontWeight(.medium)
            Spacer(minLength: 8)
            if let status = itemStatus(item) {
                Text(status).font(.caption).foregroundStyle(colors.secondaryText)
            }
        }
    }

    private func move(_ item: MailPatchEntry, by offset: Int) {
        guard let plan, record == nil, !loading, !session.isBusy else { return }
        do { self.plan = try plan.moving(from: item.number - 1, to: item.number - 1 + offset) } catch {
            self.error = error.localizedDescription
        }
    }

    private func itemStatus(_ item: MailPatchEntry) -> String? {
        guard let record else { return nil }
        let index = item.number - 1
        if (record.skipped ?? []).contains(index) { return L10n.text("已跳过") }
        if record.phase == .needsVerification { return L10n.text("待核对") }
        if index < record.next {
            return record.phase == .aborted ? L10n.text("已撤回") : L10n.text("已应用")
        }
        if record.phase == .aborted || record.phase == .dismissed { return L10n.text("未执行") }
        return index == record.next && record.phase.pending ? L10n.text("当前") : L10n.text("待处理")
    }
}
