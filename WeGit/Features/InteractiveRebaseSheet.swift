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
                Text(L10n.text("调整提交动作和顺序后执行")).font(.caption)
                    .foregroundStyle(colors.secondaryText)
                List {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        HStack(spacing: 8) {
                            Text(String(index + 1)).font(.caption.monospacedDigit())
                                .foregroundStyle(colors.secondaryText).frame(width: 24)
                            Picker("", selection: actionBinding(index)) {
                                ForEach(InteractiveRebaseAction.allCases, id: \.self) { action in
                                    Text(action.rawValue).tag(action)
                                }
                            }
                            .labelsHidden().frame(width: 100)
                            VStack(alignment: .leading) {
                                Text(String(step.id.prefix(10))).font(.caption.monospaced())
                                Text(step.subject).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                move(index, by: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless).disabled(index == 0)
                            Button {
                                move(index, by: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless).disabled(index == steps.count - 1)
                        }
                        .accessibilityIdentifier("interactive-rebase-step-\(step.id)")
                    }
                }
                .frame(minHeight: 240)
            }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel,
                    result: session.operationFeedback, context: .standard, fallback: "")
            }
            HStack {
                Spacer()
                Button(attempted ? L10n.text("关闭") : L10n.text("取消")) {
                    if !session.isBusy { dismiss() }
                }.keyboardShortcut(.cancelAction)
                if !attempted {
                    Button(L10n.text("执行交互式变基")) { execute() }
                        .workbenchPrimaryAction().tint(colors.primaryAction)
                        .disabled(preparing || steps.isEmpty || session.isBusy || !session.canWrite)
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
                steps[index] = InteractiveRebaseStep(
                    id: current.id, subject: current.subject, author: current.author,
                    action: value, message: value == .reword ? (current.message ?? current.subject) : nil)
            })
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
        attempted = true
        let adjusted = plan.replacing(steps: steps)
        session.performResult(
            L10n.text("交互式变基"), onSuccess: { dismiss() },
            operation: { try await $0.executeInteractiveRebase(adjusted).feedback })
    }
}
