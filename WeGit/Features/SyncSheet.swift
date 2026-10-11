import SwiftUI
import WeGitCore

struct SyncSheet: View {
    @Bindable var app: AppState
    @State private var state: SyncState
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var errorFocused: Bool

    init(app: AppState, request: SyncRequest) {
        self.app = app
        _state = State(initialValue: SyncState(request: request))
    }

    private var title: String {
        if state.completed { return state.completionTitle ?? (state.kind == .pull ? "拉取完成" : "推送完成") }
        if state.verificationReceipt != nil { return "核对推送结果" }
        if state.committing { return "提交并推送" }
        if state.kind == .pull { return "拉取" }
        return state.pushPlan == nil ? "推送" : "确认推送目标"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(state.session.location.name) · \(state.localBranch)").font(.headline)
                Text(state.session.location.root.path).font(.caption).foregroundStyle(AppColors.secondaryText)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let commit = state.committedOID {
                        Label("本地提交 \(commit.prefix(12)) 已完成", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).accessibilityIdentifier("sync-commit-completed")
                        if !state.completed {
                            Text("接下来只推送这个提交；重试不会再次提交。").font(.callout)
                        }
                    }
                    if state.committing {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(state.amend ? "将修改上次提交" : "将提交 \(state.stagedCount) 个暂存文件").font(.headline)
                            Text(state.commitMessage).font(.callout).lineLimit(5).textSelection(.enabled)
                            Text("先完成本地提交，再推送到下面的目标。推送失败时本地提交仍会保留。")
                                .font(.caption).foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    if state.isLoading {
                        ProgressView("读取远端配置…").frame(maxWidth: .infinity)
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
                                .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                                .accessibilityFocused($errorFocused).accessibilityIdentifier("sync-error")
                            if !state.details.isEmpty {
                                DisclosureGroup("查看详情") {
                                    Text(state.details).font(.caption.monospaced()).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if state.session.status.sequencer != .none {
                                Text("关闭此窗口后，可在更改页面处理冲突并继续或中止操作。")
                                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.defaultScrollAnchor(.top)
            Divider()
            HStack(spacing: 12) {
                if state.isWorking {
                    ProgressView().controlSize(.small)
                    Text(state.isPreparing ? "检查远端目标…" : state.session.activityLabel + "…")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                } else if state.pushPlan != nil && !state.completed {
                    Button("返回修改") {
                        state.pushPlan = nil
                        state.leaseAcknowledged = false
                    }.accessibilityIdentifier("sync-edit-target")
                }
                Spacer()
                Button(state.isWorking ? "取消操作" : state.completed ? "完成" : "关闭") {
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
            Text("推送结果待核对").font(.headline).accessibilityIdentifier("sync-push-unknown")
            LabeledContent("此前目标", value: receipt.remoteName + " · " + receipt.targetRef)
            LabeledContent("此前提交", value: String(receipt.head.prefix(12)))
            Text("读取确认时目标的当前引用，再决定是否准备新的推送。关闭窗口后仍会保留待核对记录。")
                .font(.caption).foregroundStyle(AppColors.secondaryText)
            if state.verificationResult?.matches == false {
                Button("重新选择并确认推送…") {
                    if app.confirm(
                        title: "准备新的推送计划？",
                        message: "当前远端与此前提交不同，原推送结果仍无法确定。将重新选择并检查地址、本地提交与远端状态。",
                        action: "重新选择", destructive: false)
                    {
                        Task { await state.prepareNewPush() }
                    }
                }.disabled(!state.canPrepareNewPush).accessibilityIdentifier("sync-prepare-new-push")
                if !state.canPrepareNewPush {
                    Text("本地状态已变化，请关闭窗口后刷新，或手动核对原目标后标记已处理。")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                }
            }
        }
    }

    private var targetFields: some View {
        Form {
            Picker("远端", selection: $state.remoteName) {
                Text("选择远端").tag("")
                ForEach(state.remotes) { remote in Text(remote.name).tag(remote.name) }
            }.accessibilityIdentifier("sync-remote")
                .onChange(of: state.remoteName) { _, _ in state.pushIndex = 0 }
            TextField("目标分支", text: $state.branch).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("sync-target-branch")
            if state.kind == .pull {
                if let remote = state.selectedRemote {
                    LabeledContent("获取地址") { Text(remote.displayFetchURL).textSelection(.enabled) }
                }
                Picker("整合策略", selection: $state.strategy) {
                    Text("选择策略").tag(nil as PullStrategy?)
                    ForEach(PullStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.title).tag(Optional(strategy))
                    }
                }.accessibilityIdentifier("sync-pull-strategy")
                if let preference = state.preference {
                    Text("配置来源：\(preference.source)").font(.caption).foregroundStyle(AppColors.secondaryText)
                        .textSelection(.enabled)
                    if let warning = preference.warning {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    }
                }
                if state.strategy == .rebase {
                    Toggle("保留合并结构", isOn: $state.preserveMerges).toggleStyle(.checkbox)
                    Text("将把本地提交重新应用到获取的远端提交上。遇到冲突后可继续或中止。")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                } else if state.strategy == .merge {
                    Toggle("即使能快进，也创建合并提交", isOn: $state.createMergeCommit).toggleStyle(.checkbox)
                } else if state.strategy == .fastForwardOnly {
                    Text("仅在没有分叉时前移当前分支；分叉时保留本地提交并报告原因。")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                }
            } else {
                if let remote = state.selectedRemote {
                    if remote.pushURLs.count > 1 {
                        Picker("推送地址", selection: $state.pushIndex) {
                            ForEach(Array(remote.displayPushURLs.enumerated()), id: \.offset) { index, url in
                                Text("\(index + 1). \(url)").tag(index)
                            }
                        }.accessibilityIdentifier("sync-push-url")
                        Text("本次只推送到选中的一个地址。").font(.caption).foregroundStyle(AppColors.secondaryText)
                    }
                    if remote.displayPushURLs.indices.contains(state.pushIndex) {
                        LabeledContent("推送地址") {
                            Text(remote.displayPushURLs[state.pushIndex]).textSelection(.enabled)
                        }
                    }
                }
                Toggle("将目标设为当前分支的上游", isOn: $state.setUpstream).toggleStyle(.checkbox)
                    .accessibilityIdentifier("sync-set-upstream")
                if !state.committing {
                    Toggle("使用 Force Push With Lease", isOn: $state.forceWithLease).toggleStyle(.checkbox)
                        .accessibilityIdentifier("sync-force-lease")
                }
            }
        }.formStyle(.grouped).fixedSize(horizontal: false, vertical: true)
            .disabled(state.fieldsLocked || app.session !== state.session)
    }

    private func pushReview(_ plan: PushPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("本地分支", value: plan.localBranch)
            LabeledContent("本地提交") { Text(plan.head).font(.caption.monospaced()).textSelection(.enabled) }
            LabeledContent("远端", value: plan.remote.name)
            LabeledContent("目标引用") { Text(plan.targetRef).textSelection(.enabled) }
            Text(plan.remote.displayPushURLs[plan.pushURLIndex]).font(.callout).textSelection(.enabled)
            LabeledContent("检查时的远端提交") {
                Text(plan.expectedRemoteOID ?? "分支尚不存在").font(.caption.monospaced()).textSelection(.enabled)
            }
            if plan.forceWithLease {
                Text("将用本地历史替换目标分支历史。只有远端仍是上述提交（或仍不存在）时才允许推送；后台获取不会更新这次确认条件。")
                    .font(.callout).foregroundStyle(.orange)
                Toggle("确认覆盖这个远端分支的历史", isOn: $state.leaseAcknowledged)
                    .toggleStyle(.checkbox).disabled(state.isWorking)
                    .accessibilityIdentifier("sync-lease-acknowledgement")
            }
            if plan.setUpstream {
                Text("成功后将此目标设为本地分支的上游。").font(.caption).foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if state.verificationReceipt != nil {
            Button("核对远端结果") { state.verifyPush() }.buttonStyle(.borderedProminent)
                .disabled(
                    state.isLoading || state.isWorking || !state.session.canWrite
                        || app.session !== state.session
                )
                .accessibilityIdentifier("sync-verify-push")
        } else if state.kind == .pull {
            Button(state.strategy.map { "拉取（\($0.title)）" } ?? "拉取") { state.pull() }
                .buttonStyle(.borderedProminent).disabled(!canSubmit || state.strategy == nil)
                .accessibilityIdentifier("sync-pull-confirm")
        } else if state.committing {
            Button("提交并推送") { state.commitAndPush() }.buttonStyle(.borderedProminent)
                .disabled(!canSubmit).accessibilityIdentifier("sync-commit-push-confirm")
        } else if let plan = state.pushPlan {
            Button(plan.forceWithLease ? "按 Lease 推送" : "推送", role: plan.forceWithLease ? .destructive : nil)
            {
                state.push()
            }.buttonStyle(.borderedProminent)
                .disabled(!canSubmit || (plan.forceWithLease && !state.leaseAcknowledged))
                .accessibilityIdentifier("sync-push-confirm")
        } else {
            Button("检查推送目标") { state.checkPush() }.buttonStyle(.borderedProminent)
                .disabled(!canSubmit).accessibilityIdentifier("sync-check-target")
        }
    }

    private var canSubmit: Bool {
        !state.isLoading && !state.isWorking && state.targetValid && state.session.canWrite
            && app.session === state.session
            && state.session.status.sequencer == .none
    }
}
