import AppKit
import SwiftUI
import WeGitCore

struct CommitFilesView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @Bindable var detail: CommitDetailState
    var stashContext = false
    var allowsFileHistory = true
    var allowsBlame = true
    var usesWorkspaceInspector = true
    private var movesFilesToInspector: Bool { usesWorkspaceInspector && app.workspace.inspector }

    var body: some View {
        VStack(spacing: 0) {
            if detail.loading {
                VStack(spacing: 12) {
                    ProgressView(stashContext ? L10n.text("读取记录文件…") : L10n.text("读取提交文件…"))
                    Button(L10n.text("取消读取")) { detail.cancel(userInitiated: true) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = detail.error {
                VStack {
                    EmptyPanel(
                        title: stashContext ? L10n.text("无法读取记录文件") : L10n.text("无法读取提交文件"),
                        symbol: "exclamationmark.triangle", message: error)
                    Button(L10n.text("重试")) { detail.retry() }.padding(.bottom, 14)
                }
            } else if let comparison = detail.comparison {
                if comparison.files.isEmpty {
                    EmptyPanel(
                        title: L10n.text("没有文件变化"), symbol: "doc",
                        message: stashContext
                            ? L10n.text("此部分没有保存的文件变化，可切换查看其他内容。") : L10n.text("这次提交相对于所选父提交没有文件变化。"))
                } else {
                    if !movesFilesToInspector {
                        List(selection: $detail.selectedPath) {
                            ForEach(comparison.files) { file in
                                HStack(spacing: 8) {
                                    StatusBadge(symbol: String(file.status))
                                    Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path).lineLimit(
                                        1
                                    )
                                    .truncationMode(.middle)
                                    Spacer()
                                    Text(
                                        file.binary
                                            ? L10n.text("二进制")
                                            : "+\(file.additions ?? 0) −\(file.deletions ?? 0)"
                                    )
                                    .foregroundStyle(colors.secondaryText)
                                }.font(.caption).tag(file.path).help(file.path)
                                    .accessibilityIdentifier("commit-file:" + file.path)
                                    .contextMenu {
                                        if allowsBlame && !stashContext,
                                            let target = BlameRequest.file(
                                                file, in: comparison, session: session)
                                        {
                                            Button(L10n.text("逐行归属…")) {
                                                guard app.session === session else { return }
                                                app.blameRequest = target
                                            }
                                            .accessibilityIdentifier("commit-file-blame:" + file.path)
                                        }
                                        if allowsFileHistory && !stashContext {
                                            Button(L10n.text("查看文件历史…")) {
                                                guard app.session === session else { return }
                                                app.fileHistoryRequest = FileHistoryRequest(
                                                    session: session, path: file.path,
                                                    tip: comparison.commit.id)
                                            }.accessibilityIdentifier("commit-file-history:" + file.path)
                                        }
                                    }
                            }
                        }.listStyle(.inset).scrollContentBackground(.hidden).background(colors.canvas)
                            .frame(height: CGFloat(min(4, comparison.files.count)) * 29 + 12)
                            .accessibilityIdentifier("commit-files").accessibilityLabel(
                                stashContext ? L10n.text("储藏的文件变化") : L10n.text("本次提交的文件变化"))
                    }
                    if detail.diskDisplay == nil {
                        HStack(spacing: 12) {
                            if movesFilesToInspector, let path = detail.selectedPath {
                                Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(
                                    .middle
                                )
                                .help(path)
                            }
                            WorkbenchGlassTabs(
                                title: L10n.text("布局"), selection: $app.workspace.splitDiff,
                                tabs: [
                                    GlassTab(value: false, title: L10n.text("统一")),
                                    GlassTab(value: true, title: L10n.text("分栏")),
                                ],
                                identifier: "diff-layout"
                            ).frame(width: 110)
                            Menu(L10n.text("阅读选项")) {
                                Picker(L10n.text("上下文"), selection: $app.workspace.diffOptions.contextLines) {
                                    ForEach([3, 20, 80, 200], id: \.self) {
                                        Text(L10n.count("%lld 行", $0)).tag($0)
                                    }
                                }
                                Toggle(L10n.text("忽略空白"), isOn: $app.workspace.diffOptions.ignoreWhitespace)
                                Toggle(L10n.text("词级差异"), isOn: $app.workspace.wordDiff)
                            }.fixedSize().tint(colors.accentText)
                            if allowsBlame, !stashContext,
                                let file = comparison.files.first(where: { $0.path == detail.selectedPath }),
                                let target = BlameRequest.file(file, in: comparison, session: session)
                            {
                                Button(L10n.text("逐行归属…")) {
                                    guard app.session === session else { return }
                                    app.blameRequest = target
                                }
                                .accessibilityIdentifier("commit-blame")
                            }
                            Spacer()
                            if let display = detail.display, !display.diff.binary {
                                Button(L10n.text("复制补丁")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        String(decoding: display.diff.raw, as: UTF8.self), forType: .string)
                                }
                            }
                        }.font(.caption).padding(10).background(colors.chrome)
                    }
                    Divider()
                    if detail.loadingFile {
                        VStack(spacing: 12) {
                            ProgressView(L10n.text("读取文件差异…"))
                            Button(L10n.text("取消读取")) { detail.cancelFile() }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = detail.fileError {
                        VStack {
                            EmptyPanel(
                                title: L10n.text("文件差异未显示"), symbol: "doc.text.magnifyingglass",
                                message: error)
                            Button(L10n.text("重试")) { load() }.padding(.bottom, 14)
                        }
                    } else if let summary = detail.summary {
                        VStack(spacing: 14) {
                            Text(L10n.text("此文件差异较大")).font(.headline)
                            Text(summary.path).font(.caption).textSelection(.enabled)
                            Text(detail.limit?.localizedDescription ?? L10n.text("显式加载后可分段阅读，提交内容保持只读。"))
                                .foregroundStyle(colors.secondaryText).multilineTextAlignment(.center)
                            if detail.limit == nil { Button(L10n.text("加载差异")) { load(large: true) } }
                        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let disk = detail.diskDisplay {
                        DiskDiffView(app: app, session: session, display: disk).id(ObjectIdentifier(disk))
                    } else if let display = detail.display {
                        if display.diff.binary {
                            EmptyPanel(
                                title: L10n.text("二进制文件变化"), symbol: "doc.zipper",
                                message: stashContext
                                    ? L10n.text("此记录中的文件不支持文本差异。") : L10n.text("此提交中的文件不支持文本差异。"))
                        } else if display.diff.hunks.isEmpty && display.diff.preview == nil {
                            EmptyPanel(
                                title: L10n.text("没有文本变化"), symbol: "doc",
                                message: L10n.text("此文件仅有名称或模式等元数据变化。"))
                        } else {
                            DiffContentView(app: app, session: session, display: display).id(
                                ObjectIdentifier(display))
                        }
                    }
                }
            }
        }
        .background(colors.canvas)
        .onChange(of: ObjectIdentifier(detail), initial: true) { _, _ in
            guard usesWorkspaceInspector else { return }
            app.workspace.commitInspection = CommitInspection(
                sessionID: session.id, route: app.workspace.route, detail: detail,
                allowsFileHistory: allowsFileHistory && !stashContext)
        }
        .onDisappear {
            if usesWorkspaceInspector, app.workspace.commitInspection?.detail === detail {
                app.workspace.commitInspection = nil
            }
        }
        .task(
            id:
                "\(detail.comparison?.commit.id ?? ""):\(detail.comparison?.parent ?? ""):\(detail.selectedPath ?? ""):\(app.workspace.diffOptions.contextLines):\(app.workspace.diffOptions.ignoreWhitespace)"
        ) {
            await detail.loadFile(options: app.workspace.diffOptions, split: app.workspace.splitDiff)
        }
        .onChange(of: app.workspace.splitDiff) { _, split in detail.setLayout(split) }
    }

    private func load(large: Bool = false) {
        Task {
            await detail.loadFile(
                options: app.workspace.diffOptions, split: app.workspace.splitDiff, large: large)
        }
    }
}
