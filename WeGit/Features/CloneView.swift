import AppKit
import SwiftUI
import WeGitCore

@MainActor
struct CloneView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Bindable var model: CloneViewModel
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .caption) private var destinationHeight: CGFloat = 34
    init(app: AppState) {
        self.app = app
        self.model = app.clone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetTitle(title: L10n.text("克隆仓库"), symbol: "arrow.down.to.line")
            Text(L10n.text("优先复用系统 Git 凭证或 SSH Agent；需要输入时会打开独立认证窗口。"))
                .font(.callout).foregroundStyle(colors.secondaryText)
            Form {
                TextField(L10n.text("仓库地址"), text: $model.address).accessibilityIdentifier("clone-url")
                TextField(L10n.text("文件夹名称"), text: $model.folderName).accessibilityIdentifier("clone-folder")
                HStack {
                    TextField(L10n.text("保存目录"), text: $model.parentPath).accessibilityIdentifier(
                        "clone-parent")
                    Button(L10n.text("选择…"), action: chooseParent)
                }
            }.autocorrectionDisabled().disabled(model.isBusy)
            Text(model.destination).font(.caption.monospaced()).foregroundStyle(colors.secondaryText)
                .lineLimit(2, reservesSpace: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: destinationHeight, alignment: .topLeading)

            if model.isBusy { progress }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(
                    colors.negative
                )
                .accessibilityIdentifier("clone-error")
            }
            if let failure = model.failure, let retained = failure.retainedDirectory {
                recovery(failure, retained: retained)
            }
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(
                    colors.secondaryText)
            }
            if let details = model.failure?.details, !details.isEmpty {
                DisclosureGroup(L10n.text("查看脱敏详情")) {
                    ScrollView {
                        Text(details).font(.caption.monospaced()).textSelection(.enabled).frame(
                            maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                }.font(.caption)
            }
            HStack {
                Spacer()
                Button(model.isBusy ? L10n.text("取消操作") : L10n.text("关闭")) {
                    if model.isBusy { model.cancel() } else { dismiss() }
                }
                .accessibilityIdentifier("clone-cancel")
                .keyboardShortcut(.cancelAction)
                .disabled(model.phase == .cancelling || model.phase == .cleaning || model.phase == .opening)
                Button(model.phase == .failed ? L10n.text("重试克隆") : L10n.text("克隆")) {
                    model.start { location in
                        await app.open(location.root)
                        if app.session?.location.root == location.root { dismiss() }
                    }
                }.workbenchPrimaryAction().tint(colors.primaryAction).disabled(
                    !model.canStart || app.preferences.configurationWriteInProgress
                ).accessibilityIdentifier(
                    "clone-start")
            }
        }.padding(26).frame(width: 590).interactiveDismissDisabled(model.isBusy)
            .onChange(of: model.address) { _, _ in model.updateSuggestion() }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.phase == .cloning {
                HStack {
                    Text(model.progress.stage.title).font(.callout.weight(.medium))
                        .accessibilityIdentifier("clone-stage")
                    Spacer()
                    if let fraction = model.progress.fraction {
                        Text(L10n.text("当前阶段 \(Int((fraction * 100).rounded()))%"))
                            .font(.caption.monospacedDigit()).foregroundStyle(colors.secondaryText)
                    }
                }
                if let fraction = model.progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                ProgressView(
                    model.phase == .cancelling
                        ? L10n.text("正在停止 Git，请稍候…")
                        : model.phase == .opening ? L10n.text("正在打开仓库…") : L10n.text("正在移到废纸篓…"))
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .workbenchSurface()
    }

    private func recovery(_ failure: CloneFailure, retained: URL) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.text("未完成目录已保留")).font(.callout.weight(.medium))
            Text(retained.path).font(.caption).textSelection(.enabled)
            HStack {
                Button(L10n.text("在 Finder 中检查")) {
                    NSWorkspace.shared.activateFileViewerSelecting([retained])
                }
                if failure.cleanup != nil {
                    Button(L10n.text("移到废纸篓…"), role: .destructive) {
                        if app.confirm(
                            title: L10n.text("将未完成的克隆移到废纸篓？"),
                            message: L10n.text("目录：\(retained.path)\n仅处理本次新建目录；如果内容已变化，将保留目录并停止清理。"),
                            action: L10n.text("移到废纸篓"))
                        {
                            model.cleanUp()
                        }
                    }.accessibilityIdentifier("clone-cleanup")
                } else {
                    Text(L10n.text("无法安全核对目录，请在 Finder 中处理。")).font(.caption).foregroundStyle(
                        colors.secondaryText)
                }
            }.disabled(model.isBusy)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .workbenchSurface()
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: model.parentPath)
        if panel.runModal() == .OK, let url = panel.url { model.parentPath = url.path }
    }
}
