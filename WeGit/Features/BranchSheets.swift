import SwiftUI
import WeGitCore

struct BranchEditRequest: Identifiable {
    enum Mode: String { case rename, tracking, upstream }
    let branch: GitBranch
    let mode: Mode
    var id: String { mode.rawValue + branch.id }
}

struct BranchEditorSheet: View {
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    let request: BranchEditRequest
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var upstream: String
    @State private var switchTo = true
    @State private var attempted = false

    init(app: AppState, session: RepositorySession, request: BranchEditRequest) {
        self.app = app
        self.session = session
        self.request = request
        let remote = session.remotes.filter { request.branch.name.hasPrefix($0 + "/") }.max {
            $0.count < $1.count
        }
        _name = State(
            initialValue: request.mode == .tracking
                ? remote.map { String(request.branch.name.dropFirst($0.count + 1)) } ?? request.branch.name
                : request.branch.name)
        _upstream = State(initialValue: request.branch.upstreamRef ?? "")
    }

    private var title: String {
        switch request.mode {
        case .rename: "重命名分支"
        case .tracking: "创建本地跟踪分支"
        case .upstream: "设置分支上游"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Text(request.branch.name).font(.headline).textSelection(.enabled)
            Text("当前提交：\(request.branch.oid.prefix(12))").font(.caption).foregroundStyle(
                AppColors.secondaryText)
            if request.mode == .upstream {
                Picker("上游分支", selection: $upstream) {
                    Text("未设置上游").tag("")
                    ForEach(
                        session.branches.filter { $0.id != request.branch.id && $0.symbolicTarget == nil }
                    ) { branch in
                        Text(branch.name).tag(branch.id)
                    }
                }.accessibilityIdentifier("branch-upstream").disabled(session.isBusy)
            } else {
                TextField(request.mode == .tracking ? "本地分支名称" : "新分支名称", text: $name)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("branch-edit-name")
                    .disabled(session.isBusy)
            }
            if request.mode == .tracking {
                Text("将跟踪所选远端分支；名称由你确认。").font(.caption).foregroundStyle(AppColors.secondaryText)
                Toggle("创建后立即切换", isOn: $switchTo).toggleStyle(.checkbox).disabled(session.isBusy)
            }
            if attempted, let error = session.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if session.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(session.isBusy ? "取消操作" : "取消") {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }
                Button("确定") { save() }.buttonStyle(.borderedProminent)
                    .disabled(
                        !session.canWrite || app.session !== session
                            || (request.mode != .upstream && name.isEmpty)
                    )
                    .accessibilityIdentifier("branch-edit-save")
            }
        }.padding(24).frame(width: 450).interactiveDismissDisabled(session.isBusy)
    }

    private func save() {
        guard app.session === session else { return }
        attempted = true
        let branch = request.branch
        let head = session.status.head
        let name = name
        let switchTo = switchTo
        switch request.mode {
        case .rename:
            session.perform(
                "重命名分支", onSuccess: { dismiss() },
                operation: {
                    try await $0.renameBranch(branch, to: name, expectedHead: head)
                })
        case .tracking:
            session.perform(
                "创建跟踪分支", onSuccess: { dismiss() },
                operation: {
                    try await $0.createTrackingBranch(
                        from: branch, name: name, switchTo: switchTo, expectedHead: head)
                })
        case .upstream:
            let target = session.branches.first { $0.id == upstream }
            guard upstream.isEmpty || target != nil else {
                session.show(ModelFailure.changed)
                return
            }
            session.perform(
                "设置上游", onSuccess: { dismiss() },
                operation: {
                    try await $0.setUpstream(of: branch, to: target, expectedHead: head)
                })
        }
    }
}

struct BranchDeletionSheet: View {
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    let plan: BranchDeletionPlan
    @Environment(\.dismiss) private var dismiss
    @State private var allowUnmerged = false
    @State private var attempted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("删除本地分支？").font(.title2.weight(.semibold))
            Text(plan.branch.name).font(.headline).textSelection(.enabled)
            Text("提交：\(plan.branch.oid)").font(.caption.monospaced()).textSelection(.enabled)
            Text(plan.merged ? "已合并到 \(plan.mergeTarget)。" : "尚未合并到 \(plan.mergeTarget)，删除后该分支将不再保留其提交入口。")
                .foregroundStyle(plan.merged ? Color.secondary : .orange)
            Text("只删除本地分支，不删除远端分支或工作区文件。").font(.caption).foregroundStyle(AppColors.secondaryText)
            if !plan.merged {
                Toggle("确认删除未合并分支", isOn: $allowUnmerged).toggleStyle(.checkbox)
                    .accessibilityIdentifier("branch-delete-unmerged")
            }
            if attempted, let error = session.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if session.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(session.isBusy ? "取消操作" : "取消") {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }
                Button("删除分支", role: .destructive) {
                    attempted = true
                    let force = allowUnmerged
                    session.perform("删除分支", onSuccess: { dismiss() }) {
                        try await $0.deleteBranch(plan, allowUnmerged: force)
                    }
                }.disabled(!session.canWrite || app.session !== session || (!plan.merged && !allowUnmerged))
                    .accessibilityIdentifier("branch-delete-confirm")
            }
        }.padding(24).frame(width: 480).interactiveDismissDisabled(session.isBusy)
    }
}
