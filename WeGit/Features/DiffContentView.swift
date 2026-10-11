import AppKit
import SwiftUI
import WeGitCore

struct DiffContentView: View {
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @Bindable var display: DiffDisplayState
    @State private var scrollGeometry = DiffScrollGeometry()
    @State private var scrollPosition = ScrollPosition(edge: .top)
    private var horizontalOffset: CGFloat { scrollGeometry.horizontalOffset }
    private var diff: FileDiff { display.diff }

    var body: some View {
        let split = display.split && diff.preview == nil
        VStack(spacing: 0) {
            if !diff.hunks.isEmpty {
                DiffNavigationControls(
                    count: diff.hunks.count, current: display.currentHunk,
                    loading: display.loading, navigate: display.navigate)
                Divider()
            }
            if display.rows.isEmpty {
                VStack(spacing: 16) {
                    if display.loading {
                        ProgressView("准备差异内容…")
                        Button("取消显示") { display.cancelPage() }
                    } else {
                        Text(display.error ?? "尚未显示内容").foregroundStyle(AppColors.secondaryText)
                        Button("显示内容") { Task { await display.prepare(split: app.workspace.splitDiff) } }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    GeometryReader { geometry in
                        let contentWidth = max(split ? 360 : 520, geometry.size.width)
                        let columnWidth = (contentWidth - 1) / 2
                        ScrollView([.horizontal, .vertical]) {
                            Group {
                                if display.rows.count <= DiffReadBudget.pageRows {
                                    VStack(alignment: .leading, spacing: 0) {
                                        contentRows(
                                            split: split, columnWidth: columnWidth,
                                            controlsWidth: geometry.size.width)
                                    }
                                } else {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        contentRows(
                                            split: split, columnWidth: columnWidth,
                                            controlsWidth: geometry.size.width)
                                    }
                                }
                            }.frame(minWidth: contentWidth, alignment: .leading)
                                .accessibilityElement(children: .contain).accessibilityLabel("文本差异内容")
                        }.defaultScrollAnchor(.topLeading).scrollPosition($scrollPosition).contentMargins(
                            .all, 0, for: .scrollContent
                        )
                        .accessibilityIdentifier("diff-content").accessibilityLabel("文本差异")
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
                }.id(split)
                if display.hasMore || display.error != nil || display.loading {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("已显示 \(display.displayedLines) / \(display.document?.contentRows ?? 0) 行")
                                .monospacedDigit().accessibilityIdentifier("diff-page-progress")
                            Spacer()
                            if display.loading {
                                ProgressView().controlSize(.small)
                                Button("取消加载") { display.cancelPage() }
                            } else if display.hasMore {
                                Button(display.error == nil ? "显示更多" : "重试显示") { display.loadMore() }
                                    .accessibilityIdentifier("diff-load-more")
                            }
                        }
                        if let error = display.error { Text(error).foregroundStyle(AppColors.secondaryText) }
                        if diff.canApplyHunk && display.hasMore {
                            Text("显示完整差异后可操作差异块。").foregroundStyle(AppColors.secondaryText)
                        }
                    }.font(.caption).padding(12).background(.bar)
                }
            }
        }
        .onChange(of: split) { _, _ in
            scrollGeometry = DiffScrollGeometry()
            scrollPosition.scrollTo(edge: .top)
        }
    }

    @ViewBuilder private func contentRows(split: Bool, columnWidth: CGFloat, controlsWidth: CGFloat)
        -> some View
    {
        if split {
            HStack(spacing: 0) {
                Text("原始内容").frame(width: columnWidth, alignment: .leading)
                Text("修改后").frame(width: columnWidth, alignment: .leading)
            }.font(.caption.weight(.medium)).foregroundStyle(AppColors.secondaryText)
                .padding(.vertical, 8).background(.quaternary.opacity(0.35))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("原始内容，修改后")
                .accessibilityIdentifier("diff-column-headers")
        }
        ForEach(display.rows) { row in
            switch row {
            case .hunk(let hunk):
                hunkHeader(hunk).frame(width: controlsWidth).offset(
                    x: horizontalOffset)
            case .line(let line): unifiedLine(line)
            case .split(let row): splitLine(row, columnWidth: columnWidth)
            case .gap(let gap):
                context(
                    gap, split: split, columnWidth: columnWidth,
                    controlsWidth: controlsWidth)
            }
        }
    }

    private func hunkHeader(_ hunk: DiffHunk) -> some View {
        HStack {
            Text(hunk.header).font(.system(size: 11, design: .monospaced)).foregroundStyle(
                AppColors.secondaryText
            )
            .lineLimit(1).help(hunk.header)
            Spacer(minLength: 24)
            Button("复制此块补丁") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(diff.header + hunk.raw, forType: .string)
            }.controlSize(.small).accessibilityIdentifier("diff-hunk-copy:\(hunk.id)")
            if diff.canApplyHunk && !display.hasMore && !display.loading
                && app.workspace.diffOptions == diff.options
            {
                Button(diff.layer == .staged ? "取消暂存此块" : "暂存此块") {
                    session.perform("暂存区更新") { try await $0.apply(hunk: hunk, from: diff) }
                }.controlSize(.small).disabled(!session.canWrite)
                if diff.layer == .unstaged {
                    Button("丢弃此块…", role: .destructive) {
                        if app.confirm(
                            title: "丢弃这个差异块？",
                            message:
                                "文件：\(diff.path)\n范围：\(hunk.header)\n只丢弃本块未暂存改动，其他块和暂存区保留。未提交内容可能无法恢复。",
                            action: "丢弃此块")
                        {
                            session.perform("丢弃差异块") {
                                try await $0.apply(hunk: hunk, from: diff, discard: true)
                            }
                        }
                    }.controlSize(.small).disabled(!session.canWrite)
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 9).background(.quaternary.opacity(0.5))
            .accessibilityElement(children: .contain).accessibilityLabel("差异块：" + hunk.header)
    }

    @ViewBuilder private func context(
        _ gap: DiffContextGap, split: Bool, columnWidth: CGFloat, controlsWidth: CGFloat
    ) -> some View {
        let expansion = display.contexts[gap.id] ?? DiffContextExpansion()
        if gap.expandsUpward {
            contextControls(gap, expansion: expansion).frame(width: controlsWidth).offset(x: horizontalOffset)
        }
        ForEach(expansion.lines) { line in
            if split {
                splitLine(SplitDiffRow(context: line), columnWidth: columnWidth)
            } else {
                unifiedLine(line)
            }
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
        )
        .id(DiffDisplayRow.ID.gap(gap.id))
    }

    private func unifiedLine(_ line: DiffLine) -> some View {
        DiffCodeRow(
            content: .unified(line), codeSize: app.codeSize, wordDiff: app.workspace.wordDiff,
            highlighting: display.highlighting, selection: display.selection, performanceID: display.renderID)
    }

    private func splitLine(_ row: SplitDiffRow, columnWidth: CGFloat) -> some View {
        DiffCodeRow(
            content: .split(row), codeSize: app.codeSize, wordDiff: app.workspace.wordDiff,
            highlighting: display.highlighting, columnWidth: columnWidth, selection: display.selection,
            performanceID: display.renderID)
    }
}
