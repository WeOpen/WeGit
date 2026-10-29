import SwiftUI
import WeGitCore

struct RebaseRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let target: GitBranch?
}

struct RebaseSheet: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let app: AppState
    let request: RebaseRequest
    @State private var selection: String
    @State private var preserveMerges = false
    @State private var acknowledgePublished = false
    @State private var plan: RebasePlan?
    @State private var error: String?
    @State private var preparing = false
    @State private var attempted = false
    @State private var refreshID = UUID()
    private var session: RepositorySession { request.session }
    private struct Preparation: Hashable {
        let target: String
        let merges: Bool
        let refresh: UUID
    }

    init(app: AppState, request: RebaseRequest) {
        self.app = app
        self.request = request
        _selection = State(initialValue: request.target?.id ?? "")
    }

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("变基"), symbol: "arrow.triangle.branch")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(L10n.text("目标分支"), selection: $selection) {
                        Text(L10n.text("选择目标分支…")).tag("")
                        ForEach(session.branches.filter { !$0.current && $0.symbolicTarget == nil }) {
                            branch in
                            Text(branch.name).tag(branch.id)
                        }
                    }.accessibilityIdentifier("rebase-target-picker").disabled(session.isBusy || attempted)
                    Toggle(L10n.text("保留合并结构"), isOn: $preserveMerges)
                        .toggleStyle(.checkbox).disabled(session.isBusy || attempted)
                        .accessibilityIdentifier("rebase-preserve-merges")
                    if preparing { ProgressView(L10n.text("读取变基范围…")) }
                    if let plan {
                        VStack(alignment: .leading, spacing: 8) {
                            context(
                                L10n.text("当前分支"), plan.branch, "rebase-current-branch", monospaced: false)
                            context("HEAD", plan.head, "rebase-head")
                            context(L10n.text("目标提交"), plan.target.oid, "rebase-target-oid")
                            context(
                                L10n.text("共同起点"), plan.startingPoint ?? L10n.text("无共同起点"), "rebase-base")
                        }
                        if plan.disposition == .upToDate {
                            Text(L10n.text("当前分支已包含目标提交。")).accessibilityIdentifier("rebase-no-work")
                        } else if plan.disposition == .fastForward {
                            Text(L10n.text("当前分支将快进到目标提交。")).accessibilityIdentifier("rebase-fast-forward")
                        } else {
                            HStack {
                                Text(L10n.text("待重放的提交")).font(.subheadline.weight(.semibold))
                                Spacer()
                                CountBadge(value: String(plan.commits.count), tone: .teal)
                            }
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(plan.commits) { commit in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(String(commit.id.prefix(12))).font(.caption.monospaced())
                                            .foregroundStyle(colors.secondaryText)
                                        Text(commit.subject).font(.callout).fixedSize(
                                            horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }.textSelection(.enabled)
                                }
                            }.accessibilityIdentifier("rebase-commits")
                        }
                        if !plan.publishedCommits.isEmpty {
                            Text(L10n.text("此范围包含已发布提交；变基会改写历史，后续推送需要重新确认 Lease。"))
                                .foregroundStyle(colors.modified).accessibilityIdentifier(
                                    "rebase-published-warning")
                            Toggle(L10n.text("确认改写已发布提交"), isOn: $acknowledgePublished)
                                .toggleStyle(.checkbox).disabled(session.isBusy || attempted)
                                .accessibilityIdentifier("rebase-published-confirm")
                        }
                        if !plan.conflictPaths.isEmpty, !attempted {
                            Label(
                                L10n.text("预计下一步有 \(plan.conflictPaths.count) 个冲突"),
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(colors.modified).accessibilityIdentifier(
                                "rebase-preview-conflicts")
                        }
                    }
                    if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
                    if attempted {
                        OperationFeedback(
                            busy: session.isBusy, activity: session.activityLabel,
                            result: session.operationFeedback, context: .standard, fallback: "")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("rebase-preview")
            HStack {
                if !preparing, !session.isBusy, error != nil || attempted {
                    Button(L10n.text("重新预览")) {
                        attempted = false
                        refreshID = UUID()
                    }.disabled(session.status.sequencer != .none).accessibilityIdentifier("rebase-refresh")
                }
                if attempted, !session.isBusy, session.status.sequencer != .none {
                    Button(L10n.text("查看更改")) {
                        app.workspace.route = .changes
                        dismiss()
                    }.accessibilityIdentifier("rebase-show-changes")
                }
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : attempted ? L10n.text("关闭") : L10n.text("取消")) {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("rebase-cancel")
                if !attempted {
                    Button(L10n.text("开始变基")) { execute() }.keyboardShortcut(.defaultAction)
                        .workbenchPrimaryAction().tint(colors.primaryAction)
                        .disabled(
                            preparing || plan?.hasWork != true || !session.canRebase
                                || (plan?.publishedCommits.isEmpty == false && !acknowledgePublished)
                        )
                        .accessibilityIdentifier("rebase-execute")
                }
            }.workbenchControlFamily()
        }.padding(24).frame(width: 620, height: 550).interactiveDismissDisabled(session.isBusy)
            .task(id: Preparation(target: selection, merges: preserveMerges, refresh: refreshID)) {
                await prepare()
            }
            .onChange(of: app.session?.id) { _, _ in if app.session !== session { dismiss() } }
    }

    private func context(_ label: String, _ value: String, _ identifier: String, monospaced: Bool = true)
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(colors.secondaryText).frame(width: 90, alignment: .leading)
            Text(value).font(monospaced ? .caption.monospaced() : .body)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.accessibilityElement(children: .ignore).accessibilityLabel(label + ": " + value)
            .accessibilityIdentifier(identifier)
    }

    private func prepare() async {
        guard app.session === session else { return }
        plan = nil
        error = nil
        preparing = false
        acknowledgePublished = false
        guard !selection.isEmpty else { return }
        guard let target = session.branches.first(where: { $0.id == selection }) else {
            error = ModelFailure.changed.localizedDescription
            return
        }
        preparing = true
        do {
            let value = try await session.service.prepareRebase(
                target: target, preserveMerges: preserveMerges)
            guard !Task.isCancelled, app.session === session else { return }
            plan = value
        } catch {
            guard !Task.isCancelled, app.session === session else { return }
            self.error = error.localizedDescription
        }
        preparing = false
    }

    private func execute() {
        guard app.session === session, let plan, !attempted else { return }
        attempted = true
        session.performResult(
            L10n.text("变基"), onSuccess: { dismiss() },
            operation: { try await $0.executeRebase(plan).feedback })
    }
}
