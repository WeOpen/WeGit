import SwiftUI
import WeGitCore

struct UpdateView: View {
    @Bindable var state: UpdateState
    var close: (@MainActor () -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L10n.text("软件更新")).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("关闭")) {
                    if let close { close() } else { dismiss() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("update-close")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "WeGit \(state.installed.version.rawValue)").font(.headline)
                Spacer()
                Picker(L10n.text("更新通道"), selection: $state.channel) {
                    Text(L10n.text("稳定版")).tag(UpdateChannel.stable)
                    Text(L10n.text("候选版")).tag(UpdateChannel.candidate)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 190).disabled(state.running)
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
                        .accessibilityIdentifier("update-check-again")
                }
                Spacer()
                if state.cancellable {
                    Button(L10n.text("取消")) { state.cancel() }.accessibilityIdentifier("update-cancel")
                } else if state.phase == .ready {
                    Button(L10n.text("重新启动并安装")) { state.install() }
                        .disabled(!state.installerConfigured).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("update-install")
                } else if state.update != nil, state.phase == .available || state.phase == .cancelled {
                    Button(L10n.text("下载更新")) { state.download() }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("update-download")
                } else {
                    Button(L10n.text("检查更新")) { state.check() }.disabled(state.running || !state.configured)
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("update-check")
                }
            }
        }.padding(24).frame(width: 540, height: 460)
            .onChange(of: state.channel) { _, _ in state.channelChanged() }
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
