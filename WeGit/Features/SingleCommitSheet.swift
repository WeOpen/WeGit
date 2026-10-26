import SwiftUI
import WeGitCore

struct SingleCommitRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let operation: SingleCommitOperation
    let target: String
}

struct SingleCommitSheet: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let app: AppState
    let request: SingleCommitRequest
    @State private var plan: SingleCommitPlan?
    @State private var error: String?
    @State private var preparing = true
    @State private var attempted = false
    @State private var preparation = UUID()
    private var session: RepositorySession { request.session }

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(
                title: request.operation.title,
                symbol: request.operation == .cherryPick ? "arrow.turn.down.right" : "arrow.uturn.backward")
            if let plan {
                Text(plan.target.subject).font(.headline).lineLimit(3)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text(L10n.text("当前分支")).foregroundStyle(colors.secondaryText)
                        Text(plan.branch == "(detached)" ? "Detached HEAD" : plan.branch)
                            .lineLimit(2).textSelection(.enabled)
                            .accessibilityIdentifier("single-commit-branch")
                    }
                    GridRow {
                        Text("HEAD").foregroundStyle(colors.secondaryText)
                        Text(plan.head).font(.caption.monospaced()).textSelection(.enabled)
                            .accessibilityValue(plan.head).accessibilityIdentifier("single-commit-head")
                    }
                    GridRow {
                        Text(L10n.text("选中提交")).foregroundStyle(colors.secondaryText)
                        Text(plan.target.id).font(.caption.monospaced()).textSelection(.enabled)
                            .accessibilityValue(plan.target.id).accessibilityIdentifier(
                                "single-commit-target")
                    }
                }
                if request.operation == .revert {
                    Text(L10n.text("创建新提交撤销所选改动，原提交保留。")).foregroundStyle(colors.secondaryText)
                }
                Divider()
                if plan.hasChanges {
                    HStack {
                        Text(L10n.text("将改变的文件")).font(.subheadline.weight(.semibold))
                        Spacer()
                        CountBadge(value: String(plan.files.count), tone: .teal)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(plan.files) { file in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(String(file.status)).font(.caption.monospaced()).foregroundStyle(
                                        colors.secondaryText
                                    )
                                    .frame(width: 16)
                                    Text(file.path).font(.callout.monospaced()).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 60, maxHeight: 230).accessibilityIdentifier("single-commit-files")
                } else {
                    Text(L10n.text("此提交在当前 HEAD 上没有可应用的改动。"))
                        .accessibilityIdentifier("single-commit-empty")
                }
                if !plan.conflictPaths.isEmpty {
                    Label(
                        L10n.text("预计 \(plan.conflictPaths.count) 个文件产生冲突"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(colors.modified).accessibilityIdentifier("single-commit-conflicts")
                }
            }
            if preparing { ProgressView(L10n.text("预演合并…")) }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel,
                    result: session.operationFeedback, context: .standard, fallback: "")
            }
            HStack {
                if !preparing, !attempted, error != nil {
                    Button(L10n.text("重试")) { preparation = UUID() }
                }
                if attempted, !session.isBusy, session.status.sequencer != .none {
                    Button(L10n.text("查看更改")) {
                        app.workspace.route = .changes
                        dismiss()
                    }.accessibilityIdentifier("single-commit-show-changes")
                }
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : attempted ? L10n.text("关闭") : L10n.text("取消")) {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("single-commit-cancel")
                if !attempted {
                    Button(request.operation.title) { execute() }.keyboardShortcut(.defaultAction)
                        .disabled(preparing || plan?.hasChanges != true || !session.canWrite)
                        .accessibilityIdentifier("single-commit-execute")
                }
            }.workbenchControlFamily()
        }.padding(24).frame(width: 570).interactiveDismissDisabled(session.isBusy)
            .task(id: preparation) { await prepare() }
            .onChange(of: app.session?.id) { _, _ in
                if app.session !== session { dismiss() }
            }
    }

    private func prepare() async {
        guard app.session === session else { return }
        preparing = true
        error = nil
        plan = nil
        do {
            let value = try await session.service.prepareSingleCommit(
                request.operation, target: request.target)
            guard !Task.isCancelled, app.session === session else { return }
            plan = value
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        preparing = false
    }

    private func execute() {
        guard app.session === session, let plan, !attempted else { return }
        attempted = true
        session.performResult(request.operation.title, onSuccess: { dismiss() }) {
            switch try await $0.executeSingleCommit(plan) {
            case .committed:
                return .completed(message: L10n.text("\(plan.operation.title)完成"))
            case .conflicts(let count):
                return .needsReview(message: L10n.text("产生 \(count) 个冲突，请在更改页面解决后继续或中止。"))
            case .pending(let details):
                return .needsReview(
                    message: L10n.text("提交尚未完成。请核对错误和暂存区，再继续或中止。"), details: details)
            }
        }
    }
}
