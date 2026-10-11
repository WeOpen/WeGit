import AppKit
import SwiftUI
import WeGitCore

struct CommitFilesView: View {
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @Bindable var detail: CommitDetailState

    var body: some View {
        VStack(spacing: 0) {
            if detail.loading {
                VStack(spacing: 12) {
                    ProgressView("读取提交文件…")
                    Button("取消读取") { detail.cancel(userInitiated: true) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = detail.error {
                VStack {
                    EmptyPanel(title: "无法读取提交文件", symbol: "exclamationmark.triangle", message: error)
                    Button("重试") { detail.retry() }.padding(.bottom, 14)
                }
            } else if let comparison = detail.comparison {
                if comparison.files.isEmpty {
                    EmptyPanel(title: "没有文件变化", symbol: "doc", message: "这次提交相对于所选父提交没有文件变化。")
                } else {
                    List(selection: $detail.selectedPath) {
                        ForEach(comparison.files) { file in
                            HStack(spacing: 8) {
                                StatusBadge(symbol: String(file.status))
                                Text(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path).lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(file.binary ? "二进制" : "+\(file.additions ?? 0) −\(file.deletions ?? 0)")
                                    .foregroundStyle(AppColors.secondaryText)
                            }.font(.caption).tag(file.path).help(file.path)
                                .accessibilityIdentifier("commit-file:" + file.path)
                        }
                    }.listStyle(.inset).frame(height: CGFloat(min(4, comparison.files.count)) * 29 + 12)
                        .accessibilityIdentifier("commit-files").accessibilityLabel("本次提交的文件变化")
                    if detail.diskDisplay == nil {
                        HStack(spacing: 12) {
                            Picker("布局", selection: $app.workspace.splitDiff) {
                                Text("统一").tag(false)
                                Text("分栏").tag(true)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
                            Menu("阅读选项") {
                                Picker("上下文", selection: $app.workspace.diffOptions.contextLines) {
                                    ForEach([3, 20, 80, 200], id: \.self) { Text("\($0) 行").tag($0) }
                                }
                                Toggle("忽略空白", isOn: $app.workspace.diffOptions.ignoreWhitespace)
                                Toggle("词级差异", isOn: $app.workspace.wordDiff)
                            }.fixedSize()
                            Spacer()
                            if let display = detail.display, !display.diff.binary {
                                Button("复制补丁") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        String(decoding: display.diff.raw, as: UTF8.self), forType: .string)
                                }
                            }
                        }.font(.caption).padding(10)
                    }
                    Divider()
                    if detail.loadingFile {
                        VStack(spacing: 12) {
                            ProgressView("读取文件差异…")
                            Button("取消读取") { detail.cancelFile() }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = detail.fileError {
                        VStack {
                            EmptyPanel(title: "文件差异未显示", symbol: "doc.text.magnifyingglass", message: error)
                            Button("重试") { load() }.padding(.bottom, 14)
                        }
                    } else if let summary = detail.summary {
                        VStack(spacing: 14) {
                            Text("此文件差异较大").font(.headline)
                            Text(summary.path).font(.caption).textSelection(.enabled)
                            Text(detail.limit?.localizedDescription ?? "显式加载后可分段阅读，提交内容保持只读。")
                                .foregroundStyle(AppColors.secondaryText).multilineTextAlignment(.center)
                            if detail.limit == nil { Button("加载差异") { load(large: true) } }
                        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let disk = detail.diskDisplay {
                        DiskDiffView(app: app, session: session, display: disk).id(ObjectIdentifier(disk))
                    } else if let display = detail.display {
                        if display.diff.binary {
                            EmptyPanel(title: "二进制文件变化", symbol: "doc.zipper", message: "此提交中的文件不支持文本差异。")
                        } else if display.diff.hunks.isEmpty && display.diff.preview == nil {
                            EmptyPanel(title: "没有文本变化", symbol: "doc", message: "此文件仅有名称或模式等元数据变化。")
                        } else {
                            DiffContentView(app: app, session: session, display: display).id(
                                ObjectIdentifier(display))
                        }
                    }
                }
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
