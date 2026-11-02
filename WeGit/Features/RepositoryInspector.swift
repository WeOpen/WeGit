import AppKit
import SwiftUI
import WeGitCore

/// Selection details share the visible diff's state; opening this pane performs no Git reads.
struct RepositoryInspector: View {
    private enum InspectorTab: Hashable {
        case file, commit, resources
    }

    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @State private var tab: InspectorTab = .file
    @State private var submodules: [SubmoduleStatus] = []
    @State private var lfsObjects: [LFSObjectStatus] = []
    @State private var resourceError: String?
    @State private var resourceRefreshID = UUID()

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
                    GlassTab(value: .file, title: L10n.text("文件信息")),
                    GlassTab(value: .commit, title: L10n.text("提交信息")),
                    GlassTab(value: .resources, title: L10n.text("仓库资源")),
                ],
                identifier: "inspector-tabs"
            ).padding(12)
            if tab == .resources {
                resourcesView
            } else if let comparison, let inspection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if tab == .commit {
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
                }.frame(maxHeight: tab == .commit ? 280 : 250)
                Divider()
                InspectorCommitFiles(detail: inspection.detail)
            } else if let diff = workingDiff {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if tab == .commit {
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
            .task(id: "\(session.id):\(session.statusRenderID):\(tab):\(resourceRefreshID)") {
                guard tab == .resources else { return }
                await loadResources()
            }
    }

    private var resourcesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                resourceSectionTitle(L10n.text("子模块"), symbol: "shippingbox")
                if submodules.isEmpty {
                    Text(L10n.text("没有配置子模块")).foregroundStyle(colors.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(submodules) { module in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(module.path).font(.system(.body, design: .monospaced))
                                        .lineLimit(2).textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Text(submoduleTitle(module.state)).font(.caption)
                                        .foregroundStyle(submoduleColor(module.state))
                                }
                                if let oid = module.actualOID ?? module.recordedOID {
                                    Text(String(oid.prefix(12))).font(.caption.monospaced())
                                        .foregroundStyle(colors.secondaryText)
                                }
                                HStack {
                                    Spacer(minLength: 0)
                                    if let recorded = module.recordedOID,
                                        module.state == .uninitialized || module.state == .childChanged
                                    {
                                        Button(L10n.text("初始化/更新")) {
                                            session.perform(L10n.text("更新子模块")) {
                                                try await $0.initializeOrUpdateSubmodule(
                                                    path: module.path, expectedOID: recorded)
                                            }
                                        }.disabled(!session.canWrite || session.isBusy)
                                            .accessibilityIdentifier(
                                                "inspector-submodule-update:" + module.path)
                                    }
                                }
                            }.padding(10).background(colors.canvas, in: .rect(cornerRadius: 8))
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("inspector-submodule:" + module.path)
                        }
                    }
                }

                Divider()
                resourceSectionTitle("Git LFS", symbol: "externaldrive")
                if lfsObjects.isEmpty {
                    Text(L10n.text("没有 LFS 指针")).foregroundStyle(colors.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(lfsObjects) { object in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(object.path).font(.system(.body, design: .monospaced))
                                        .lineLimit(2).textSelection(.enabled)
                                    Spacer(minLength: 8)
                                    Text(lfsTitle(object)).font(.caption)
                                        .foregroundStyle(
                                            object.objectAvailable ? colors.positive : colors.secondaryText)
                                }
                                if let size = object.size {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(.caption).foregroundStyle(colors.secondaryText)
                                }
                                HStack {
                                    if let detail = object.detail {
                                        Text(detail).font(.caption).foregroundStyle(colors.secondaryText)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    if object.isPointer, !object.objectAvailable,
                                        object.workingTreeHydrated != true
                                    {
                                        Button(L10n.text("获取对象")) {
                                            session.perform(
                                                L10n.text("获取 LFS 对象"),
                                                onSuccess: {
                                                    resourceRefreshID = UUID()
                                                },
                                                operation: {
                                                    try await $0.fetchLFS(
                                                        path: object.path, expectedOID: object.oid)
                                                })
                                        }.disabled(!session.canWrite || session.isBusy)
                                            .accessibilityIdentifier("inspector-lfs-fetch:" + object.path)
                                    }
                                }
                            }.padding(10).background(colors.canvas, in: .rect(cornerRadius: 8))
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("inspector-lfs:" + object.path)
                        }
                    }
                }
                if let resourceError {
                    Text(resourceError).font(.caption).foregroundStyle(colors.negative)
                        .textSelection(.enabled).accessibilityIdentifier("inspector-resources-error")
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("inspector-resources")
    }

    private func resourceSectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.headline)
    }

    private func loadResources() async {
        guard !Task.isCancelled else { return }
        let renderID = session.statusRenderID
        var modules: [SubmoduleStatus] = []
        var objects: [LFSObjectStatus] = []
        var failure: String?
        do {
            modules = try await session.service.submodules()
        } catch {
            failure = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        do {
            objects = try await session.service.lfsObjects()
        } catch {
            failure = failure ?? error.localizedDescription
        }
        guard !Task.isCancelled, renderID == session.statusRenderID, tab == .resources else { return }
        submodules = modules
        lfsObjects = objects
        resourceError = failure
    }

    private func submoduleTitle(_ state: SubmoduleState) -> String {
        switch state {
        case .uninitialized: L10n.text("未初始化")
        case .clean: L10n.text("干净")
        case .dirty: L10n.text("有改动")
        case .stagedChange: L10n.text("暂存指向变化")
        case .childChanged: L10n.text("子模块指向已变化")
        case .invalid: L10n.text("状态无效")
        }
    }

    private func submoduleColor(_ state: SubmoduleState) -> Color {
        switch state {
        case .clean: colors.positive
        case .invalid, .dirty: colors.negative
        default: colors.secondaryText
        }
    }

    private func lfsTitle(_ object: LFSObjectStatus) -> String {
        if object.workingTreeHydrated == true { return L10n.text("已水合") }
        if object.objectAvailable { return L10n.text("对象已缓存") }
        if object.workingTreeHydrated == false { return L10n.text("指针文件") }
        return L10n.text("状态未知")
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
