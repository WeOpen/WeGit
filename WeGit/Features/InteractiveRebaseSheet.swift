import SwiftUI
import WeGitCore

struct InteractiveRebaseRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let upstream: GitBranch?
}

struct InteractiveRebaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors
    let app: AppState
    let request: InteractiveRebaseRequest
    @State private var upstreamID: String
    @State private var plan: InteractiveRebasePlan?
    @State private var steps: [InteractiveRebaseStep] = []
    @State private var preparing = false
    @State private var attempted = false
    @State private var refreshID = UUID()
    @State private var error: String?
    @State private var acknowledgePublished = false

    private var session: RepositorySession { request.session }

    init(app: AppState, request: InteractiveRebaseRequest) {
        self.app = app
        self.request = request
        _upstreamID = State(initialValue: request.upstream?.id ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle(title: L10n.text("交互式变基"), symbol: "list.number")
            Picker(L10n.text("上游分支"), selection: $upstreamID) {
                Text(L10n.text("选择上游分支…")).tag("")
                ForEach(session.branches.filter { !$0.current && !$0.remote && $0.symbolicTarget == nil }) {
                    Text($0.name).tag($0.id)
                }
            }
            .accessibilityIdentifier("interactive-rebase-upstream")
            .disabled(preparing || attempted || session.isBusy)
            if preparing { ProgressView(L10n.text("读取提交序列…")) }
            if !steps.isEmpty {
                if plan?.publishedCommits.isEmpty == false {
                    Text(L10n.text("此范围包含已发布提交；变基会改写历史，后续推送需要重新确认 Lease。"))
                        .font(.caption).foregroundStyle(colors.negative)
                        .accessibilityIdentifier("interactive-rebase-published-warning")
                    Toggle(L10n.text("确认改写已发布提交"), isOn: $acknowledgePublished)
                        .accessibilityIdentifier("interactive-rebase-published-confirm")
                }
                List {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(String(index + 1)).font(.caption.monospacedDigit())
                                    .foregroundStyle(colors.secondaryText).frame(width: 24)
                                Picker("", selection: actionBinding(index)) {
                                    ForEach(InteractiveRebaseAction.allCases, id: \.self) { action in
                                        Text(actionTitle(action)).tag(action)
                                    }
                                }
                                .labelsHidden().frame(width: 145)
                                .accessibilityLabel(L10n.text("提交动作"))
                                .accessibilityIdentifier("interactive-rebase-action-\(step.id)")
                                VStack(alignment: .leading) {
                                    Text(String(step.id.prefix(10))).font(.caption.monospaced())
                                    Text(
                                        step.subject.components(separatedBy: .newlines).first ?? step.subject
                                    )
                                    .lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    move(index, by: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless).disabled(index == 0)
                                .accessibilityLabel(L10n.text("上移提交"))
                                .accessibilityIdentifier("interactive-rebase-up-\(step.id)")
                                Button {
                                    move(index, by: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless).disabled(index == steps.count - 1)
                                .accessibilityLabel(L10n.text("下移提交"))
                                .accessibilityIdentifier("interactive-rebase-down-\(step.id)")
                            }
                            if step.action == .reword || step.action == .squash {
                                TextEditor(text: messageBinding(index))
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(height: 64)
                                    .accessibilityLabel(L10n.text("提交说明"))
                                    .accessibilityIdentifier("interactive-rebase-message-\(step.id)")
                                    .overlay(alignment: .topLeading) {
                                        if step.action == .squash && (step.message ?? "").isEmpty {
                                            Text(L10n.text("留空以保留 Git 生成的组合消息"))
                                                .font(.caption).foregroundStyle(colors.secondaryText)
                                                .padding(.leading, 5).padding(.top, 8)
                                                .allowsHitTesting(false)
                                        }
                                    }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("interactive-rebase-step-\(step.id)")
                    }
                }
                .frame(minHeight: 200)
                .disabled(preparing || attempted || session.isBusy)
            }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel,
                    result: session.operationFeedback, context: .standard, fallback: "")
            }
            HStack {
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : attempted ? L10n.text("关闭") : L10n.text("取消")) {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("interactive-rebase-cancel")
                if !attempted {
                    Button(L10n.text("执行交互式变基")) { execute() }
                        .workbenchPrimaryAction().tint(colors.primaryAction)
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            preparing || steps.isEmpty || session.isBusy || !session.canWrite
                                || (plan?.publishedCommits.isEmpty == false && !acknowledgePublished)
                        )
                        .accessibilityIdentifier("interactive-rebase-execute")
                }
            }.workbenchControlFamily()
        }
        .padding(22).frame(width: 700, height: 560)
        .interactiveDismissDisabled(session.isBusy)
        .task(id: "\(upstreamID):\(refreshID)") { await prepare() }
    }

    private func actionBinding(_ index: Int) -> Binding<InteractiveRebaseAction> {
        Binding(
            get: { steps[index].action },
            set: { value in
                let current = steps[index]
                let message: String?
                switch value {
                case .reword: message = current.message ?? current.subject
                case .squash: message = current.message
                default: message = nil
                }
                steps[index] = InteractiveRebaseStep(
                    id: current.id, subject: current.subject, author: current.author,
                    action: value, message: message)
            })
    }

    private func messageBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { steps[index].message ?? "" },
            set: { value in
                let current = steps[index]
                steps[index] = InteractiveRebaseStep(
                    id: current.id, subject: current.subject, author: current.author,
                    action: current.action, message: value.isEmpty && current.action == .squash ? nil : value)
            })
    }

    private func actionTitle(_ action: InteractiveRebaseAction) -> String {
        switch action {
        case .pick: L10n.text("保留提交")
        case .reword: L10n.text("重写提交消息")
        case .edit: L10n.text("编辑后暂停")
        case .squash: L10n.text("压缩并编辑消息")
        case .fixup: L10n.text("压缩并保留前一消息")
        case .drop: L10n.text("丢弃提交")
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard steps.indices.contains(destination) else { return }
        steps.swapAt(index, destination)
    }

    private func prepare() async {
        guard app.session === session, let upstream = session.branches.first(where: { $0.id == upstreamID })
        else {
            plan = nil
            steps = []
            return
        }
        preparing = true
        acknowledgePublished = false
        error = nil
        do {
            let value = try await session.service.prepareInteractiveRebase(upstream: upstream)
            guard !Task.isCancelled, app.session === session else { return }
            plan = value
            steps = value.steps
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            plan = nil
            steps = []
        }
        preparing = false
    }

    private func execute() {
        guard let plan, !steps.isEmpty, !attempted else { return }
        do {
            try session.service.validateInteractiveSteps(steps, sourceIDs: Set(plan.steps.map(\.id)))
        } catch {
            self.error = error.localizedDescription
            return
        }
        attempted = true
        let adjusted = plan.replacing(steps: steps)
        session.performResult(
            L10n.text("交互式变基"), onSuccess: { dismiss() },
            operation: { try await $0.executeInteractiveRebase(adjusted).feedback })
    }
}
