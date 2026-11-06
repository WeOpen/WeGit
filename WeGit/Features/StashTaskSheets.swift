import SwiftUI
import WeGitCore

struct TaskSwitchRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
}
struct StashBranchRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let entry: GitStash
    let list: StashList
}

struct TaskSwitchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors
    let app: AppState
    let request: TaskSwitchRequest
    @State private var selected = ""
    @State private var message = ""
    @State private var includeUntracked = false
    @State private var plan: TaskSwitchPlan?
    @State private var loading = false
    @State private var attempted = false
    @State private var error: String?
    private var session: RepositorySession { request.session }
    private var branches: [GitBranch] {
        session.branches.filter {
            !$0.remote && !$0.current && $0.symbolicTarget == nil && $0.worktreePath == nil
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("保存任务并切换"), symbol: "archivebox")
            Text(session.location.name + " · " + session.status.branch).font(.headline)
            TextField(L10n.text("任务名称（可选）"), text: $message).textFieldStyle(.roundedBorder)
                .disabled(attempted).accessibilityIdentifier("task-switch-message")
            Picker(L10n.text("切换到"), selection: $selected) {
                Text(L10n.text("选择分支…")).tag("")
                ForEach(branches) { Text($0.name).tag($0.id) }
            }.disabled(attempted).accessibilityIdentifier("task-switch-target")
            Toggle(L10n.text("同时保存未跟踪文件"), isOn: $includeUntracked)
                .disabled(attempted).accessibilityIdentifier("task-switch-untracked")
            if let plan {
                Text(plan.head.prefix(12) + " → " + plan.target.name + " · " + plan.target.oid.prefix(12))
                    .font(.caption.monospaced()).textSelection(.enabled)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.files.filter { !$0.untracked || plan.includeUntracked }) {
                            Text($0.path).font(.caption.monospaced())
                        }
                    }
                }.frame(maxHeight: 180).accessibilityIdentifier("task-switch-files")
            }
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel, result: session.operationFeedback,
                    context: .standard, fallback: "")
            }
            HStack {
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : L10n.text("关闭")) {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                if !attempted {
                    if let plan {
                        Button(L10n.text("保存并切换")) { execute(plan) }.workbenchPrimaryAction()
                            .disabled(loading || session.isBusy).accessibilityIdentifier(
                                "task-switch-execute")
                    } else {
                        Button(L10n.text("预览")) { Task { await prepare() } }
                            .disabled(selected.isEmpty || loading).accessibilityIdentifier(
                                "task-switch-preview")
                    }
                }
            }.workbenchControlFamily()
        }.accessibilityElement(children: .contain).padding(24).frame(width: 610)
            .interactiveDismissDisabled(session.isBusy)
            .onChange(of: selected) { _, _ in plan = nil }
            .onChange(of: message) { _, _ in plan = nil }
            .onChange(of: includeUntracked) { _, _ in plan = nil }
            .onChange(of: app.session?.id) { _, _ in if app.session !== session { dismiss() } }
    }
    private func prepare() async {
        guard let branch = branches.first(where: { $0.id == selected }) else { return }
        loading = true
        error = nil
        do {
            plan = try await session.service.prepareTaskSwitch(
                to: branch, message: message, includeUntracked: includeUntracked)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        loading = false
    }
    private func execute(_ plan: TaskSwitchPlan) {
        attempted = true
        session.performResult(
            L10n.text("保存任务并切换"), onSuccess: { dismiss() },
            operation: {
                switch try await $0.executeTaskSwitch(plan) {
                case .switched: return .completed(message: L10n.text("任务已保存，已切换到目标分支。"))
                case .savedNeedsReview(let stash, let details):
                    return .needsReview(
                        message: L10n.text("任务已保存，切换结果需要核对。储藏：\(stash.objectID.prefix(12))"), details: details
                    )
                }
            })
    }
}

struct StashBranchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors
    let app: AppState
    let request: StashBranchRequest
    @State private var name = ""
    @State private var drop = false
    @State private var plan: StashBranchPlan?
    @State private var loading = false
    @State private var attempted = false
    @State private var error: String?
    private var session: RepositorySession { request.session }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("从储藏新建分支"), symbol: "arrow.triangle.branch")
            Text(request.entry.message).font(.headline).lineLimit(3)
            Text(request.entry.objectID).font(.caption.monospaced()).foregroundStyle(colors.secondaryText)
                .textSelection(.enabled)
            TextField(L10n.text("新分支名称"), text: $name).textFieldStyle(.roundedBorder)
                .disabled(attempted).accessibilityIdentifier("stash-branch-name")
            Toggle(L10n.text("恢复成功后删除储藏"), isOn: $drop).disabled(attempted)
                .accessibilityIdentifier("stash-branch-drop")
            if let plan {
                Text(L10n.text("分支起点：\(plan.base.prefix(12))")).font(.caption.monospaced())
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.files, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                }.frame(maxHeight: 180).accessibilityIdentifier("stash-branch-files")
            }
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel, result: session.operationFeedback,
                    context: .standard, fallback: "")
                if !session.status.conflicts.isEmpty {
                    Button(L10n.text("查看更改")) {
                        app.workspace.route = .changes
                        dismiss()
                    }
                }
            }
            HStack {
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : L10n.text("关闭")) {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                if !attempted {
                    if let plan {
                        Button(L10n.text("创建并恢复")) { execute(plan) }.workbenchPrimaryAction()
                            .disabled(loading || session.isBusy).accessibilityIdentifier(
                                "stash-branch-execute")
                    } else {
                        Button(L10n.text("预览")) { Task { await prepare() } }.disabled(name.isEmpty || loading)
                            .accessibilityIdentifier("stash-branch-preview")
                    }
                }
            }.workbenchControlFamily()
        }.accessibilityElement(children: .contain).padding(24).frame(width: 610)
            .interactiveDismissDisabled(session.isBusy)
            .onChange(of: name) { _, _ in plan = nil }
            .onChange(of: drop) { _, _ in plan = nil }
            .onChange(of: app.session?.id) { _, _ in if app.session !== session { dismiss() } }
    }
    private func prepare() async {
        loading = true
        error = nil
        do {
            plan = try await session.service.prepareStashBranch(
                request.entry, in: request.list, name: name, dropAfterApply: drop)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        loading = false
    }
    private func execute(_ plan: StashBranchPlan) {
        attempted = true
        session.performResult(
            L10n.text("从储藏新建分支"),
            onSuccess: {
                app.workspace.route = .changes
                dismiss()
            },
            operation: {
                switch try await $0.executeStashBranch(plan) {
                case .restored(_, .applied), .restored(_, .popped):
                    return .completed(message: L10n.text("新分支已创建，任务及暂存状态已恢复。"))
                case .restored(_, .appliedNeedsReview(let details)):
                    return .needsReview(message: L10n.text("任务已恢复，删除储藏结果需要核对。"), details: details)
                case .branchCreatedNeedsReview(let name, let details):
                    return .needsReview(message: L10n.text("已创建分支 \(name)，恢复结果需要核对。储藏保留。"), details: details)
                }
            })
    }
}
