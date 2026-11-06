import AppKit
import SwiftUI
import WeGitCore

struct SubmoduleManagementSheet: View {
    @Bindable var session: RepositorySession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors
    @State private var operation: SubmoduleChangeOperation
    @State private var path: String
    @State private var source: String
    @State private var synchronizeChildRemote = false
    @State private var plan: SubmoduleChangePlan?
    @State private var receipt: SubmoduleChangeReceipt?
    @State private var error: String?
    @State private var preparing = false
    @State private var attempted = false
    @State private var preparation: Task<Void, Never>?
    @FocusState private var focus: Field?
    private enum Field { case path, source }

    init(
        session: RepositorySession, operation: SubmoduleChangeOperation = .add, path: String = "",
        source: String = ""
    ) {
        self.session = session
        _operation = State(initialValue: operation)
        _path = State(initialValue: path)
        _source = State(initialValue: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: operation.title, symbol: "shippingbox")
            Form {
                LabeledContent(L10n.text("路径")) {
                    TextField("", text: $path).textFieldStyle(.roundedBorder).focused($focus, equals: .path)
                        .accessibilityLabel(L10n.text("子模块路径")).accessibilityIdentifier("submodule-path")
                }
                if operation != .remove {
                    LabeledContent(L10n.text("来源")) {
                        TextField("", text: $source).textFieldStyle(.roundedBorder).focused(
                            $focus, equals: .source
                        )
                        .accessibilityLabel(L10n.text("子模块来源")).accessibilityIdentifier("submodule-source")
                    }
                }
            }.disabled(attempted || preparing)
            if operation == .changeSource {
                Toggle(L10n.text("同步子仓库 origin 来源"), isOn: $synchronizeChildRemote)
                    .toggleStyle(.checkbox).disabled(attempted || preparing)
                    .accessibilityIdentifier("submodule-sync-child-source")
            }
            if let plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let oid = plan.targetOID ?? plan.indexOID {
                            LabeledContent(L10n.text("暂存区指向")) {
                                Text(oid).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        if let oid = plan.actualChildOID {
                            LabeledContent(L10n.text("子仓库 HEAD")) {
                                Text(oid).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        if plan.downloadsRepository {
                            Text(L10n.text("下载来源仓库并检出固定提交；不递归初始化嵌套模块。"))
                                .font(.callout).accessibilityIdentifier("submodule-download-preview")
                        } else if operation == .remove {
                            Text(L10n.text("保留子仓库文件与 Git 数据。仅移除父仓库登记和此路径的 gitlink。"))
                                .font(.callout).accessibilityIdentifier("submodule-retain-preview")
                        }
                        if let childSource = plan.childRemoteSource {
                            LabeledContent("origin") {
                                Text(Redaction.text(childSource) + " → " + Redaction.text(plan.source ?? ""))
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        LabeledContent(operation == .add ? L10n.text("子模块路径") : L10n.text("保留文件")) {
                            Text(plan.retention.files.path).font(.caption.monospaced()).textSelection(
                                .enabled)
                        }
                        if let gitData = plan.retention.gitData {
                            LabeledContent(L10n.text("Git 数据")) {
                                Text(gitData.path).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        } else if plan.retention.initialized {
                            Text(L10n.text("Git 数据位置未能确认；原子仓库目录保持原样。"))
                                .foregroundStyle(colors.negative)
                        }
                        retention(plan.retention)
                        DisclosureGroup(".gitmodules · " + L10n.text("未暂存")) {
                            Text(plan.gitmodulesPreview).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("submodule-preview")
            } else {
                Spacer(minLength: 0)
            }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if let receipt {
                SubmoduleReceiptView(receipt: receipt)
            } else if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel, result: session.operationFeedback,
                    context: .standard, fallback: "")
            }
            HStack {
                if preparing { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("准备预览")) }
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : attempted ? L10n.text("关闭") : L10n.text("取消")) {
                    if session.isBusy {
                        session.cancel()
                    } else {
                        preparation?.cancel()
                        dismiss()
                    }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("submodule-cancel")
                if !attempted {
                    if plan == nil {
                        Button(L10n.text("预览"), action: prepare).disabled(
                            preparing || path.isEmpty || (operation != .remove && source.isEmpty)
                        )
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("submodule-prepare")
                    } else {
                        Button(operation.title, action: execute).workbenchPrimaryAction().keyboardShortcut(
                            .defaultAction
                        )
                        .disabled(
                            preparing || session.isBusy || !session.canWrite
                                || !(plan?.retention.locks.isEmpty ?? false)
                        )
                        .accessibilityIdentifier("submodule-execute")
                    }
                }
            }
        }.padding(24).frame(width: 660, height: 600).interactiveDismissDisabled(session.isBusy)
            .onChange(of: path + "\0" + source) { _, _ in
                if !attempted {
                    plan = nil
                    error = nil
                }
            }
            .onChange(of: synchronizeChildRemote) { _, _ in
                if !attempted {
                    plan = nil
                    error = nil
                }
            }
            .task { focus = path.isEmpty ? .path : .source }
            .onDisappear { preparation?.cancel() }
    }

    @ViewBuilder private func retention(_ value: SubmoduleRetention) -> some View {
        HStack(spacing: 12) {
            if !value.initialized { Text(L10n.text("未初始化")) }
            if value.dirty { Text(L10n.text("有改动")) }
            if value.untracked { Text(L10n.text("未跟踪")) }
            if value.ignored { Text(L10n.text("已忽略")) }
            if value.invalid { Text(L10n.text("状态无效")) }
        }.font(.callout).foregroundStyle(colors.negative)
        if let count = value.independentCommits, count > 0 {
            Text(L10n.text("存在未进入远端引用的提交"))
        }
        if !value.nestedPaths.isEmpty {
            DisclosureGroup(L10n.text("嵌套子模块")) {
                ForEach(value.nestedPaths, id: \.self) {
                    Text($0).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        if !value.locks.isEmpty {
            Text(L10n.text("子仓库已锁定，暂时不能执行。"))
                .foregroundStyle(colors.negative).accessibilityIdentifier("submodule-locked")
        }
    }

    private func prepare() {
        guard !preparing, !attempted else { return }
        preparing = true
        error = nil
        let requested = (path, source, operation, synchronizeChildRemote)
        preparation = Task {
            defer { preparing = false }
            do {
                let value = try await session.service.prepareSubmoduleChange(
                    operation: requested.2, path: requested.0,
                    source: requested.2 == .remove ? nil : requested.1, synchronizeChildRemote: requested.3)
                guard !Task.isCancelled, path == requested.0, source == requested.1,
                    synchronizeChildRemote == requested.3
                else { return }
                plan = value
            } catch {
                guard !Task.isCancelled else { return }
                self.error = Redaction.text(error.localizedDescription)
            }
        }
    }

    private func execute() {
        guard let plan, !attempted, session.canWrite, !session.isBusy, plan.retention.locks.isEmpty else {
            return
        }
        attempted = true
        session.performResult(operation.title) { service in
            do {
                let value = try await service.executeSubmoduleChange(plan)
                await MainActor.run { receipt = value }
                return .completed(message: L10n.text("子模块配置已更新。"))
            } catch let unknown as SubmoduleChangeOutcomeUnknown {
                await MainActor.run { receipt = unknown.receipt }
                return .needsReview(message: unknown.localizedDescription)
            }
        }
    }
}

private struct SubmoduleReceiptView: View {
    let receipt: SubmoduleChangeReceipt
    @Environment(\.themeColors) private var colors
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                receipt.phase == .completed
                    ? L10n.text("子模块配置已更新。") : L10n.text("子模块操作结果需要核对。已保留文件、Git 数据和回执；不会自动重试。")
            )
            .foregroundStyle(receipt.phase == .completed ? colors.positive : colors.negative)
            HStack(spacing: 12) {
                if receipt.childInstalled { Text(L10n.text("子仓库已放置")) }
                if receipt.gitmodulesWritten { Text(".gitmodules ✓") }
                if receipt.configurationWritten { Text(L10n.text("配置已写入")) }
                if receipt.indexWritten { Text(L10n.text("gitlink 已写入")) }
                if receipt.childConfigurationWritten { Text(L10n.text("子仓库 origin 已更新")) }
            }.font(.caption)
            Button(L10n.text("在 Finder 中检查")) {
                NSWorkspace.shared.activateFileViewerSelecting([receipt.receiptFile])
            }
            .accessibilityIdentifier("submodule-receipt-open")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("submodule-receipt")
    }
}

struct SubmoduleReceiptReviewSheet: View {
    let receipt: SubmoduleChangeReceipt
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("核对子模块操作"), symbol: "exclamationmark.triangle")
            Text(receipt.path).font(.callout.monospaced()).textSelection(.enabled)
            SubmoduleReceiptView(receipt: receipt)
            LabeledContent(L10n.text("子模块路径"), value: receipt.retainedFiles.path)
            if let data = receipt.retainedGitData { LabeledContent(L10n.text("Git 数据"), value: data.path) }
            if let download = receipt.retainedDownload {
                LabeledContent(L10n.text("下载位置"), value: download.path)
            }
            if let detail = receipt.detail {
                Text(detail).font(.caption).textSelection(.enabled)
            }
            Spacer()
            HStack {
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 660, height: 420).textSelection(.enabled)
            .accessibilityIdentifier("submodule-receipt-review")
    }
}

struct LFSRuleSheet: View {
    @Bindable var session: RepositorySession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors
    @State private var pattern = ""
    @State private var action = LFSRuleAction.track
    @State private var plan: LFSRulePlan?
    @State private var preparing = false
    @State private var attempted = false
    @State private var error: String?
    @State private var preparation: Task<Void, Never>?
    @FocusState private var patternFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("LFS 规则"), symbol: "externaldrive")
            Picker(L10n.text("操作"), selection: $action) {
                ForEach(LFSRuleAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(attempted || preparing).accessibilityIdentifier(
                "lfs-rule-action")
            LabeledContent(L10n.text("匹配规则")) {
                TextField("*.bin", text: $pattern).textFieldStyle(.roundedBorder).focused($patternFocused)
                    .disabled(attempted || preparing).accessibilityLabel(L10n.text("匹配规则"))
                    .accessibilityIdentifier("lfs-rule-pattern")
            }
            if let plan {
                if !plan.installation.available {
                    Text(L10n.text("当前 Git 未安装 Git LFS。规则仍可保存；不会安装工具或 Hook。"))
                        .font(.callout).foregroundStyle(colors.secondaryText).accessibilityIdentifier(
                            "lfs-rule-tool-missing")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(plan.matchedPaths) { match in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(match.path).font(.callout.monospaced()).textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Text(match.filter == "lfs" ? "LFS" : match.filter).font(.caption)
                                        .foregroundStyle(
                                            match.filter == "lfs" ? colors.positive : colors.secondaryText)
                                }
                                if let source = match.filterSource {
                                    Text(source).font(.caption).foregroundStyle(colors.secondaryText)
                                } else if match.filter != "unspecified" {
                                    Text(L10n.text("有效来源未能确认")).font(.caption).foregroundStyle(
                                        colors.secondaryText)
                                }
                            }
                        }
                        DisclosureGroup(".gitattributes · " + L10n.text("未暂存")) {
                            Text(plan.after).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        DisclosureGroup(L10n.text("规则顺序与来源")) {
                            ForEach(plan.rules) { rule in
                                Text(
                                    rule.source + ":" + String(rule.line) + "  " + rule.pattern + " "
                                        + rule.attributes
                                )
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("lfs-rule-preview")
            } else {
                Spacer(minLength: 0)
            }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel, result: session.operationFeedback,
                    context: .standard, fallback: "")
            }
            HStack {
                if preparing { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("准备预览")) }
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : attempted ? L10n.text("关闭") : L10n.text("取消")) {
                    if session.isBusy {
                        session.cancel()
                    } else {
                        preparation?.cancel()
                        dismiss()
                    }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("lfs-rule-cancel")
                if !attempted {
                    if plan == nil {
                        Button(L10n.text("预览"), action: prepare).keyboardShortcut(.defaultAction)
                            .disabled(preparing || pattern.isEmpty).accessibilityIdentifier(
                                "lfs-rule-prepare")
                    } else {
                        Button(L10n.text("保存规则"), action: execute).workbenchPrimaryAction().keyboardShortcut(
                            .defaultAction
                        )
                        .disabled(preparing || session.isBusy || !session.canWrite).accessibilityIdentifier(
                            "lfs-rule-execute")
                    }
                }
            }
        }.padding(24).frame(width: 660, height: 560).interactiveDismissDisabled(session.isBusy)
            .onChange(of: pattern + "\0" + action.rawValue) { _, _ in
                if !attempted {
                    plan = nil
                    error = nil
                }
            }
            .task { patternFocused = true }.onDisappear { preparation?.cancel() }
    }
    private func prepare() {
        guard !preparing, !attempted else { return }
        preparing = true
        error = nil
        let requested = (pattern, action)
        preparation = Task {
            defer { preparing = false }
            do {
                let value = try await session.service.prepareLFSRule(
                    pattern: requested.0, action: requested.1)
                guard !Task.isCancelled, pattern == requested.0, action == requested.1 else { return }
                plan = value
            } catch { if !Task.isCancelled { self.error = Redaction.text(error.localizedDescription) } }
        }
    }
    private func execute() {
        guard let plan, !attempted, session.canWrite, !session.isBusy else { return }
        attempted = true
        session.performResult(action.title) { service in
            do {
                _ = try await service.executeLFSRule(plan)
                return .completed(message: L10n.text("LFS 规则已保存。"))
            } catch let unknown as RecoveryOutcomeUnknown {
                return .needsReview(message: unknown.localizedDescription)
            }
        }
    }
}
