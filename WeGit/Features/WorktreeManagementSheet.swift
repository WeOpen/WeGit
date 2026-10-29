import AppKit
import SwiftUI
import WeGitCore

struct WorktreeManagementSheet: View {
    @Environment(\.themeColors) private var colors
    let app: AppState
    let request: WorktreeManagementRequest
    @State private var model: WorktreeManagementState
    private var session: RepositorySession { request.session }

    init(app: AppState, request: WorktreeManagementRequest) {
        self.app = app
        self.request = request
        _model = State(initialValue: WorktreeManagementState(app: app, request: request))
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle(title: title, symbol: "square.stack.3d.up")
            switch model.screen {
            case .list: listing
            case .form: form
            case .creation(let plan): creationPreview(plan)
            case .removal(let plan): removalPreview(plan)
            }
            if model.isReading { ProgressView(L10n.text("读取工作树…")) }
            if let error = model.error {
                Text(error).foregroundStyle(colors.negative).textSelection(.enabled)
                    .accessibilityIdentifier("worktree-error")
            }
            if model.attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel,
                    result: session.operationFeedback, context: .standard, fallback: "")
            }
            Spacer(minLength: 0)
            if let directory = model.preservedDirectory {
                HStack {
                    Text(directory.path).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(2).accessibilityIdentifier("worktree-preserved-path")
                    Spacer()
                    Button(L10n.text("在 Finder 中查看")) { NSWorkspace.shared.open(directory) }
                        .accessibilityIdentifier("worktree-preserved-open")
                }
            }
            actions.workbenchControlFamily()
        }.padding(24).frame(width: 660, height: 520)
            .interactiveDismissDisabled(session.isBusy)
            .task { model.refresh() }
            .onDisappear { model.cancelReads() }
            .onChange(of: app.session?.id) { _, _ in if app.session !== session { model.close() } }
    }

    private var title: String {
        switch model.screen {
        case .list: L10n.text("工作树")
        case .form, .creation: L10n.text("创建工作树")
        case .removal: L10n.text("移除工作树")
        }
    }

    private var listing: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.trees) { tree in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(tree.url.lastPathComponent).font(.headline)
                                Text(tree.branchName ?? (tree.bare ? "Bare" : "Detached HEAD"))
                                    .font(.caption).foregroundStyle(colors.secondaryText)
                                if tree.primary {
                                    Text(L10n.text("主工作树")).font(.caption).foregroundStyle(
                                        colors.secondaryText)
                                }
                                if tree.locked != nil {
                                    Image(systemName: "lock.fill").accessibilityLabel(L10n.text("已锁定"))
                                }
                                if tree.prunable != nil {
                                    Image(systemName: "exclamationmark.triangle").accessibilityLabel(
                                        L10n.text("登记已过期"))
                                }
                            }
                            Text(tree.path).font(.caption.monospaced()).foregroundStyle(colors.secondaryText)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button {
                            model.open(tree)
                        } label: {
                            Label(L10n.text("打开"), systemImage: "arrow.up.forward")
                        }
                        .workbenchIconButton().disabled(session.isBusy || tree.bare || tree.prunable != nil)
                        .accessibilityIdentifier("worktree-open:" + tree.id)
                        Button {
                            model.prepareRemoval(tree)
                        } label: {
                            Label(L10n.text("移除工作树"), systemImage: "minus.circle")
                        }
                        .workbenchIconButton()
                        .disabled(
                            session.isBusy || model.isReading || tree.primary || tree.bare
                                || tree.locked != nil || tree.prunable != nil
                                || tree.path == session.location.root.path
                        )
                        .accessibilityIdentifier("worktree-remove:" + tree.id)
                    }.accessibilityElement(children: .contain).accessibilityIdentifier(
                        "worktree-row:" + tree.id)
                    Divider()
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("worktree-list")
    }

    private var form: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 16) {
            Picker(L10n.text("创建方式"), selection: $model.kind) {
                ForEach(WorktreeFormKind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("worktree-kind")
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("工作树路径")).font(.subheadline)
                HStack {
                    TextField(L10n.text("工作树路径"), text: $model.destination).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("worktree-destination")
                    Button(L10n.text("选择…"), action: choosePath)
                }
            }
            if model.kind == .newBranch {
                TextField(L10n.text("新分支名称"), text: $model.newBranch).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("worktree-branch")
            } else if model.kind == .existingBranch {
                TextField(L10n.text("本地分支名称"), text: $model.existingBranch).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("worktree-branch")
            }
        }
    }

    private func creationPreview(_ plan: WorktreeCreationPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.destination.path).font(.callout.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("worktree-preview-path")
            switch plan.kind {
            case .newBranch(let name): Text(L10n.text("新分支") + ": " + name)
            case .existingBranch(let name): Text(L10n.text("已有分支") + ": " + name)
            case .detached: Text("Detached HEAD")
            }
            Text(plan.target).font(.caption.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("worktree-preview-head")
        }
    }

    private func removalPreview(_ plan: WorktreeRemovalPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.worktree.path).font(.callout.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("worktree-preview-path")
            Text(plan.worktree.branchName ?? "Detached HEAD").font(.headline)
            Text(L10n.text("登记将移除，全部文件和 Git 状态会保留在私有目录。"))
                .foregroundStyle(colors.secondaryText)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            if case .list = model.screen {
                Button(L10n.text("刷新")) { model.refresh() }.disabled(model.isReading || session.isBusy)
                    .accessibilityIdentifier("worktree-refresh")
            }
            Spacer()
            Button(session.isBusy ? L10n.text("取消操作") : L10n.text("关闭")) {
                if session.isBusy {
                    session.cancel()
                } else if case .list = model.screen {
                    model.close()
                } else {
                    model.back()
                }
            }.keyboardShortcut(.cancelAction).accessibilityIdentifier("worktree-cancel")
            switch model.screen {
            case .list:
                Button(L10n.text("创建工作树…")) { model.beginCreation() }
                    .disabled(session.isBusy || model.isReading || !session.canWrite)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("worktree-create")
            case .form:
                Button(L10n.text("预览")) { model.prepareCreation() }.disabled(!model.canPreview)
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("worktree-preview")
            case .creation(let plan):
                if !model.attempted {
                    Button(L10n.text("创建工作树")) { model.executeCreation(plan) }
                        .disabled(!session.canWrite || session.isBusy).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("worktree-execute")
                }
            case .removal(let plan):
                if !model.attempted {
                    Button(L10n.text("移除工作树")) { model.executeRemoval(plan) }
                        .disabled(!session.canWrite || session.isBusy).keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("worktree-execute")
                }
            }
        }
    }

    private func choosePath() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: model.destination).deletingLastPathComponent()
        panel.nameFieldStringValue = URL(fileURLWithPath: model.destination).lastPathComponent
        panel.prompt = L10n.text("选择")
        if panel.runModal() == .OK, let url = panel.url { model.destination = url.path }
    }
}
