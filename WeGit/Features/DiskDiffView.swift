import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WeGitCore

struct DiskDiffView: View {
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @Bindable var display: DiskDiffDisplayState
    @State private var copyTask: Task<Void, Never>?
    @State private var copyError: String?
    @State private var copying = false
    @State private var scrollGeometry = DiffScrollGeometry()
    @State private var scrollPosition = ScrollPosition(edge: .top)
    private var horizontalOffset: CGFloat { scrollGeometry.horizontalOffset }
    private var snapshot: DiskDiffSnapshot { display.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                DetailHeader(title: snapshot.path, subtitle: subtitle)
                if !snapshot.rawPreview && !snapshot.binary {
                    Text("+\(snapshot.additions)").foregroundStyle(.green)
                    Text("−\(snapshot.deletions)").foregroundStyle(.red)
                }
                if !snapshot.rawPreview && !snapshot.binary {
                    Picker("差异布局", selection: $app.workspace.splitDiff) {
                        Text("统一").tag(false)
                        Text("分栏").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
                }
                Menu {
                    Button(snapshot.rawPreview ? "导出完整内容…" : "导出完整补丁…") { export() }
                        .disabled(display.exporting)
                    Button("外部打开") {
                        NSWorkspace.shared.open(session.location.root.appending(path: snapshot.path))
                    }
                    if snapshot.layer == .unstaged && !snapshot.options.ignoreWhitespace {
                        Button("丢弃文件未暂存改动…", role: .destructive) {
                            if app.confirm(
                                title: "丢弃 \(snapshot.path) 的未暂存改动？",
                                message: "将恢复到暂存区内容。未提交的改动可能无法恢复。", action: "丢弃改动")
                            {
                                session.perform("丢弃改动") { try await $0.discard(snapshot) }
                            }
                        }.disabled(!session.canWrite)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("差异文件操作").help("差异文件操作")
            }.font(.caption).padding(14)
            if snapshot.layer == .unstaged || snapshot.layer == .staged || snapshot.layer == .commit {
                HStack(spacing: 16) {
                    Picker("上下文", selection: $app.workspace.diffOptions.contextLines) {
                        ForEach([3, 20, 80, 200], id: \.self) { Text("\($0) 行").tag($0) }
                    }.pickerStyle(.menu).fixedSize().accessibilityIdentifier("diff-context")
                    Toggle("忽略空白", isOn: $app.workspace.diffOptions.ignoreWhitespace)
                        .toggleStyle(.checkbox).accessibilityIdentifier("diff-ignore-whitespace")
                    Toggle("词级差异", isOn: $app.workspace.wordDiff)
                        .toggleStyle(.checkbox).accessibilityIdentifier("diff-word-highlight")
                    Spacer()
                }.font(.caption).padding(.horizontal, 14).padding(.bottom, 10)
            }
            HStack {
                Text(
                    "分页浏览 · \(ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteCount), countStyle: .file))"
                )
                if snapshot.options.ignoreWhitespace { Text("· 忽略空白，仅供阅读") }
                Spacer()
                if display.exporting {
                    ProgressView().controlSize(.small)
                    Button("取消导出") { display.cancelExport() }
                } else if display.exported {
                    Text("导出完成")
                }
            }.font(.caption).foregroundStyle(AppColors.secondaryText).padding(.horizontal, 14).padding(
                .bottom, 8)
            if let error = display.exportError {
                Text(error).font(.caption).foregroundStyle(AppColors.secondaryText).padding(.horizontal, 14)
                    .padding(
                        .bottom, 8)
            }
            if !snapshot.hunks.isEmpty {
                DiffNavigationControls(
                    count: snapshot.hunks.count, current: display.currentHunk,
                    loading: display.loading, navigate: display.navigate)
            }
            if let copyError { Text(copyError).font(.caption).foregroundStyle(.red).padding(8) }
            Divider()
            if snapshot.binary {
                EmptyPanel(title: "无法显示为文本", symbol: "doc.zipper", message: "可导出原始内容或使用外部工具查看。")
            } else if let page = display.page, !page.rows.isEmpty {
                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        let contentWidth = max(display.split ? 360 : 520, geometry.size.width)
                        let columnWidth = (contentWidth - 1) / 2
                        ScrollView([.horizontal, .vertical]) {
                            // A disk page is bounded to 399 content rows. Measuring
                            // that page keeps wrapped native cells from shifting
                            // the viewport as lazy height estimates are corrected.
                            VStack(alignment: .leading, spacing: 0) {
                                if display.split {
                                    HStack(spacing: 0) {
                                        Text("原始内容").frame(width: columnWidth, alignment: .leading)
                                        Text("修改后").frame(width: columnWidth, alignment: .leading)
                                    }.font(.caption.weight(.medium)).foregroundStyle(AppColors.secondaryText)
                                        .padding(
                                            .vertical, 8
                                        )
                                        .accessibilityElement(children: .ignore).accessibilityLabel(
                                            "原始内容，修改后"
                                        )
                                        .accessibilityIdentifier("diff-column-headers")
                                }
                                ForEach(page.rows) { row in
                                    switch row {
                                    case .hunk(let hunk):
                                        if let gap = display.gap(before: hunk) {
                                            context(
                                                gap, columnWidth: columnWidth,
                                                controlsWidth: geometry.size.width)
                                        }
                                        hunkHeader(hunk).frame(width: geometry.size.width).offset(
                                            x: horizontalOffset)
                                    case .line(let line):
                                        DiffCodeRow(
                                            content: .unified(line), codeSize: app.codeSize,
                                            wordDiff: app.workspace.wordDiff, highlighting: page.highlighting,
                                            selection: display.selection, performanceID: display.renderID)
                                    case .split(let row):
                                        DiffCodeRow(
                                            content: .split(row), codeSize: app.codeSize,
                                            wordDiff: app.workspace.wordDiff, highlighting: page.highlighting,
                                            columnWidth: columnWidth, selection: display.selection,
                                            performanceID: display.renderID)
                                    }
                                }
                                if page.next == nil, let gap = display.contextGaps[snapshot.hunks.count] {
                                    context(gap, columnWidth: columnWidth, controlsWidth: geometry.size.width)
                                }
                            }.frame(minWidth: contentWidth, alignment: .leading)
                                .accessibilityElement(children: .contain).accessibilityLabel("分页差异内容")
                        }.defaultScrollAnchor(.topLeading).scrollPosition($scrollPosition).contentMargins(
                            .all, 0, for: .scrollContent
                        )
                        .accessibilityIdentifier("disk-diff-content")
                        .accessibilityLabel("分页文本差异")
                        .onScrollGeometryChange(for: DiffScrollGeometry.self) {
                            DiffScrollGeometry($0)
                        } action: { _, geometry in
                            scrollGeometry = geometry
                        }
                    }
                    .onChange(of: display.navigationID) { _, _ in
                        if display.scrollTarget == .gap(0) {
                            scrollPosition.scrollTo(edge: .top)
                        } else if let target = display.scrollTarget {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                }.id("\(display.split):\(display.pageIndex)")
            } else if display.loading {
                ProgressView("读取这一页…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyPanel(
                    title: display.error == nil ? "没有显示内容" : "无法读取这一页",
                    symbol: "doc.text.magnifyingglass", message: display.error ?? "可重新读取，或导出完整内容查看。")
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("上一页") { display.previous() }.disabled(!display.canGoBack)
                        .accessibilityIdentifier("disk-diff-previous")
                    Button("下一页") { display.next() }.disabled(!display.canGoForward)
                        .accessibilityIdentifier("disk-diff-next")
                    Text(
                        "第 \(display.pageIndex + 1) 页 · \(display.page?.firstLine ?? 0)–\(display.page?.lastLine ?? 0) / \(display.totalLines) 行"
                    )
                    .monospacedDigit().accessibilityIdentifier("disk-diff-progress")
                    Spacer()
                    if display.loading {
                        ProgressView().controlSize(.small)
                        Button("取消加载") { display.cancelPage() }
                    } else if display.error != nil || display.page == nil {
                        Button("重新读取") { display.retry() }
                    }
                }
                if let error = display.error, display.page != nil {
                    Text(error).foregroundStyle(AppColors.secondaryText)
                }
                if display.page?.rows.contains(where: {
                    switch $0 {
                    case .line(let line): line.truncated
                    case .split(let row): row.old?.truncated == true || row.new?.truncated == true
                    case .hunk: false
                    }
                }) == true {
                    Text("长行仅显示开头；可从文件菜单导出完整内容。").foregroundStyle(AppColors.secondaryText)
                }
            }.font(.caption).padding(12).background(.bar)
        }
        .onDisappear { copyTask?.cancel() }
        .onChange(of: app.workspace.splitDiff) { _, split in
            scrollGeometry = DiffScrollGeometry()
            scrollPosition.scrollTo(edge: .top)
            Task {
                guard app.workspace.splitDiff == split, app.workspace.diskDisplay === display else { return }
                await display.prepare(split: split)
            }
        }
        .onChange(of: display.split) { _, _ in scrollPosition.scrollTo(edge: .top) }
        .onChange(of: display.pageIndex) { _, _ in
            scrollGeometry = DiffScrollGeometry()
            scrollPosition.scrollTo(edge: .top)
        }
    }

    private var subtitle: String {
        switch snapshot.layer {
        case .unstaged: "工作区 ↔ 暂存区"
        case .staged: snapshot.head == nil ? "暂存区 ↔ 空树（首次提交）" : "暂存区 ↔ HEAD"
        case .untracked: "未跟踪 · 待添加内容"
        case .conflict: "冲突 · 需要解决"
        case .commit: "提交差异 · 只读"
        }
    }

    @ViewBuilder private func context(_ gap: DiffContextGap, columnWidth: CGFloat, controlsWidth: CGFloat)
        -> some View
    {
        let expansion = display.contexts[gap.id] ?? DiffContextExpansion()
        if gap.expandsUpward {
            contextControls(gap, expansion: expansion).frame(width: controlsWidth).offset(x: horizontalOffset)
        }
        ForEach(expansion.lines) { line in
            DiffCodeRow(
                content: display.split ? .split(SplitDiffRow(context: line)) : .unified(line),
                codeSize: app.codeSize, wordDiff: false, highlighting: display.contextHighlighting,
                columnWidth: columnWidth, selection: display.selection, performanceID: display.renderID
            )
            .accessibilityIdentifier("disk-context-line:\(line.id)")
        }
        if !gap.expandsUpward {
            contextControls(gap, expansion: expansion).frame(width: controlsWidth).offset(x: horizontalOffset)
        }
    }

    private func contextControls(_ gap: DiffContextGap, expansion: DiffContextExpansion) -> some View {
        DiffContextControls(
            gap: gap, expansion: expansion, expandingGap: display.expandingGap,
            onExpand: { display.expand(gap) }, onCancel: { display.cancelContext() },
            onCollapse: { display.collapse(gap) }
        ).id(DiffDisplayRow.ID.gap(gap.id))
    }

    private func hunkHeader(_ hunk: DiskDiffHunk) -> some View {
        HStack {
            Text(hunk.header).font(.system(size: 11, design: .monospaced)).foregroundStyle(
                AppColors.secondaryText
            )
            .lineLimit(1).help(hunk.header)
            Spacer(minLength: 16)
            Button("复制此块补丁") {
                copying = true
                copyError = nil
                copyTask = Task {
                    defer { copying = false }
                    do {
                        let data = try await snapshot.hunkPatch(hunk)
                        try Task.checkCancellation()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            String(decoding: data, as: UTF8.self), forType: .string)
                    } catch { if !Task.isCancelled { copyError = error.localizedDescription } }
                }
            }.controlSize(.small).disabled(copying).accessibilityIdentifier("diff-hunk-copy:\(hunk.id)")
            if snapshot.canApplyHunk {
                if display.completedHunks.contains(hunk.id) {
                    Button(snapshot.layer == .staged ? "取消暂存此块" : "暂存此块") {
                        session.perform("暂存区更新") { try await $0.apply(hunk: hunk, from: snapshot) }
                    }.controlSize(.small).disabled(!session.canWrite || display.loading)
                    if snapshot.layer == .unstaged {
                        Button("丢弃此块…", role: .destructive) {
                            if app.confirm(
                                title: "丢弃这个差异块？",
                                message: "文件：\(snapshot.path)\n范围：\(hunk.header)\n只丢弃本块未暂存改动。其他块和暂存区保留。",
                                action: "丢弃此块")
                            {
                                session.perform("丢弃差异块") {
                                    try await $0.apply(hunk: hunk, from: snapshot, discard: true)
                                }
                            }
                        }.controlSize(.small).disabled(!session.canWrite || display.loading)
                    }
                } else {
                    Text("此块仍有未加载内容").font(.caption).foregroundStyle(AppColors.secondaryText)
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 9).background(.quaternary.opacity(0.5))
            .accessibilityElement(children: .contain).accessibilityLabel("差异块：" + hunk.header)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            (snapshot.path as NSString).lastPathComponent + (snapshot.rawPreview ? "" : ".patch")
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        panel.message = "导出完整内容。请选择新文件名，已有文件不会被覆盖。"
        if panel.runModal() == .OK, let url = panel.url { display.export(to: url) }
    }
}
