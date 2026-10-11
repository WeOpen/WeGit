import SwiftUI
import WeGitCore

struct BranchSwitchRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
}

struct BranchSwitcherView: View {
    @Bindable var app: AppState
    let request: BranchSwitchRequest
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: String?
    @State private var attempted = false
    @FocusState private var searchFocused: Bool

    private var branches: [GitBranch] {
        request.session.branches.filter {
            !$0.remote && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }
    private var branch: GitBranch? { branches.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("切换本地分支").font(.title2.weight(.semibold))
            Text("\(request.session.location.name) · 当前：\(request.session.status.displayBranch)")
                .font(.callout).foregroundStyle(AppColors.secondaryText)
            TextField("搜索分支名称", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
                .accessibilityIdentifier("branch-switch-search").onSubmit { switchSelected() }
                .onKeyPress(.downArrow) {
                    move(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(-1)
                    return .handled
                }
                .disabled(request.session.isBusy)
            List(selection: $selected) {
                ForEach(branches) { branch in
                    HStack {
                        Image(systemName: branch.current ? "checkmark.circle.fill" : "arrow.triangle.branch")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(branch.name).font(.headline)
                            Text(
                                app.branchSwitchReason(branch, in: request.session)
                                    ?? String(branch.oid.prefix(12))
                            )
                            .font(.caption).foregroundStyle(AppColors.secondaryText)
                        }
                        Spacer()
                    }.padding(.vertical, 4).tag(branch.id).contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            selected = branch.id
                            switchSelected()
                        }
                }
            }.disabled(request.session.isBusy).accessibilityIdentifier("branch-switch-list")
                .overlay {
                    if branches.isEmpty { Text("没有匹配的本地分支").foregroundStyle(AppColors.secondaryText) }
                }
            Text("兼容的未提交改动会保留；Git 检测到内容会被覆盖时将拒绝切换。")
                .font(.caption).foregroundStyle(AppColors.secondaryText)
            if attempted, let error = request.session.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("查看远端跟踪分支") {
                    app.workspace.route = .branches
                    app.workspace.branchFilter = ""
                    dismiss()
                }.disabled(request.session.isBusy)
                Spacer()
                if request.session.isBusy { ProgressView().controlSize(.small) }
                Button(request.session.isBusy ? "取消操作" : "取消") {
                    if request.session.isBusy { request.session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button("切换") { switchSelected() }.keyboardShortcut(.defaultAction).buttonStyle(
                    .borderedProminent
                )
                .disabled(
                    branch == nil || app.session !== request.session
                        || branch.map { app.branchSwitchReason($0, in: request.session) != nil } == true
                )
                .accessibilityIdentifier("branch-switch-confirm")
            }
        }.padding(22).frame(width: 540, height: 440).interactiveDismissDisabled(request.session.isBusy)
            .task {
                chooseInitial()
                searchFocused = true
            }
            .onChange(of: query) { _, _ in chooseInitial() }
    }

    private func chooseInitial() {
        selected =
            branches.first { app.branchSwitchReason($0, in: request.session) == nil }?.id
            ?? branches.first?.id
    }
    private func move(_ step: Int) {
        guard !branches.isEmpty else { return }
        let index = branches.firstIndex { $0.id == selected } ?? 0
        selected = branches[min(max(index + step, 0), branches.count - 1)].id
    }
    private func switchSelected() {
        guard let branch, app.session === request.session else { return }
        attempted = true
        app.switchBranch(branch, in: request.session, onSuccess: { dismiss() })
    }
}
