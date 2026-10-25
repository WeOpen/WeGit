import AppKit
import SwiftUI
import WeGitCore

/// Selection details share the visible diff's state; opening this pane performs no Git reads.
struct RepositoryInspector: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @State private var tab = false

    private var inspection: CommitInspection? {
        guard let value = app.workspace.commitInspection,
            value.sessionID == session.id, value.route == app.workspace.route,
            app.workspace.route != .history
                || value.detail.comparison?.commit.id == app.workspace.selectedCommit?.id
        else { return nil }
        return value
    }
    private var comparison: CommitComparison? { inspection?.detail.comparison }
    private var commitFile: CommitFileChange? {
        comparison?.files.first { $0.path == inspection?.detail.selectedPath }
    }
    private var workingDiff: FileDiff? {
        guard app.workspace.route == .changes, !app.workspace.loadingDiff,
            let diff = app.workspace.diff,
            app.workspace.selectedFile == diff.layer.rawValue + "|" + diff.path
        else { return nil }
        return diff
    }
    private var display: DiffDisplayState? {
        if app.workspace.route == .changes { return workingDiff == nil ? nil : app.workspace.diffDisplay }
        return inspection?.detail.display
    }
    private var workingSelection: (file: FileChange, layer: DiffLayer)? {
        guard app.workspace.route == .changes, let selection = app.workspace.selectedFile,
            let divider = selection.firstIndex(of: "|"),
            let layer = DiffLayer(rawValue: String(selection[..<divider]))
        else { return nil }
        let path = String(selection[selection.index(after: divider)...])
        guard let file = session.status.files.first(where: { $0.path == path && $0.layers.contains(layer) })
        else { return nil }
        return (file, layer)
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchGlassTabs(
                title: L10n.text("检查器"), selection: $tab,
                tabs: [
                    GlassTab(value: false, title: L10n.text("文件信息")),
                    GlassTab(value: true, title: L10n.text("提交信息")),
                ],
                identifier: "inspector-tabs"
            ).padding(12)
            if let comparison, let inspection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if tab {
                            commitInfo(comparison.commit)
                        } else if let file = commitFile {
                            fileInfo(
                                path: file.path, oldPath: file.oldPath, status: String(file.status),
                                additions: file.additions, deletions: file.deletions, binary: file.binary)
                            if inspection.allowsFileHistory {
                                historyButton(path: file.path, tip: comparison.commit.id)
                            }
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: tab ? 280 : 250)
                Divider()
                InspectorCommitFiles(detail: inspection.detail)
            } else if let diff = workingDiff {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if tab {
                            // Worktree changes have no commit yet. Do not show a previously selected SHA.
                            Text(L10n.text("未提交的更改")).font(.headline)
                            repositoryInfo
                        } else {
                            let file = session.status.files.first { $0.path == diff.path }
                            fileInfo(
                                path: diff.path, oldPath: file?.oldPath,
                                status: file?.symbol(for: diff.layer),
                                additions: diff.preview == nil && !diff.binary ? display?.additions : nil,
                                deletions: diff.preview == nil && !diff.binary ? display?.deletions : nil,
                                binary: diff.binary)
                            Text(layerTitle(diff.layer)).font(.caption).foregroundStyle(colors.secondaryText)
                            HStack {
                                Button(L10n.text("外部打开"), systemImage: "arrow.up.forward.app") {
                                    NSWorkspace.shared.open(session.location.root.appending(path: diff.path))
                                }.disabled(file?.worktree == "D")
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([
                                        session.location.root.appending(path: diff.path)
                                    ])
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .accessibilityLabel(L10n.text("在 Finder 中显示"))
                            }.controlSize(.small)
                            if let file, !file.untracked {
                                historyButton(
                                    path: file.index == "R" || file.worktree == "R"
                                        ? file.oldPath ?? file.path : file.path, tip: session.status.head)
                            }
                            if let display, !diff.hunks.isEmpty { hunkList(display) }
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let selected = workingSelection, !app.workspace.loadingDiff {
                // Deferred and file-backed diffs reuse metadata without loading the file into memory.
                let summary = app.workspace.diffSummary
                let disk = app.workspace.diskDisplay?.snapshot
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        fileInfo(
                            path: selected.file.path, oldPath: selected.file.oldPath,
                            status: selected.file.symbol(for: selected.layer),
                            additions: summary?.additions
                                ?? (disk?.rawPreview == false ? disk?.additions : nil),
                            deletions: summary?.deletions
                                ?? (disk?.rawPreview == false ? disk?.deletions : nil),
                            binary: summary?.binary ?? disk?.binary ?? false)
                        Text(layerTitle(selected.layer)).font(.caption).foregroundStyle(colors.secondaryText)
                        if let bytes = summary?.fileBytes {
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(
                                .caption)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if inspection?.detail.loading == true
                || app.workspace.route == .changes && app.workspace.loadingDiff
            {
                ProgressView(L10n.text("读取中…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { repositoryInfo }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.background(colors.sidebar)
    }

    private func fileInfo(
        path: String, oldPath: String?, status: String?, additions: Int?, deletions: Int?, binary: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                FileTypeIcon(path: path)
                Text((path as NSString).lastPathComponent).font(.headline).lineLimit(2).textSelection(
                    .enabled)
                Spacer(minLength: 0)
                if let status { StatusBadge(symbol: status) }
            }
            HStack(alignment: .top) {
                Text(path).font(.caption).foregroundStyle(colors.secondaryText).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
                        "inspector-file-path")
                Spacer(minLength: 0)
                Button {
                    copy(path)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .workbenchIconButton().accessibilityLabel(L10n.text("复制文件路径"))
                .help(L10n.text("复制文件路径")).accessibilityIdentifier("inspector-copy-file-path")
            }
            if let oldPath, oldPath != path {
                Text(oldPath + " → " + path).font(.caption).foregroundStyle(colors.secondaryText)
                    .textSelection(.enabled)
            }
            if let additions, let deletions {
                DiffChangeSummary(additions: additions, deletions: deletions)
                    .accessibilityIdentifier("inspector-file-statistics")
            } else if binary {
                Text(L10n.text("二进制")).font(.caption).foregroundStyle(colors.secondaryText)
            }
        }
    }

    private func commitInfo(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(commit.subject).font(.headline).textSelection(.enabled)
            Text(commit.author + " <" + commit.authorEmail + ">").font(.caption).textSelection(.enabled)
            Text(
                commit.date.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))
            )
            .font(.caption).foregroundStyle(colors.secondaryText)
            HStack {
                Text(String(commit.id.prefix(12))).font(.caption.monospaced()).textSelection(.enabled).help(
                    commit.id)
                Button {
                    copy(commit.id)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .workbenchIconButton().accessibilityLabel(L10n.text("复制 SHA"))
            }
            DisclosureGroup(L10n.text("完整提交消息")) {
                Text(commit.message).font(.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption)
            if commit.committer != commit.author || commit.committerEmail != commit.authorEmail
                || commit.committedAt != commit.date
            {
                Text(
                    L10n.text(
                        "提交者：\(commit.committer) <\(commit.committerEmail)> · \(commit.committedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))"
                    )
                )
                .font(.caption).foregroundStyle(colors.secondaryText).textSelection(.enabled)
            }
        }.accessibilityIdentifier("inspector-commit-info")
    }

    private func historyButton(path: String, tip: String?) -> some View {
        Button(L10n.text("查看文件历史…"), systemImage: "clock.arrow.circlepath") {
            guard app.session === session else { return }
            app.fileHistoryRequest = FileHistoryRequest(session: session, path: path, tip: tip)
        }.controlSize(.small).accessibilityIdentifier("inspector-file-history")
    }

    private func hunkList(_ display: DiffDisplayState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.count("%lld 个差异块", display.diff.hunks.count)).font(.headline)
            LazyVStack(spacing: 10) {
                ForEach(Array(display.diff.hunks.enumerated()), id: \.element.id) { index, hunk in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(L10n.text("块 \(index + 1)")) { display.navigate(to: hunk.id) }
                                .disabled(display.loading || display.document == nil)
                                .accessibilityIdentifier("inspector-hunk:\(hunk.id)")
                            Spacer(minLength: 0)
                            Text(hunk.header).font(.system(size: 10, design: .monospaced))
                                .lineLimit(1).help(hunk.header).foregroundStyle(colors.secondaryText)
                        }
                        ForEach(
                            Array(
                                hunk.lines.lazy.filter { $0.kind == "+" || $0.kind == "-" }.prefix(4)
                                    .enumerated()),
                            id: \.offset
                        ) { _, line in
                            Text(String(line.kind) + " " + String(line.content.prefix(160))).font(
                                .system(size: 10, design: .monospaced)
                            )
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(line.kind == "+" ? colors.positive : colors.negative)
                        }
                        if display.diff.canApplyHunk, !display.hasMore, !display.loading,
                            app.workspace.diffOptions == display.diff.options
                        {
                            Button(display.diff.layer == .staged ? L10n.text("取消暂存此块") : L10n.text("暂存此块")) {
                                session.perform(L10n.text("暂存区更新")) {
                                    try await $0.apply(hunk: hunk, from: display.diff)
                                }
                            }.controlSize(.small).disabled(!session.canWrite)
                        }
                    }.padding(10).background(colors.canvas, in: .rect(cornerRadius: 8))
                }
            }
        }
    }

    private var repositoryInfo: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(session.location.name, systemImage: "folder").font(.headline)
            Text(session.location.root.path).font(.caption).foregroundStyle(colors.secondaryText)
                .textSelection(.enabled)
            HStack {
                Button {
                    NSWorkspace.shared.open(session.location.root)
                } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel(L10n.text("在 Finder 中显示")).accessibilityIdentifier(
                    "inspector-open-finder")
                Button(action: app.openTerminal) { Image(systemName: "terminal") }
                    .accessibilityLabel(L10n.text("在 Terminal 中打开")).accessibilityIdentifier(
                        "inspector-open-terminal")
                Button(action: app.copyRepositoryPath) { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel(L10n.text("复制仓库路径")).accessibilityIdentifier("inspector-copy-path")
            }.workbenchIconButton()
            Divider()
            LabeledContent(L10n.text("当前"), value: session.status.displayBranch)
            LabeledContent(L10n.text("上游"), value: session.status.upstream ?? L10n.text("未设置"))
            RepositorySyncSummary(session: session)
        }.font(.caption)
    }
    private func layerTitle(_ layer: DiffLayer) -> String {
        switch layer {
        case .staged: L10n.text("已暂存")
        case .unstaged: L10n.text("未暂存")
        case .untracked: L10n.text("未跟踪")
        case .conflict: L10n.text("冲突")
        case .commit: L10n.text("提交")
        }
    }
    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct InspectorCommitFiles: View {
    @Environment(\.themeColors) private var colors
    @Bindable var detail: CommitDetailState
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("提交的文件")).font(.headline)
                Spacer()
                CountBadge(value: String(detail.comparison?.files.count ?? 0), tone: .blue)
            }.padding(14)
            List(selection: $detail.selectedPath) {
                ForEach(detail.comparison?.files ?? []) { file in
                    HStack(alignment: .top, spacing: 8) {
                        StatusBadge(symbol: String(file.status))
                        VStack(alignment: .leading, spacing: 4) {
                            Text((file.path as NSString).lastPathComponent).font(
                                .system(size: 12, weight: .medium))
                            Text(file.path).font(.system(size: 10)).foregroundStyle(colors.secondaryText)
                                .lineLimit(1).truncationMode(.middle)
                            if let added = file.additions, let removed = file.deletions {
                                HStack(spacing: 8) {
                                    Text("+\(added)").foregroundStyle(colors.positive)
                                    Text("−\(removed)").foregroundStyle(colors.negative)
                                }.font(.system(size: 10, design: .monospaced))
                            } else if file.binary {
                                Text(L10n.text("二进制")).font(.caption).foregroundStyle(colors.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 3).tag(file.path).help(file.path)
                        .accessibilityIdentifier("inspector-commit-file:" + file.path)
                }
            }.listStyle(.inset).scrollContentBackground(.hidden).background(colors.sidebar)
                .accessibilityIdentifier("inspector-commit-files")
        }
    }
}
