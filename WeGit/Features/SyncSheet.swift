import SwiftUI
import WeGitCore

struct SyncSheet: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @State private var state: SyncState
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var errorFocused: Bool

    init(app: AppState, request: SyncRequest) {
        self.app = app
        _state = State(initialValue: SyncState(request: request))
    }

    private var title: String {
        if state.completed {
            return state.completionTitle ?? (state.kind == .pull ? L10n.text("拉取完成") : L10n.text("推送完成"))
        }
        if state.verificationReceipt != nil { return L10n.text("核对推送结果") }
        if state.committing { return L10n.text("提交并推送") }
        if state.kind == .pull { return L10n.text("拉取") }
        return state.pushPlan == nil ? L10n.text("推送") : L10n.text("确认推送目标")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: title, symbol: state.kind == .pull ? "arrow.down" : "arrow.up")
            VStack(alignment: .leading, spacing: 4) {
                Text("\(state.session.location.name) · \(state.localBranch)").font(.headline)
                Text(state.session.location.root.path).font(.caption).foregroundStyle(colors.secondaryText)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let commit = state.committedOID {
                        Label(
                            L10n.text("本地提交 \(commit.prefix(12)) 已完成"), systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(colors.positive).accessibilityIdentifier(
                            "sync-commit-completed")
                        if !state.completed {
                            Text(L10n.text("接下来只推送这个提交；重试不会再次提交。")).font(.callout)
                        }
                    }
                    if state.committing {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(
                                state.amend
                                    ? L10n.text("将修改上次提交") : L10n.text("将提交 \(state.stagedCount) 个暂存文件")
                            ).font(.headline)
                            Text(state.commitMessage).font(.callout).lineLimit(5).textSelection(.enabled)
                            Text(L10n.text("先完成本地提交，再推送到下面的目标。推送失败时本地提交仍会保留。"))
                                .font(.caption).foregroundStyle(colors.secondaryText)
                        }
                    }
                    if state.isLoading {
                        ProgressView(L10n.text("读取远端配置…")).frame(maxWidth: .infinity)
                    } else if let receipt = state.verificationReceipt, !state.completed {
                        verificationReview(receipt)
                    } else if let plan = state.pushPlan {
                        pushReview(plan)
                    } else if !state.completed {
                        targetFields
                    }
                    if let warning = state.warning {
                        Label(warning, systemImage: "exclamationmark.triangle").font(.callout)
                            .foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let error = state.error ?? state.session.refreshError {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(colors.negative).textSelection(.enabled)
                                .accessibilityFocused($errorFocused).accessibilityIdentifier("sync-error")
                            if !state.details.isEmpty {
                                DisclosureGroup(L10n.text("查看详情")) {
                                    Text(state.details).font(.caption.monospaced()).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if state.session.status.sequencer != .none {
                                Text(L10n.text("关闭此窗口后，可在更改页面处理冲突并继续或中止操作。"))
                                    .font(.caption).foregroundStyle(colors.secondaryText)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.defaultScrollAnchor(.top)
            Divider()
            HStack(spacing: 12) {
                if state.isWorking {
                    ProgressView().controlSize(.small)
                    Text(state.isPreparing ? L10n.text("检查远端目标…") : state.session.activityLabel + "…")
                        .font(.caption).foregroundStyle(colors.secondaryText)
                } else if state.pushPlan != nil && !state.completed {
                    Button(L10n.text("返回修改")) {
                        state.pushPlan = nil
                        state.leaseAcknowledged = false
                    }.accessibilityIdentifier("sync-edit-target")
                }
                Spacer()
                Button(
                    state.isWorking ? L10n.text("取消操作") : state.completed ? L10n.text("完成") : L10n.text("关闭")
                ) {
                    if state.isWorking { state.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("sync-close")
                if !state.completed { primaryAction }
            }
        }.padding(24).frame(width: 540, height: 570)
            .interactiveDismissDisabled(state.isWorking)
            .task { await state.load() }
            .onDisappear { state.stopPreparation() }
            .onChange(of: state.error) { _, error in if error != nil { errorFocused = true } }
    }

    private func verificationReview(_ receipt: PushReceipt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("推送结果待核对")).font(.headline).accessibilityIdentifier("sync-push-unknown")
            LabeledContent(L10n.text("此前目标"), value: receipt.remoteName + " · " + receipt.targetRef)
            LabeledContent(L10n.text("此前提交"), value: String(receipt.head.prefix(12)))
            Text(L10n.text("读取确认时目标的当前引用，再决定是否准备新的推送。关闭窗口后仍会保留待核对记录。"))
                .font(.caption).foregroundStyle(colors.secondaryText)
            if state.verificationResult?.matches == false {
                Button(L10n.text("重新选择并确认推送…")) {
                    if app.confirm(
                        title: L10n.text("准备新的推送计划？"),
                        message: L10n.text("当前远端与此前提交不同，原推送结果仍无法确定。将重新选择并检查地址、本地提交与远端状态。"),
                        action: L10n.text("重新选择"), destructive: false)
                    {
                        Task { await state.prepareNewPush() }
                    }
                }.disabled(!state.canPrepareNewPush).accessibilityIdentifier("sync-prepare-new-push")
                if !state.canPrepareNewPush {
                    Text(L10n.text("本地状态已变化，请关闭窗口后刷新，或手动核对原目标后标记已处理。"))
                        .font(.caption).foregroundStyle(colors.secondaryText)
                }
            }
        }
    }

    private var targetFields: some View {
        Form {
            Picker(L10n.text("远端"), selection: $state.remoteName) {
                Text(L10n.text("选择远端")).tag("")
                ForEach(state.remotes) { remote in Text(remote.name).tag(remote.name) }
            }.accessibilityIdentifier("sync-remote")
                .onChange(of: state.remoteName) { _, _ in state.pushIndex = 0 }
            TextField(L10n.text("目标分支"), text: $state.branch).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("sync-target-branch")
            if state.kind == .pull {
                if let remote = state.selectedRemote {
                    LabeledContent(L10n.text("获取地址")) { Text(remote.displayFetchURL).textSelection(.enabled) }
                }
                Picker(L10n.text("整合策略"), selection: $state.strategy) {
                    Text(L10n.text("选择策略")).tag(nil as PullStrategy?)
                    ForEach(PullStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.title).tag(Optional(strategy))
                    }
                }.accessibilityIdentifier("sync-pull-strategy")
                if let preference = state.preference {
                    Text(L10n.text("配置来源：\(preference.source)")).font(.caption).foregroundStyle(
                        colors.secondaryText
                    )
                    .textSelection(.enabled)
                    if let warning = preference.warning {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                }
                if state.strategy == .rebase {
                    Toggle(L10n.text("保留合并结构"), isOn: $state.preserveMerges).toggleStyle(.checkbox)
                    Text(L10n.text("将把本地提交重新应用到获取的远端提交上。遇到冲突后可继续或中止。"))
                        .font(.caption).foregroundStyle(colors.secondaryText)
                } else if state.strategy == .merge {
                    Toggle(L10n.text("即使能快进，也创建合并提交"), isOn: $state.createMergeCommit).toggleStyle(.checkbox)
                } else if state.strategy == .fastForwardOnly {
                    Text(L10n.text("仅在没有分叉时前移当前分支；分叉时保留本地提交并报告原因。"))
                        .font(.caption).foregroundStyle(colors.secondaryText)
                }
            } else {
                if let remote = state.selectedRemote {
                    if remote.pushURLs.count > 1 {
                        Picker(L10n.text("推送地址"), selection: $state.pushIndex) {
                            ForEach(Array(remote.displayPushURLs.enumerated()), id: \.offset) { index, url in
                                Text("\(index + 1). \(url)").tag(index)
                            }
                        }.accessibilityIdentifier("sync-push-url")
                        Text(L10n.text("本次只推送到选中的一个地址。")).font(.caption).foregroundStyle(
                            colors.secondaryText)
                    }
                    if remote.displayPushURLs.indices.contains(state.pushIndex) {
                        LabeledContent(L10n.text("推送地址")) {
                            Text(remote.displayPushURLs[state.pushIndex]).textSelection(.enabled)
                        }
                    }
                }
                Toggle(L10n.text("将目标设为当前分支的上游"), isOn: $state.setUpstream).toggleStyle(.checkbox)
                    .accessibilityIdentifier("sync-set-upstream")
                if !state.committing {
                    Toggle(L10n.text("使用 Force Push With Lease"), isOn: $state.forceWithLease).toggleStyle(
                        .checkbox
                    )
                    .accessibilityIdentifier("sync-force-lease")
                }
            }
        }.formStyle(.grouped).fixedSize(horizontal: false, vertical: true)
            .disabled(state.fieldsLocked || app.session !== state.session)
    }

    private func pushReview(_ plan: PushPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(L10n.text("本地分支"), value: plan.localBranch)
            LabeledContent(L10n.text("本地提交")) {
                Text(plan.head).font(.caption.monospaced()).textSelection(.enabled)
            }
            LabeledContent(L10n.text("远端"), value: plan.remote.name)
            LabeledContent(L10n.text("目标引用")) { Text(plan.targetRef).textSelection(.enabled) }
            Text(plan.remote.displayPushURLs[plan.pushURLIndex]).font(.callout).textSelection(.enabled)
            LabeledContent(L10n.text("检查时的远端提交")) {
                Text(plan.expectedRemoteOID ?? L10n.text("分支尚不存在")).font(.caption.monospaced()).textSelection(
                    .enabled)
            }
            if plan.forceWithLease {
                Text(L10n.text("将用本地历史替换目标分支历史。只有远端仍是上述提交（或仍不存在）时才允许推送；后台获取不会更新这次确认条件。"))
                    .font(.callout).foregroundStyle(.orange)
                Toggle(L10n.text("确认覆盖这个远端分支的历史"), isOn: $state.leaseAcknowledged)
                    .toggleStyle(.checkbox).disabled(state.isWorking)
                    .accessibilityIdentifier("sync-lease-acknowledgement")
            }
            if plan.setUpstream {
                Text(L10n.text("成功后将此目标设为本地分支的上游。")).font(.caption).foregroundStyle(colors.secondaryText)
            }
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if state.verificationReceipt != nil {
            Button(L10n.text("核对远端结果")) { state.verifyPush() }.workbenchPrimaryAction().tint(
                colors.primaryAction
            )
            .disabled(
                state.isLoading || state.isWorking || !state.session.canWrite
                    || app.session !== state.session
            )
            .accessibilityIdentifier("sync-verify-push")
        } else if state.kind == .pull {
            Button(state.strategy.map { L10n.text("拉取（\($0.title)）") } ?? L10n.text("拉取")) { state.pull() }
                .workbenchPrimaryAction().tint(colors.primaryAction).disabled(
                    !canSubmit || state.strategy == nil
                )
                .accessibilityIdentifier("sync-pull-confirm")
        } else if state.committing {
            Button(L10n.text("提交并推送")) { state.commitAndPush() }.workbenchPrimaryAction().tint(
                colors.primaryAction
            )
            .disabled(!canSubmit).accessibilityIdentifier("sync-commit-push-confirm")
        } else if let plan = state.pushPlan {
            Button(
                plan.forceWithLease ? L10n.text("按 Lease 推送") : L10n.text("推送"),
                role: plan.forceWithLease ? .destructive : nil
            ) {
                state.push()
            }.workbenchPrimaryAction()
                .tint(plan.forceWithLease ? colors.destructiveAction : colors.primaryAction)
                .disabled(!canSubmit || (plan.forceWithLease && !state.leaseAcknowledged))
                .accessibilityIdentifier("sync-push-confirm")
        } else {
            Button(L10n.text("检查推送目标")) { state.checkPush() }.workbenchPrimaryAction().tint(
                colors.primaryAction
            )
            .disabled(!canSubmit).accessibilityIdentifier("sync-check-target")
        }
    }

    private var canSubmit: Bool {
        !state.isLoading && !state.isWorking && state.targetValid && state.session.canWrite
            && app.session === state.session
            && state.session.status.sequencer == .none
    }
}
