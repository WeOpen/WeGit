import SwiftUI
import WeGitCore

struct UpdateView: View {
    @Bindable var state: UpdateState
    var close: (@MainActor () -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors
    @State private var showsRecords = false
    @State private var selectedRecordID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L10n.text("软件更新")).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("关闭")) {
                    state.cancelRetentionCleanup()
                    if let close { close() } else { dismiss() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("update-close")
            }
            Picker(L10n.text("软件更新"), selection: $showsRecords) {
                Text(L10n.text("检查更新")).tag(false)
                Text(L10n.text("更新记录")).tag(true)
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("update-pages")
            if showsRecords { records } else { updateContent }
        }.padding(24).frame(width: 600, height: 520)
            .onChange(of: state.channel) { _, _ in state.channelChanged() }
            .onChange(of: showsRecords) { _, visible in
                if visible { state.refreshRetention() }
            }
            .onChange(of: state.running) { _, running in
                if showsRecords, !running { state.refreshRetention() }
            }
            .onChange(of: state.retainedEntries.map(\.id)) { _, ids in
                if let selectedRecordID, !ids.contains(selectedRecordID) { self.selectedRecordID = nil }
            }
            .alert(
                L10n.text("清理更新记录？"),
                isPresented: Binding(
                    get: { state.cleanupRequest != nil },
                    set: { if !$0 { state.cancelRetentionCleanup() } }),
                presenting: state.cleanupRequest
            ) { plan in
                Button(L10n.text("取消"), role: .cancel) { state.cancelRetentionCleanup() }
                Button(L10n.text("清理"), role: .destructive) { state.executeRetentionCleanup(plan) }
                    .accessibilityIdentifier("update-record-clean-confirm")
            } message: { plan in
                Text(
                    recordTitle(plan.entry) + " · " + byteCount(plan.bytes) + "\n"
                        + L10n.text("将删除此记录保留的文件，无法撤销。"))
            }
    }

    private var updateContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "WeGit \(state.installed.version.rawValue)").font(.headline)
                Spacer()
                Picker(L10n.text("更新通道"), selection: $state.channel) {
                    Text(L10n.text("稳定版")).tag(UpdateChannel.stable)
                    Text(L10n.text("候选版")).tag(UpdateChannel.candidate)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 190).disabled(
                    state.running || state.retentionBusy
                )
                .accessibilityIdentifier("update-channel")
            }
            status
            if let update = state.update {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: "WeGit \(update.manifest.version)").font(.headline)
                    ScrollView {
                        Text(verbatim: update.manifest.releaseNotes).frame(
                            maxWidth: .infinity, alignment: .leading
                        )
                        .textSelection(.enabled)
                    }.frame(maxHeight: 210).accessibilityIdentifier("update-release-notes")
                }
            }
            if state.phase == .downloading {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(state.received), total: Double(max(1, state.expected)))
                        .accessibilityIdentifier("update-download-progress")
                    Text(
                        verbatim: ByteCountFormatter.string(fromByteCount: state.received, countStyle: .file)
                            + " / "
                            + ByteCountFormatter.string(fromByteCount: state.expected, countStyle: .file)
                    )
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let error = state.error {
                Text(verbatim: error).foregroundStyle(colors.negative).textSelection(.enabled)
                    .accessibilityIdentifier("update-error")
            }
            Spacer(minLength: 0)
            HStack {
                Link(L10n.text("官网下载"), destination: URL(string: "https://wegit.willxue.com/")!)
                if state.update != nil, !state.running {
                    Button(L10n.text("检查更新")) { state.check() }
                        .disabled(state.retentionBusy).accessibilityIdentifier("update-check-again")
                }
                Spacer()
                if state.cancellable {
                    Button(L10n.text("取消")) { state.cancel() }.accessibilityIdentifier("update-cancel")
                } else if state.phase == .ready {
                    Button(L10n.text("重新启动并安装")) { state.install() }
                        .disabled(!state.installerConfigured || state.retentionBusy).buttonStyle(
                            .borderedProminent
                        )
                        .accessibilityIdentifier("update-install")
                } else if state.update != nil, state.phase == .available || state.phase == .cancelled {
                    Button(L10n.text("下载更新")) { state.download() }.buttonStyle(.borderedProminent)
                        .disabled(state.retentionBusy).accessibilityIdentifier("update-download")
                } else {
                    Button(L10n.text("检查更新")) { state.check() }.disabled(
                        state.running || state.retentionBusy || !state.configured
                    )
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("update-check")
                }
            }
        }
    }

    private var selectedRecord: UpdateRetentionEntry? {
        state.retainedEntries.first { $0.id == selectedRecordID }
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(byteCount(state.retentionInventory?.totalBytes)).font(.callout.monospacedDigit())
                    .foregroundStyle(colors.secondaryText).accessibilityIdentifier("update-record-total")
                Spacer()
                if state.retentionPhase != .idle {
                    ProgressView().controlSize(.small).accessibilityLabel(retentionActivity)
                }
                Button(L10n.text("刷新")) { state.refreshRetention() }
                    .disabled(!state.canManageRetention).accessibilityIdentifier("update-record-refresh")
            }
            if state.retainedEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox").font(.system(size: 28)).accessibilityHidden(true)
                    if state.running {
                        Text(L10n.text("更新操作结束后可读取记录"))
                    } else if state.retentionPhase == .loading {
                        Text(L10n.text("正在读取更新记录…"))
                    } else if state.retentionError != nil {
                        Text(L10n.text("无法读取更新记录"))
                    } else {
                        Text(L10n.text("暂无更新记录"))
                    }
                }.foregroundStyle(colors.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("update-record-empty")
            } else {
                List(selection: $selectedRecordID) {
                    ForEach(state.retainedEntries) { entry in
                        retentionRow(entry).tag(entry.id)
                            .listRowBackground(
                                selectedRecordID == entry.id ? colors.selectionBackground : colors.surface)
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden).background(colors.surface)
                    .accessibilityIdentifier("update-record-list")
            }
            if let error = state.retentionError {
                Text(verbatim: error).foregroundStyle(colors.negative).font(.callout)
                    .textSelection(.enabled).accessibilityIdentifier("update-record-error")
            } else if let entry = selectedRecord, let reason = retentionReason(entry) {
                Text(reason).foregroundStyle(colors.secondaryText).font(.callout)
                    .accessibilityIdentifier("update-record-reason")
            } else if state.retentionInventory?.capacityBlocked == true {
                Text(L10n.text("请先处理保留记录，再准备新更新。"))
                    .foregroundStyle(colors.secondaryText).font(.callout)
            }
            HStack(spacing: 12) {
                Button(L10n.text("在 Finder 中查看")) {
                    if let selectedRecord { state.revealRetention(selectedRecord) }
                }.disabled(selectedRecord == nil || state.retentionBusy)
                    .accessibilityIdentifier("update-record-reveal")
                Button(L10n.text("导出诊断…")) { state.exportRetentionDiagnostics() }
                    .disabled(state.retentionInventory == nil || !state.canManageRetention)
                    .accessibilityIdentifier("update-record-export")
                Spacer()
                Button(L10n.text("清理…")) {
                    if let selectedRecord { state.prepareRetentionCleanup(selectedRecord) }
                }.disabled(selectedRecord?.canClean != true || !state.canManageRetention)
                    .accessibilityIdentifier("update-record-clean")
            }
        }
    }

    private func retentionRow(_ entry: UpdateRetentionEntry) -> some View {
        let selected = selectedRecordID == entry.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(recordTitle(entry)).font(.headline).lineLimit(1)
                Spacer(minLength: 12)
                Text(
                    entry.state == .blocked && entry.canClean
                        ? L10n.text("已中止") : retentionStatus(entry.state)
                ).font(.callout).lineLimit(1)
            }.foregroundStyle(selected ? colors.selectionText : colors.text)
            HStack {
                if let created = entry.created {
                    Text(created, format: .dateTime.year().month().day().hour().minute())
                } else {
                    Text(L10n.text("时间未知"))
                }
                Spacer()
                Text(byteCount(entry.bytes)).monospacedDigit()
            }.font(.caption).foregroundStyle(selected ? colors.selectionText : colors.secondaryText)
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
            .accessibilityIdentifier("update-record-" + entry.id)
    }

    private func recordTitle(_ entry: UpdateRetentionEntry) -> String {
        if let version = entry.version { return "WeGit " + version }
        return L10n.text("未识别的记录") + " · " + String(entry.id.suffix(8))
    }

    private func byteCount(_ bytes: Int64?) -> String {
        guard let bytes else { return L10n.text("大小未知") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var retentionActivity: String {
        switch state.retentionPhase {
        case .idle: L10n.text("更新记录")
        case .loading: L10n.text("正在读取更新记录…")
        case .preparing: L10n.text("正在核对记录…")
        case .cleaning: L10n.text("正在清理记录…")
        }
    }

    private func retentionStatus(_ status: UpdateRetentionState) -> String {
        switch status {
        case .preparing: L10n.text("准备未完成")
        case .prepared: L10n.text("等待安装")
        case .awaitingLaunch: L10n.text("等待启动核对")
        case .completed: L10n.text("已完成")
        case .rolledBack: L10n.text("已回退")
        case .blocked: L10n.text("需要核对")
        case .unverified: L10n.text("未验证")
        case .busy: L10n.text("正在使用")
        }
    }

    private func retentionReason(_ entry: UpdateRetentionEntry) -> String? {
        guard !entry.canClean else { return nil }
        switch entry.detail {
        case "verification-failed": return L10n.text("无法验证此记录，请先在 Finder 中核对。")
        case "preparation-incomplete": return L10n.text("准备过程尚未完成，保留现有文件。")
        case "active-transaction": return L10n.text("安装器仍在使用此记录。")
        case "recovery-required": return L10n.text("恢复尚未完成，暂不可清理。")
        case "retained-files-changed": return L10n.text("保留文件已变化，请先在 Finder 中核对。")
        case "capacity-unknown": return L10n.text("无法完整读取此记录，请先在 Finder 中核对。")
        default: return nil
        }
    }

    @ViewBuilder private var status: some View {
        if !state.configured {
            Text(L10n.text("更新验证公钥尚未配置，请使用官网下载。"))
        } else {
            switch state.phase {
            case .checking, .installing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(state.phase == .checking ? L10n.text("正在检查更新…") : L10n.text("正在准备安装…"))
                }
            case .current: Label(L10n.text("已是最新版本"), systemImage: "checkmark.circle")
            case .ready:
                Text(state.installerConfigured ? L10n.text("更新已校验，可以安装。") : L10n.text("安装器尚未配置，请使用官网下载。"))
            case .handedOff: Text(L10n.text("更新已交给安装器。"))
            case .cancelled: Text(L10n.text("更新已取消。"))
            default: EmptyView()
            }
        }
    }
}
