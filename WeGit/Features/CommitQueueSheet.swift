import SwiftUI
import WeGitCore

struct CommitQueueRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let operation: SingleCommitOperation
    let commits: [GitCommit]
    var record: CommitQueueRecord? = nil
}

struct CommitQueueSheet: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let app: AppState
    let request: CommitQueueRequest
    @State private var order: [GitCommit]
    @State private var mainlines: [String: Int] = [:]
    @State private var plan: CommitQueuePlan?
    @State private var record: CommitQueueRecord?
    @State private var loading = false
    @State private var error: String?
    @State private var attempted = false
    @State private var abortConfirmation = false
    private var session: RepositorySession { request.session }
    init(app: AppState, request: CommitQueueRequest) {
        self.app = app
        self.request = request
        _order = State(initialValue: request.commits)
        _record = State(initialValue: request.record)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: request.operation.title + L10n.text(" 队列"), symbol: "list.number")
            Text(session.location.name + " · " + (record?.branch ?? session.status.branch))
                .font(.headline).textSelection(.enabled)
            if let record {
                Text(L10n.text("已处理 \(record.next) / \(record.items.count) 个提交"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("已处理 \(record.next) / \(record.items.count) 个提交"))
                    .accessibilityIdentifier("commit-queue-progress")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(record.items.enumerated()), id: \.offset) { index, item in
                            HStack {
                                Text(String(index + 1)).monospaced().frame(width: 26)
                                Image(
                                    systemName: item.state == .committed
                                        ? "checkmark.circle.fill"
                                        : item.state == .skipped ? "arrow.forward.circle" : "circle"
                                )
                                .foregroundStyle(
                                    item.state == .committed ? colors.positive : colors.secondaryText)
                                Text(item.subject).lineLimit(2)
                                Spacer()
                                Text(item.objectID.prefix(8)).font(.caption.monospaced()).foregroundStyle(
                                    colors.secondaryText)
                            }.accessibilityElement(children: .contain)
                                .accessibilityIdentifier("commit-queue-item:\(index)")
                        }
                    }
                }.frame(maxHeight: 260)
                if let details = record.details {
                    DisclosureGroup(L10n.text("查看详情")) {
                        ScrollView {
                            Text(details).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 140)
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(order.enumerated()), id: \.element.id) { index, commit in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(String(index + 1)).monospaced().frame(width: 26)
                                    Text(commit.subject).lineLimit(2)
                                    Spacer()
                                    Button {
                                        move(index, by: -1)
                                    } label: {
                                        Image(systemName: "arrow.up")
                                    }
                                    .disabled(index == 0 || loading).accessibilityLabel(L10n.text("向前移动"))
                                    .workbenchIconButton()
                                    .accessibilityIdentifier("commit-queue-up:\(index)")
                                    Button {
                                        move(index, by: 1)
                                    } label: {
                                        Image(systemName: "arrow.down")
                                    }
                                    .disabled(index + 1 == order.count || loading).accessibilityLabel(
                                        L10n.text("向后移动")
                                    )
                                    .workbenchIconButton()
                                    .accessibilityIdentifier("commit-queue-down:\(index)")
                                }
                                Text(commit.id).font(.caption.monospaced()).foregroundStyle(
                                    colors.secondaryText
                                ).textSelection(.enabled)
                                if commit.parents.count > 1 {
                                    Picker(
                                        L10n.text("主线父提交"),
                                        selection: Binding<Int?>(
                                            get: { mainlines[commit.id] },
                                            set: {
                                                mainlines[commit.id] = $0
                                                plan = nil
                                            })
                                    ) {
                                        Text(L10n.text("选择父提交…")).tag(Int?.none)
                                        ForEach(Array(commit.parents.enumerated()), id: \.offset) {
                                            parent, oid in
                                            Text("\(parent + 1) · " + oid.prefix(12)).tag(
                                                Int?.some(parent + 1))
                                        }
                                    }.accessibilityIdentifier("commit-queue-mainline:" + commit.id)
                                }
                            }.accessibilityElement(children: .contain)
                                .accessibilityIdentifier("commit-queue-selection:\(index)")
                        }
                    }
                }.frame(maxHeight: 240)
                if let first = plan?.first {
                    Divider()
                    Text(L10n.text("下一项的文件变化")).font(.subheadline.weight(.semibold))
                    Text(first.head.prefix(12) + " → " + first.target.id.prefix(12)).font(
                        .caption.monospaced())
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(first.files) {
                                Text(String($0.status) + "  " + $0.path).font(.caption.monospaced())
                            }
                        }
                    }.frame(maxHeight: 120).accessibilityIdentifier("commit-queue-preview-files")
                    if !first.conflictPaths.isEmpty {
                        Text(L10n.text("本项预计产生冲突，队列将停下等待处理。")).foregroundStyle(colors.modified)
                    }
                }
            }
            if loading || session.isBusy {
                ProgressView(session.activityLabel.isEmpty ? L10n.text("预演队列…") : session.activityLabel)
            }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel, result: session.operationFeedback,
                    context: .standard, fallback: "")
            }
            HStack {
                if let record, record.phase.pending {
                    Button(L10n.text("跳过本项")) { perform(.skip, record: record) }
                        .disabled(session.isBusy).accessibilityIdentifier("commit-queue-skip")
                    Button(L10n.text("中止队列…"), role: .destructive) { abortConfirmation = true }
                        .disabled(session.isBusy).accessibilityIdentifier("commit-queue-abort")
                }
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : L10n.text("关闭")) {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("commit-queue-close")
                if let record {
                    if record.phase.pending {
                        let changedHead =
                            record.phase == .needsVerification && session.status.head != record.currentHead
                        Button(changedHead ? L10n.text("确认本项完成并继续") : L10n.text("继续队列")) {
                            perform(changedHead ? .confirm : .continueQueue, record: record)
                        }.disabled(session.isBusy || !session.status.conflicts.isEmpty)
                            .accessibilityIdentifier("commit-queue-continue")
                    } else {
                        Button(L10n.text("结束并关闭队列")) { perform(.close, record: record) }
                            .disabled(session.isBusy).accessibilityIdentifier("commit-queue-finish")
                    }
                } else if plan == nil {
                    Button(L10n.text("预演")) { Task { await prepare() } }
                        .disabled(
                            loading || order.isEmpty
                                || order.contains { $0.parents.count > 1 && mainlines[$0.id] == nil }
                        )
                        .accessibilityIdentifier("commit-queue-preview")
                } else {
                    Button(L10n.text("开始队列")) { execute() }.workbenchPrimaryAction()
                        .disabled(loading || session.isBusy).accessibilityIdentifier("commit-queue-start")
                }
            }.workbenchControlFamily()
        }.accessibilityElement(children: .contain).padding(24).frame(width: 680)
            .interactiveDismissDisabled(session.isBusy)
            .onChange(of: session.status.commitQueue) { _, value in
                if attempted || request.record != nil { record = value }
            }
            .onChange(of: app.session?.id) { _, _ in if app.session !== session { dismiss() } }
            .alert(L10n.text("中止当前项和剩余队列？"), isPresented: $abortConfirmation) {
                Button(L10n.text("取消"), role: .cancel) {}
                Button(L10n.text("中止队列"), role: .destructive) {
                    if let record { perform(.abort, record: record) }
                }
            } message: {
                Text(L10n.text("已完成提交保留，当前冲突变更先备份再中止；剩余提交不再执行。"))
            }
    }
    private func move(_ index: Int, by offset: Int) {
        order.swapAt(index, index + offset)
        plan = nil
    }
    private func prepare() async {
        loading = true
        error = nil
        do {
            let value = try await session.service.prepareCommitQueue(
                request.operation,
                selections: order.map { CommitQueueSelection(target: $0.id, mainline: mainlines[$0.id]) })
            guard !Task.isCancelled, app.session === session else { return }
            plan = value
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        loading = false
    }
    private func execute() {
        guard let plan, app.session === session else { return }
        attempted = true
        session.performResult(request.operation.title + L10n.text(" 队列")) {
            let value = try await $0.executeCommitQueue(plan)
            return value.phase == .completed
                ? .completed(message: L10n.text("提交队列完成。"))
                : .needsReview(message: L10n.text("队列已暂停，请处理当前项后继续或跳过。"))
        }
    }
    private enum Action { case continueQueue, confirm, skip, abort, close }
    private func perform(_ action: Action, record: CommitQueueRecord) {
        attempted = true
        session.performResult(
            request.operation.title + L10n.text(" 队列"),
            onSuccess: {
                if action == .close { dismiss() }
            },
            operation: { repository in
                let value: CommitQueueRecord
                switch action {
                case .continueQueue, .confirm:
                    value = try await repository.continueCommitQueue(
                        record, confirmObservedCommit: action == .confirm)
                case .skip: value = try await repository.skipCommitQueueItem(record)
                case .abort: value = try await repository.abortCommitQueue(record)
                case .close:
                    try await repository.closeCommitQueue(record)
                    return .completed(message: L10n.text("提交队列已关闭。"))
                }
                return value.phase.pending
                    ? .needsReview(message: L10n.text("队列已暂停，请处理当前项后继续或跳过。"))
                    : .completed(message: L10n.text("提交队列已结束。"))
            })
    }
}
