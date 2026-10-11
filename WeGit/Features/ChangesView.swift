import AppKit
import SwiftUI
import WeGitCore

struct ChangesView: View {
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @State private var preparingRemoval = false
    @State private var removalTask: Task<Void, Never>?
    @State private var preparingDiscard = false
    @State private var discardTask: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text("更改").font(.headline)
                        Text(
                            app.workspace.changeFilter == .all && app.workspace.filter.isEmpty
                                ? "\(session.status.files.count)"
                                : "\(app.workspace.fileFilter.visiblePathCount(session.status.files))/\(session.status.files.count)"
                        )
                        .foregroundStyle(AppColors.secondaryText).help("匹配路径 / 仓库全部改动路径；同一路径不重复计数")
                        if preparingRemoval { ProgressView().controlSize(.small).help("检查未跟踪文件…") }
                        if preparingDiscard { ProgressView().controlSize(.small).help("检查未暂存改动…") }
                        Spacer()
                        Menu {
                            Button("暂存全部", action: app.stageAll).disabled(!app.canStageAll)
                                .help("暂存当前仓库全部适用文件，不受筛选影响，不自动标记冲突解决")
                            Button("取消全部暂存", action: app.unstageAll).disabled(!app.canUnstageAll)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }.menuStyle(.borderlessButton).fixedSize().disabled(!session.canWrite)
                    }.padding(14)
                    HStack {
                        TextField("筛选文件路径", text: $app.workspace.filter).accessibilityIdentifier(
                            "changes-filter"
                        )
                        .textFieldStyle(.roundedBorder)
                        Picker("改动状态", selection: $app.workspace.changeFilter) {
                            ForEach(ChangeKindFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 110).accessibilityIdentifier("changes-state-filter")
                    }.padding(.horizontal, 12).padding(.bottom, 10)
                    Divider()
                    if let error = session.refreshError, !session.hasLoaded {
                        EmptyPanel(title: "无法读取仓库", symbol: "exclamationmark.triangle", message: error)
                    } else if !session.hasLoaded {
                        ProgressView("读取仓库状态…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if session.status.files.isEmpty {
                        EmptyPanel(
                            title: session.isStale ? "等待重新核对仓库" : "工作区干净", symbol: "checkmark.circle",
                            message: session.isStale ? "上次读取时没有未提交改动，请刷新确认当前状态。" : "没有未提交改动。")
                    } else if app.workspace.fileFilter.visiblePathCount(session.status.files) == 0 {
                        VStack {
                            EmptyPanel(
                                title: "没有匹配文件", symbol: "line.3.horizontal.decrease.circle",
                                message: "当前仓库仍有改动，请调整路径或状态筛选。")
                            Button("清除筛选") {
                                app.workspace.filter = ""
                                app.workspace.changeFilter = .all
                            }.padding(.bottom, 18)
                        }
                    } else {
                        List(selection: $app.workspace.selectedFile) {
                            group("冲突", layer: .conflict, files: session.status.conflicts)
                            group("已暂存", layer: .staged, files: session.status.files.filter(\.staged))
                            group("未暂存", layer: .unstaged, files: session.status.files.filter(\.unstaged))
                            group("未跟踪", layer: .untracked, files: session.status.files.filter(\.untracked))
                        }.listStyle(.inset).accessibilityIdentifier("changes-list")
                    }
                }.frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
                DiffView(app: app, session: session)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            composer
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
        .onDisappear {
            app.workspace.diffDisplay?.cancelAll()
            app.workspace.diskDisplay?.cancelAll()
            removalTask?.cancel()
            discardTask?.cancel()
        }
    }

    @ViewBuilder private func group(_ title: String, layer: DiffLayer, files: [FileChange]) -> some View {
        let filtered = files.filter { app.workspace.fileFilter.matches($0, layer: layer) }
        if !filtered.isEmpty {
            Section("\(title)（\(filtered.count)）") {
                ForEach(filtered) { file in
                    HStack(spacing: 8) {
                        if app.preferences.showFileIcons {
                            Image(systemName: "doc.text").foregroundStyle(AppColors.secondaryText)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.filename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if file.path != file.filename {
                                Text((file.path as NSString).deletingLastPathComponent).font(.caption2)
                                    .foregroundStyle(AppColors.secondaryText).lineLimit(1).truncationMode(
                                        .middle)
                            }
                        }
                        Spacer(minLength: 4)
                        StatusBadge(symbol: file.symbol(for: layer))
                        Button {
                            stageAction(file, layer: layer)
                        } label: {
                            Image(
                                systemName: layer == .staged
                                    ? "minus.circle" : layer == .conflict ? "checkmark.circle" : "plus.circle"
                            )
                        }
                        .buttonStyle(.borderless).disabled(!session.canWrite)
                        .help(layer == .staged ? "取消暂存" : layer == .conflict ? "标记已解决" : "暂存文件")
                        .accessibilityLabel(
                            "\(layer == .staged ? "取消暂存" : layer == .conflict ? "标记已解决" : "暂存") \(file.filename)"
                        )
                        .accessibilityIdentifier("stage:\(layer.rawValue):\(file.path)")
                    }
                    .padding(.vertical, app.preferences.density == "compact" ? 1 : 4)
                    .accessibilityElement(children: .contain)
                    .tag(layer.rawValue + "|" + file.path)
                    .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                    .contextMenu {
                        Button(layer == .staged ? "取消暂存" : layer == .conflict ? "标记已解决…" : "暂存文件") {
                            stageAction(file, layer: layer)
                        }.disabled(!session.canWrite)
                        Divider()
                        FileContextMenu(app: app, session: session, path: file.path)
                        if layer == .unstaged {
                            Divider()
                            Button("丢弃未暂存改动…", role: .destructive) { discardFile(file) }
                                .disabled(!session.canWrite || preparingDiscard || preparingRemoval)
                                .accessibilityIdentifier("discard-file:" + file.path)
                        }
                        if layer == .untracked {
                            Divider()
                            Button("移到废纸篓…", role: .destructive) { removeUntracked(file) }
                                .disabled(!session.canWrite || preparingRemoval || preparingDiscard)
                                .accessibilityIdentifier("trash-untracked:" + file.path)
                        }
                    }
                }
            }
        }
    }

    private func stageAction(_ file: FileChange, layer: DiffLayer) {
        guard app.session === session, session.canWrite else { return }
        let head = session.status.head
        if layer == .staged {
            session.perform("取消暂存") { try await $0.unstage(paths: [file.path], expectedHead: head) }
        } else if layer == .conflict {
            if app.confirm(
                title: "标记已解决？",
                message: "请先在外部编辑器中保存 \(file.path) 的正确结果。此操作将把当前文件加入暂存区。",
                action: "标记已解决", destructive: false)
            {
                session.perform("标记已解决") { try await $0.markResolved(path: file.path, expectedHead: head) }
            }
        } else {
            session.perform("暂存文件") { try await $0.stage(paths: [file.path], expectedHead: head) }
        }
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
                let link = removal.symbolicLink ? "\n只移动符号链接本身，不影响链接目标。" : ""
                if app.confirm(
                    title: "将未跟踪文件移到废纸篓？",
                    message: "文件：\(removal.path)\n大小：\(size)\(link)\n文件尚未被 Git 跟踪，移除后可从废纸篓恢复。",
                    action: "移到废纸篓")
                {
                    session.lastTrashedFile = nil
                    session.perform("移到废纸篓") {
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
                    throw ModelFailure.unsupported(limit?.localizedDescription ?? "无法完整核对该文件，请在外部处理。")
                }
                guard
                    app.confirm(
                        title: "丢弃文件的未暂存改动？",
                        message:
                            "分支：\(branch)\n文件：\(file.path)\n将把工作区内容恢复为暂存区版本，包括空白改动。已暂存内容保留，未提交的工作区改动可能无法恢复。",
                        action: "丢弃未暂存改动")
                else { return }
                session.perform("丢弃未暂存改动") { current in
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "square.and.pencil").font(.title2).foregroundStyle(AppColors.secondaryText)
                    .padding(
                        .top, 5)
                TextField("提交消息；可换行添加详细描述", text: $session.message, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("commit-message")
                Button {
                    app.commitCurrent()
                } label: {
                    Text(session.amend ? "修改提交" : "提交（\(session.status.files.filter(\.staged).count) 个文件）")
                        .frame(minWidth: 110)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!session.canCommit)
                    .accessibilityIdentifier("commit-button")
                Button("提交并推送…") { app.presentSync(.commitAndPush) }
                    .disabled(!session.canCommitAndPush).accessibilityIdentifier("commit-push-button")
                    .help(
                        session.canCommitAndPush
                            ? "先提交本地改动，再推送到指定远端"
                            : session.canCommit ? session.syncReason : session.commitReason)
            }
            HStack {
                Toggle("修改上次提交（Amend）", isOn: $session.amend).toggleStyle(.checkbox).disabled(
                    session.status.head == nil || session.isBusy
                )
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
                    Button("查看废纸篓中的文件") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                        .font(.caption).disabled(session.isBusy).accessibilityIdentifier("show-trashed-file")
                        .accessibilityValue(path.path)
                }
                Text(
                    session.isBusy
                        ? session.activityLabel + "…"
                        : session.notice ?? (session.canCommit ? "⌘↩ 提交" : session.commitReason)
                )
                .font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(1)
            }
        }.padding(16).background(.bar)
    }
}

struct DiffView: View {
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    var body: some View {
        VStack(spacing: 0) {
            if app.workspace.refreshingDiff {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在核对差异…").font(.caption)
                    Spacer()
                    Button("取消核对") { app.cancelDiffRead() }
                }.padding(8).background(.bar).accessibilityIdentifier("diff-refresh-progress")
            }
            if let notice = app.workspace.diffReadNotice {
                Text(notice).font(.caption).foregroundStyle(AppColors.secondaryText).padding(8)
            }
            if app.workspace.loadingDiff {
                VStack(spacing: 16) {
                    ProgressView("读取差异…")
                    Button("取消读取") { app.cancelDiffRead() }.accessibilityIdentifier("diff-cancel-read")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = app.workspace.diffError {
                VStack {
                    EmptyPanel(title: "无法读取差异", symbol: "exclamationmark.triangle", message: error)
                    HStack {
                        Button("重试") { Task { await app.loadDiff() } }
                        Button("恢复默认差异选项") { app.workspace.diffOptions = DiffReadOptions() }
                    }.padding(.bottom, 20)
                }
            } else if let summary = app.workspace.diffSummary {
                summaryView(summary)
            } else if app.workspace.diffCancelled {
                VStack {
                    EmptyPanel(title: "已取消读取", symbol: "pause.circle", message: "可随时重新读取这个文件的差异。")
                    Button("重新读取") { Task { await app.loadDiff() } }.padding(.bottom, 20)
                }
            } else if let display = app.workspace.diskDisplay {
                DiskDiffView(app: app, session: session, display: display).id(ObjectIdentifier(display))
            } else if let diff = app.workspace.diff, let display = app.workspace.diffDisplay {
                HStack(spacing: 12) {
                    DetailHeader(title: diff.path, subtitle: subtitle(diff.layer))
                    if diff.preview == nil && !diff.binary {
                        Text("+\(display.additions)").foregroundStyle(.green).monospacedDigit()
                        Text("−\(display.deletions)").foregroundStyle(.red).monospacedDigit()
                    } else {
                        Text(diff.binary ? "二进制" : "内容预览").foregroundStyle(AppColors.secondaryText)
                    }
                    Picker("差异布局", selection: $app.workspace.splitDiff) {
                        Text("统一").tag(false)
                        Text("分栏").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
                    Menu {
                        if !diff.binary {
                            Button(diff.preview == nil ? "复制完整补丁" : "复制完整内容") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    String(decoding: diff.raw, as: UTF8.self), forType: .string)
                            }
                        }
                        Button("外部打开") {
                            NSWorkspace.shared.open(session.location.root.appending(path: diff.path))
                        }
                        if diff.layer == .unstaged && !diff.options.ignoreWhitespace {
                            Button("丢弃文件未暂存改动…", role: .destructive) {
                                if app.confirm(
                                    title: "丢弃 \(diff.path) 的未暂存改动？", message: "将恢复到暂存区内容。未提交的改动可能无法恢复。",
                                    action: "丢弃改动")
                                {
                                    session.perform("丢弃改动") { try await $0.discard(diff) }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }.menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("差异文件操作").help("差异文件操作")
                }.font(.caption).padding(14)
                if diff.layer == .unstaged || diff.layer == .staged {
                    HStack(spacing: 16) {
                        Picker("上下文", selection: $app.workspace.diffOptions.contextLines) {
                            ForEach([3, 20, 80, 200], id: \.self) { Text("\($0) 行").tag($0) }
                        }.pickerStyle(.menu).fixedSize().accessibilityIdentifier("diff-context")
                        Toggle("忽略空白", isOn: $app.workspace.diffOptions.ignoreWhitespace)
                            .toggleStyle(.checkbox).accessibilityIdentifier("diff-ignore-whitespace")
                        Toggle("词级差异", isOn: $app.workspace.wordDiff)
                            .toggleStyle(.checkbox).accessibilityIdentifier("diff-word-highlight")
                            .help("突出替换行中变化的词；长行仍保留整行差异标识。")
                        Spacer()
                    }.font(.caption).padding(.horizontal, 14).padding(.bottom, 10)
                    if app.workspace.wordDiff, display.highlighting.fallbackLines > 0 {
                        Text("部分行使用整行差异标识").font(.caption).foregroundStyle(AppColors.secondaryText)
                            .padding(.horizontal, 14).padding(.bottom, 8)
                    }
                    if diff.options.ignoreWhitespace {
                        Label("忽略空白仅用于阅读；关闭后可操作差异块及展开未变更行。", systemImage: "info.circle")
                            .accessibilityIdentifier(
                                "diff-readonly-notice"
                            )
                            .font(.caption).foregroundStyle(AppColors.secondaryText).padding(.horizontal, 14)
                            .padding(
                                .bottom, 10)
                    }
                }
                Divider()
                if diff.binary {
                    EmptyPanel(title: "二进制文件已变化", symbol: "doc.zipper", message: "此文件不支持文本差异，请使用外部工具查看。")
                } else if diff.preview?.isEmpty == true {
                    EmptyPanel(title: "空文件", symbol: "doc", message: "文件没有文本内容，仍可在文件列表中暂存。")
                } else if diff.hunks.isEmpty && diff.preview == nil {
                    EmptyPanel(
                        title: diff.layer == .conflict ? "请在外部工具解决冲突" : "没有文本差异",
                        symbol: "doc.text.magnifyingglass",
                        message: diff.layer == .conflict ? "保存结果后，在文件列表中标记已解决。" : "文件可能只有模式、名称或空白之外的元数据变化。")
                } else {
                    DiffContentView(app: app, session: session, display: display).id(
                        ObjectIdentifier(display))
                }
            } else {
                EmptyPanel(
                    title: "选择一个文件", symbol: "doc.text.magnifyingglass", message: "查看工作区与暂存区的差异，整理下一次提交。")
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
                AppColors.secondaryText)
            Text(app.workspace.diffLimit == nil ? "此差异较大" : "内容超过读取上限").font(.title3.weight(.semibold))
            Text(summary.path).font(.headline).textSelection(.enabled)
            if let added = summary.additions, let removed = summary.deletions {
                Text("新增 \(added) 行 · 删除 \(removed) 行").monospacedDigit()
            }
            if let bytes = summary.fileBytes {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
            Text(app.workspace.diffLimit?.localizedDescription ?? "加载后分段显示内容，可随时取消。")
                .foregroundStyle(AppColors.secondaryText).multilineTextAlignment(.center)
            if app.workspace.diffCancelled { Text("已取消读取").foregroundStyle(AppColors.secondaryText) }
            HStack {
                if app.workspace.diffLimit == nil {
                    Button("加载差异") { Task { await app.loadDiff(loadLarge: true) } }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("diff-load-large")
                } else {
                    Button("重新检查") { Task { await app.loadDiff() } }
                }
                Button("外部打开") {
                    NSWorkspace.shared.open(session.location.root.appending(path: summary.path))
                }
            }
            if app.workspace.diffLimit != nil && app.workspace.diffOptions.contextLines > 3 {
                Button("使用 3 行上下文重试") { app.workspace.diffOptions.contextLines = 3 }
            }
        }.font(.callout).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain).accessibilityIdentifier("diff-large-summary")
    }
    private func subtitle(_ layer: DiffLayer) -> String {
        switch layer {
        case .unstaged: "工作区 ↔ 暂存区"
        case .staged: session.status.head == nil ? "暂存区 ↔ 空树（首次提交）" : "暂存区 ↔ HEAD"
        case .untracked: "未跟踪 · 待添加内容"
        case .conflict: "冲突 · 需要解决"
        case .commit: "提交差异"
        }
    }
}
