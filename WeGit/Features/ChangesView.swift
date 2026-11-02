import AppKit
import SwiftUI
import WeGitCore

struct ChangesView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    var leadingInset: CGFloat = 0
    @State private var preparingRemoval = false
    @State private var removalTask: Task<Void, Never>?
    @State private var preparingDiscard = false
    @State private var discardTask: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    PanelHeader(title: L10n.text("更改"), symbol: "square.and.pencil") {
                        CountBadge(
                            value:
                                app.workspace.changeFilter == .all && app.workspace.filter.isEmpty
                                ? "\(session.status.files.count)"
                                : "\(app.workspace.fileFilter.visiblePathCount(session.status.files))/\(session.status.files.count)"
                        ).help(L10n.text("匹配路径 / 仓库全部改动路径；同一路径不重复计数"))
                        if preparingRemoval { ProgressView().controlSize(.small).help(L10n.text("检查未跟踪文件…")) }
                        if preparingDiscard { ProgressView().controlSize(.small).help(L10n.text("检查未暂存改动…")) }
                        Spacer()
                        Menu {
                            Picker(L10n.text("显示方式"), selection: $app.workspace.changesByFolder) {
                                Text(L10n.text("文件列表")).tag(false)
                                Text(L10n.text("按文件夹显示")).tag(true)
                            }
                        } label: {
                            Label(
                                L10n.text("显示方式"),
                                systemImage: app.workspace.changesByFolder ? "folder" : "list.bullet")
                        }.workbenchGlassMenu(icon: true).accessibilityIdentifier("changes-display-mode")
                            .help(L10n.text("切换文件列表或按文件夹显示"))
                        Menu {
                            Button(L10n.text("暂存全部"), action: app.stageAll).disabled(!app.canStageAll)
                                .help(L10n.text("暂存当前仓库全部适用文件，不受筛选影响，不自动标记冲突解决"))
                            Button(L10n.text("取消全部暂存"), action: app.unstageAll).disabled(!app.canUnstageAll)
                        } label: {
                            Image(systemName: "ellipsis")
                        }.workbenchGlassMenu(icon: true).disabled(!session.canWrite)
                    }
                    HStack {
                        WorkbenchSearchField(
                            prompt: L10n.text("筛选文件路径"), text: $app.workspace.filter,
                            identifier: "changes-filter")
                        Picker(L10n.text("改动状态"), selection: $app.workspace.changeFilter) {
                            ForEach(ChangeKindFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 110).tint(colors.accentText)
                            .accessibilityIdentifier("changes-state-filter")
                    }.padding(.horizontal, 12).padding(.bottom, 10).background(colors.chrome)
                    Divider()
                    if let error = session.refreshError, !session.hasLoaded {
                        EmptyPanel(
                            title: L10n.text("无法读取仓库"), symbol: "exclamationmark.triangle", message: error)
                    } else if !session.hasLoaded {
                        ProgressView(L10n.text("读取仓库状态…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if session.status.files.isEmpty {
                        EmptyPanel(
                            title: session.isStale ? L10n.text("等待重新核对仓库") : L10n.text("工作区干净"),
                            symbol: "checkmark.circle",
                            message: session.isStale
                                ? L10n.text("上次读取时没有未提交改动，请刷新确认当前状态。") : "")
                    } else if app.workspace.fileFilter.visiblePathCount(session.status.files) == 0 {
                        VStack {
                            EmptyPanel(
                                title: L10n.text("没有匹配文件"), symbol: "line.3.horizontal.decrease.circle",
                                message: L10n.text("当前仓库仍有改动，请调整路径或状态筛选。"))
                            Button(L10n.text("清除筛选")) {
                                app.workspace.filter = ""
                                app.workspace.changeFilter = .all
                            }.padding(.bottom, 18)
                        }
                    } else {
                        ChangesFileList(
                            files: session.status.files, filter: app.workspace.fileFilter,
                            byFolder: app.workspace.changesByFolder,
                            showFileIcons: app.preferences.showFileIcons,
                            compact: app.preferences.density == "compact", canWrite: session.canWrite,
                            writeReason: session.writeReason, selection: $app.workspace.selectedFile,
                            collapsedGroups: $app.workspace.collapsedChangeGroups,
                            collapsedFolders: $app.workspace.collapsedChangeFolders,
                            stage: stageFiles,
                            editConflict: editConflict
                        ) { file, layer in fileMenu(file, layer: layer) }
                    }
                }.frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
                DiffView(app: app, session: session)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            composer.padding(.leading, leadingInset)
        }
        .background(
            ViewPerformanceProbe(
                spans: [ViewPerformanceSpan(name: "status", id: session.statusRenderID)]
                    + (session.watcherRenderID.map { [ViewPerformanceSpan(name: "watcher", id: $0)] } ?? []))
        )
        .task(
            id:
                "\(session.id):\(session.diffGeneration):\(app.workspace.selectedFile ?? ""):\(app.workspace.diffOptions.contextLines):\(app.workspace.diffOptions.ignoreWhitespace)"
        ) {
            await app.loadDiff()
        }
        .onChange(of: app.workspace.filter) { _, _ in clearHiddenSelection() }
        .onChange(of: app.workspace.changeFilter) { _, _ in clearHiddenSelection() }
        .onChange(of: app.workspace.changesByFolder) { _, _ in app.saveCurrentWorkspace() }
        .onDisappear {
            app.workspace.diffDisplay?.cancelAll()
            app.workspace.diskDisplay?.cancelAll()
            removalTask?.cancel()
            discardTask?.cancel()
        }
    }

    @ViewBuilder private func fileMenu(_ file: FileChange, layer: DiffLayer) -> some View {
        if layer == .conflict {
            Button(L10n.text("编辑冲突…"), systemImage: "square.and.pencil") {
                editConflict(file)
            }.disabled(!session.canWrite)
            Divider()
        }
        Button(
            layer == .staged
                ? L10n.text("取消暂存")
                : layer == .conflict ? L10n.text("标记已解决…") : L10n.text("暂存文件")
        ) { stageAction(file, layer: layer) }.disabled(!session.canWrite)
        Divider()
        FileContextMenu(
            app: app, session: session, path: file.path,
            historyPath: file.index == "R" || file.worktree == "R" ? file.oldPath : nil)
        if layer == .unstaged {
            Divider()
            Button(L10n.text("丢弃未暂存改动…"), role: .destructive) { discardFile(file) }
                .disabled(!session.canWrite || preparingDiscard || preparingRemoval)
                .accessibilityIdentifier("discard-file:" + file.path)
        }
        if layer == .untracked {
            Divider()
            Button(L10n.text("移到废纸篓…"), role: .destructive) { removeUntracked(file) }
                .disabled(!session.canWrite || preparingRemoval || preparingDiscard)
                .accessibilityIdentifier("trash-untracked:" + file.path)
        }
    }

    private func stageFiles(_ files: [FileChange], layer: DiffLayer) {
        guard app.session === session, session.canWrite, !files.isEmpty else { return }
        if files.count == 1 {
            stageAction(files[0], layer: layer)
            return
        }
        // Batch operations retain the visible files, never a folder path or conflict.
        let current = Set(session.status.files)
        guard layer != .conflict,
            files.allSatisfy({ current.contains($0) && $0.layers.contains(layer) && !$0.conflict })
        else { return }
        let head = session.status.head
        let paths = files.map(\.path)
        if layer == .staged {
            session.perform(L10n.text("取消暂存")) { try await $0.unstage(paths: paths, expectedHead: head) }
        } else {
            session.perform(L10n.text("暂存文件")) { try await $0.stage(paths: paths, expectedHead: head) }
        }
    }

    private func stageAction(_ file: FileChange, layer: DiffLayer) {
        guard app.session === session, session.canWrite else { return }
        let head = session.status.head
        if layer == .staged {
            session.perform(L10n.text("取消暂存")) {
                try await $0.unstage(paths: [file.path], expectedHead: head)
            }
        } else if layer == .conflict {
            if app.confirm(
                title: L10n.text("标记已解决？"),
                message: L10n.text("请先在外部编辑器中保存 \(file.path) 的正确结果。此操作将把当前文件加入暂存区。"),
                action: L10n.text("标记已解决"), destructive: false)
            {
                session.perform(L10n.text("标记已解决")) {
                    try await $0.markResolved(path: file.path, expectedHead: head)
                }
            }
        } else {
            session.perform(L10n.text("暂存文件")) { try await $0.stage(paths: [file.path], expectedHead: head) }
        }
    }

    private func editConflict(_ file: FileChange) {
        guard app.session === session, session.canWrite, file.conflict else { return }
        app.conflictEditorRequest = ConflictEditorRequest(
            session: session, path: file.path, expectedHead: session.status.head)
    }

    private func clearHiddenSelection() {
        guard let selection = app.workspace.selectedFile, let delimiter = selection.firstIndex(of: "|"),
            let layer = DiffLayer(rawValue: String(selection[..<delimiter]))
        else { return }
        let path = String(selection[selection.index(after: delimiter)...])
        if !session.status.files.contains(where: {
            $0.path == path && app.workspace.fileFilter.matches($0, layer: layer)
        }) {
            app.workspace.selectedFile = nil
        }
    }

    private func removeUntracked(_ file: FileChange) {
        guard !preparingRemoval && !preparingDiscard && session.canWrite else { return }
        preparingRemoval = true
        let head = session.status.head
        removalTask = Task {
            defer {
                preparingRemoval = false
                removalTask = nil
            }
            do {
                let removal = try await session.service.prepareUntrackedRemoval(
                    path: file.path, expectedHead: head)
                guard app.session === session, !Task.isCancelled else { return }
                let size = ByteCountFormatter.string(fromByteCount: removal.byteCount, countStyle: .file)
                let link = removal.symbolicLink ? L10n.text("\n只移动符号链接本身，不影响链接目标。") : ""
                if app.confirm(
                    title: L10n.text("将未跟踪文件移到废纸篓？"),
                    message: L10n.text("文件：\(removal.path)\n大小：\(size)\(link)\n文件尚未被 Git 跟踪，移除后可从废纸篓恢复。"),
                    action: L10n.text("移到废纸篓"))
                {
                    session.lastTrashedFile = nil
                    session.perform(L10n.text("移到废纸篓")) {
                        let receipt = try await $0.trashUntracked(removal)
                        await MainActor.run { session.lastTrashedFile = receipt.trashURL }
                    }
                }
            } catch {
                if app.session === session && !Task.isCancelled { session.show(error) }
            }
        }
    }

    private func discardFile(_ file: FileChange) {
        guard session.canWrite, !preparingDiscard, !preparingRemoval else { return }
        preparingDiscard = true
        let branch = session.status.branch
        discardTask = Task {
            defer {
                preparingDiscard = false
                discardTask = nil
            }
            do {
                let service = session.service.expectingBranch(branch)
                let result = try await service.readDiff(path: file.path, layer: .unstaged, loadLarge: true)
                guard app.session === session, !Task.isCancelled else { return }
                if case .deferred(_, let limit) = result {
                    throw ModelFailure.unsupported(
                        limit?.localizedDescription ?? L10n.text("无法完整核对该文件，请在外部处理。"))
                }
                guard
                    app.confirm(
                        title: L10n.text("丢弃文件的未暂存改动？"),
                        message:
                            L10n.text(
                                "分支：\(branch)\n文件：\(file.path)\n将把工作区内容恢复为暂存区版本，包括空白改动。已暂存内容保留，未提交的工作区改动可能无法恢复。"
                            ),
                        action: L10n.text("丢弃未暂存改动"))
                else { return }
                session.perform(L10n.text("丢弃未暂存改动")) { current in
                    let service = current.expectingBranch(branch)
                    switch result {
                    case .loaded(let diff): try await service.discard(diff)
                    case .disk(let snapshot): try await service.discard(snapshot)
                    case .deferred: throw ModelFailure.changed
                    }
                }
            } catch { if !Task.isCancelled { session.show(error) } }
        }
    }

    private var composer: some View {
        let stagedCount = session.status.files.lazy.filter(\.staged).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                WorkbenchMessageField(message: $session.message)
                VStack(spacing: 6) {
                    Button {
                        app.commitCurrent()
                    } label: {
                        Text(session.amend ? L10n.text("修改提交") : L10n.count("提交（%lld 个文件）", stagedCount))
                            .frame(maxWidth: .infinity)
                    }.workbenchPrimaryAction()
                        .tint(colors.primaryAction).disabled(
                            !session.canCommit
                        )
                        .accessibilityIdentifier("commit-button")
                        .help(session.canCommit ? L10n.text("提交已暂存内容 ⌘↩") : session.commitReason)
                    Button {
                        app.presentSync(.commitAndPush)
                    } label: {
                        Text(L10n.text("提交并推送…")).frame(maxWidth: .infinity)
                    }.workbenchControlFamily()
                        .disabled(!session.canCommitAndPush).accessibilityIdentifier("commit-push-button")
                        .help(
                            session.canCommitAndPush
                                ? L10n.text("先提交本地改动，再推送到指定远端")
                                : session.canCommit ? session.syncReason : session.commitReason)
                }.frame(width: 168)
            }
            HStack(spacing: 10) {
                CommitReadiness(count: stagedCount)
                Toggle(L10n.text("修改上次提交（Amend）"), isOn: $session.amend).toggleStyle(.checkbox).disabled(
                    session.status.head == nil || session.isBusy
                )
                .accessibilityIdentifier("commit-amend")
                .onChange(of: session.amend) { _, new in
                    if new && session.message.isEmpty {
                        Task {
                            do {
                                let commits = try await session.service.history(
                                    limit: 1, tips: session.status.head.map { [$0] })
                                if session.amend && session.message.isEmpty {
                                    session.message = commits.first?.message ?? ""
                                }
                            } catch { session.show(error) }
                        }
                    }
                }
                Spacer()
                if let path = session.lastTrashedFile {
                    Button(L10n.text("查看废纸篓中的文件")) { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                        .font(.caption).disabled(session.isBusy).accessibilityIdentifier("show-trashed-file")
                        .accessibilityValue(path.path)
                }
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel, result: session.operationFeedback,
                    context: session.operationFeedbackContext,
                    fallback: session.canCommit ? L10n.text("⌥↩ 换行 · ⌘↩ 提交") : session.commitReason)
            }
        }.padding(16).background(colors.chrome)
            .overlay(alignment: .top) {
                Rectangle().fill(colors.border)
                    .frame(height: 1).allowsHitTesting(false)
            }
    }
}

struct DiffView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    var body: some View {
        VStack(spacing: 0) {
            if app.workspace.refreshingDiff {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在核对差异…")).font(.caption)
                    Spacer()
                    Button(L10n.text("取消核对")) { app.cancelDiffRead() }
                }.padding(8).background(colors.chrome).accessibilityIdentifier("diff-refresh-progress")
            }
            if let notice = app.workspace.diffReadNotice {
                Text(notice).font(.caption).foregroundStyle(colors.secondaryText).padding(8)
            }
            if app.workspace.loadingDiff {
                VStack(spacing: 16) {
                    ProgressView(L10n.text("读取差异…"))
                    Button(L10n.text("取消读取")) { app.cancelDiffRead() }.accessibilityIdentifier(
                        "diff-cancel-read")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = app.workspace.diffError {
                VStack {
                    EmptyPanel(title: L10n.text("无法读取差异"), symbol: "exclamationmark.triangle", message: error)
                    HStack {
                        Button(L10n.text("重试")) { Task { await app.loadDiff() } }
                        Button(L10n.text("恢复默认差异选项")) { app.workspace.diffOptions = DiffReadOptions() }
                    }.padding(.bottom, 20)
                }
            } else if let summary = app.workspace.diffSummary {
                summaryView(summary)
            } else if app.workspace.diffCancelled {
                VStack {
                    EmptyPanel(
                        title: L10n.text("已取消读取"), symbol: "pause.circle",
                        message: L10n.text("可随时重新读取这个文件的差异。"))
                    Button(L10n.text("重新读取")) { Task { await app.loadDiff() } }.padding(.bottom, 20)
                }
            } else if let display = app.workspace.diskDisplay {
                DiskDiffView(app: app, session: session, display: display).id(ObjectIdentifier(display))
            } else if let diff = app.workspace.diff, let display = app.workspace.diffDisplay {
                HStack(spacing: 12) {
                    if app.workspace.inspector {
                        Text((diff.path as NSString).lastPathComponent).font(
                            .system(size: 12, weight: .medium)
                        )
                        .lineLimit(1).truncationMode(.middle).help(diff.path)
                        Spacer(minLength: 0)
                    } else {
                        DetailHeader(title: diff.path, subtitle: subtitle(diff.layer))
                    }
                    if !app.workspace.inspector, diff.preview == nil && !diff.binary {
                        DiffChangeSummary(additions: display.additions, deletions: display.deletions)
                    } else if !app.workspace.inspector {
                        Text(diff.binary ? L10n.text("二进制") : L10n.text("内容预览")).foregroundStyle(
                            colors.secondaryText)
                    }
                    WorkbenchGlassTabs(
                        title: L10n.text("差异布局"), selection: $app.workspace.splitDiff,
                        tabs: [
                            GlassTab(value: false, title: L10n.text("统一")),
                            GlassTab(value: true, title: L10n.text("分栏")),
                        ],
                        identifier: "diff-layout"
                    ).frame(width: 110)
                    if app.workspace.inspector {
                        Menu(L10n.text("阅读选项")) {
                            Picker(L10n.text("上下文"), selection: $app.workspace.diffOptions.contextLines) {
                                ForEach([3, 20, 80, 200], id: \.self) {
                                    Text(L10n.count("%lld 行", $0)).tag($0)
                                }
                            }
                            Toggle(L10n.text("忽略空白"), isOn: $app.workspace.diffOptions.ignoreWhitespace)
                            Toggle(L10n.text("词级差异"), isOn: $app.workspace.wordDiff)
                        }.fixedSize().tint(colors.accentText)
                    }
                    Menu {
                        if !diff.binary {
                            Button(diff.preview == nil ? L10n.text("复制完整补丁") : L10n.text("复制完整内容")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    String(decoding: diff.raw, as: UTF8.self), forType: .string)
                            }
                        }
                        Button(L10n.text("外部打开")) {
                            NSWorkspace.shared.open(session.location.root.appending(path: diff.path))
                        }
                        if diff.layer == .unstaged && !diff.options.ignoreWhitespace {
                            Button(L10n.text("丢弃文件未暂存改动…"), role: .destructive) {
                                if app.confirm(
                                    title: L10n.text("丢弃 \(diff.path) 的未暂存改动？"),
                                    message: L10n.text("将恢复到暂存区内容。未提交的改动可能无法恢复。"),
                                    action: L10n.text("丢弃改动"))
                                {
                                    session.perform(L10n.text("丢弃改动")) { try await $0.discard(diff) }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }.workbenchGlassMenu(icon: true)
                        .accessibilityLabel(L10n.text("差异文件操作")).help(L10n.text("差异文件操作"))
                }.font(.caption).padding(14).background(colors.chrome)
                if diff.layer == .unstaged || diff.layer == .staged {
                    if !app.workspace.inspector {
                        HStack(spacing: 16) {
                            Picker(L10n.text("上下文"), selection: $app.workspace.diffOptions.contextLines) {
                                ForEach([3, 20, 80, 200], id: \.self) {
                                    Text(L10n.count("%lld 行", $0)).tag($0)
                                }
                            }.pickerStyle(.menu).fixedSize().tint(colors.accentText)
                                .accessibilityIdentifier("diff-context")
                            Toggle(L10n.text("忽略空白"), isOn: $app.workspace.diffOptions.ignoreWhitespace)
                                .toggleStyle(.checkbox).accessibilityIdentifier("diff-ignore-whitespace")
                            Toggle(L10n.text("词级差异"), isOn: $app.workspace.wordDiff)
                                .toggleStyle(.checkbox).accessibilityIdentifier("diff-word-highlight")
                                .help(L10n.text("突出替换行中变化的词；长行仍保留整行差异标识。"))
                            Spacer()
                        }.font(.caption).padding(.horizontal, 14).padding(.bottom, 10)
                    }
                    if app.workspace.wordDiff, display.highlighting.fallbackLines > 0 {
                        Text(L10n.text("部分行使用整行差异标识")).font(.caption).foregroundStyle(colors.secondaryText)
                            .padding(.horizontal, 14).padding(.bottom, 8)
                    }
                    if diff.options.ignoreWhitespace {
                        Label(L10n.text("忽略空白仅用于阅读；关闭后可操作差异块及展开未变更行。"), systemImage: "info.circle")
                            .accessibilityIdentifier(
                                "diff-readonly-notice"
                            )
                            .font(.caption).foregroundStyle(colors.secondaryText).padding(.horizontal, 14)
                            .padding(
                                .bottom, 10)
                    }
                }
                Divider()
                if diff.binary {
                    EmptyPanel(
                        title: L10n.text("二进制文件已变化"), symbol: "doc.zipper",
                        message: L10n.text("此文件不支持文本差异，请使用外部工具查看。"))
                } else if diff.preview?.isEmpty == true {
                    EmptyPanel(
                        title: L10n.text("空文件"), symbol: "doc", message: L10n.text("文件没有文本内容，仍可在文件列表中暂存。"))
                } else if diff.hunks.isEmpty && diff.preview == nil {
                    EmptyPanel(
                        title: diff.layer == .conflict ? L10n.text("请在外部工具解决冲突") : L10n.text("没有文本差异"),
                        symbol: "doc.text.magnifyingglass",
                        message: diff.layer == .conflict
                            ? L10n.text("保存结果后，在文件列表中标记已解决。") : L10n.text("文件可能只有模式、名称或空白之外的元数据变化。"))
                } else {
                    DiffContentView(app: app, session: session, display: display).id(
                        ObjectIdentifier(display))
                }
            } else {
                EmptyPanel(
                    title: L10n.text("选择一个文件"), symbol: "doc.text.magnifyingglass",
                    message: L10n.text("查看工作区与暂存区的差异，整理下一次提交。"))
            }
        }
        .onChange(of: app.workspace.splitDiff) { _, split in
            if let display = app.workspace.diffDisplay {
                Task {
                    guard app.workspace.splitDiff == split, app.workspace.diffDisplay === display else {
                        return
                    }
                    await display.prepare(split: split)
                }
            }
        }
    }

    private func summaryView(_ summary: DiffSummary) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 32)).foregroundStyle(
                colors.secondaryText)
            Text(app.workspace.diffLimit == nil ? L10n.text("此差异较大") : L10n.text("内容超过读取上限")).font(
                .title3.weight(.semibold))
            Text(summary.path).font(.headline).textSelection(.enabled)
            if let added = summary.additions, let removed = summary.deletions {
                Text(L10n.text("新增 \(added) 行 · 删除 \(removed) 行")).monospacedDigit()
            }
            if let bytes = summary.fileBytes {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
            Text(app.workspace.diffLimit?.localizedDescription ?? L10n.text("加载后分段显示内容，可随时取消。"))
                .foregroundStyle(colors.secondaryText).multilineTextAlignment(.center)
            if app.workspace.diffCancelled {
                Text(L10n.text("已取消读取")).foregroundStyle(colors.secondaryText)
            }
            HStack {
                if app.workspace.diffLimit == nil {
                    Button(L10n.text("加载差异")) { Task { await app.loadDiff(loadLarge: true) } }
                        .workbenchPrimaryAction().tint(colors.primaryAction)
                        .accessibilityIdentifier("diff-load-large")
                } else {
                    Button(L10n.text("重新检查")) { Task { await app.loadDiff() } }
                }
                Button(L10n.text("外部打开")) {
                    NSWorkspace.shared.open(session.location.root.appending(path: summary.path))
                }
            }
            if app.workspace.diffLimit != nil && app.workspace.diffOptions.contextLines > 3 {
                Button(L10n.text("使用 3 行上下文重试")) { app.workspace.diffOptions.contextLines = 3 }
            }
        }.font(.callout).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain).accessibilityIdentifier("diff-large-summary")
    }
    private func subtitle(_ layer: DiffLayer) -> String {
        switch layer {
        case .unstaged: L10n.text("工作区 ↔ 暂存区")
        case .staged: session.status.head == nil ? L10n.text("暂存区 ↔ 空树（首次提交）") : L10n.text("暂存区 ↔ HEAD")
        case .untracked: L10n.text("未跟踪 · 待添加内容")
        case .conflict: L10n.text("冲突 · 需要解决")
        case .commit: L10n.text("提交差异")
        }
    }
}
