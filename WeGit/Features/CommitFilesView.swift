import AppKit
import SwiftUI
import WeGitCore

struct ReferenceComparisonSheet: View {
    let app: AppState
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReferenceComparisonState
    init(app: AppState, request: ReferenceComparisonRequest) {
        self.app = app
        _model = State(initialValue: ReferenceComparisonState(request))
    }
    var body: some View {
        @Bindable var model = model
        @Bindable var comparisonDetail = model.detail
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SheetTitle(title: L10n.text("比较对象"), symbol: "arrow.left.arrow.right")
                Spacer()
                if model.loading {
                    ProgressView()
                    Button(L10n.text("取消读取")) { model.cancel() }
                }
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("comparison-close")
            }
            HStack {
                referenceField(L10n.text("起点"), value: $model.base, identifier: "comparison-base")
                Image(systemName: "arrow.right").accessibilityHidden(true)
                referenceField(L10n.text("目标"), value: $model.target, identifier: "comparison-target")
            }.disabled(model.loading)
            HStack {
                Picker(L10n.text("范围"), selection: $model.kind) {
                    Text(L10n.text("两点比较")).tag(ReferenceComparisonKind.twoPoint)
                    Text(L10n.text("共同祖先到目标")).tag(ReferenceComparisonKind.mergeBase)
                }.frame(width: 220).accessibilityIdentifier("comparison-kind")
                Spacer()
                Button(L10n.text("比较")) { model.compare() }.workbenchPrimaryAction().disabled(
                    model.base.isEmpty || model.target.isEmpty
                )
                .accessibilityIdentifier("comparison-execute")
            }.disabled(model.loading)
            if let plan = model.plan {
                HStack {
                    Text(String(plan.base.id.prefix(12)) + " → " + String(plan.target.id.prefix(12))).font(
                        .caption.monospaced()
                    ).accessibilityIdentifier("comparison-objects")
                    if plan.kind == .mergeBase, plan.mergeBases.count > 1 {
                        Picker(L10n.text("共同祖先"), selection: $model.ancestor) {
                            Text(L10n.text("选择起点")).tag("")
                            ForEach(plan.mergeBases, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if let result = model.result, plan.kind == .mergeBase {
                        Text(L10n.text("共同祖先") + " " + String(result.effectiveBase.prefix(12))).font(
                            .caption.monospaced()
                        ).accessibilityIdentifier("comparison-effective-base")
                    }
                }.foregroundStyle(colors.secondaryText)
                    .accessibilityElement(children: .contain)
            }
            if let error = model.error {
                Text(error).foregroundStyle(colors.negative).textSelection(.enabled)
            }
            if model.kind == .mergeBase, model.result != nil {
                DisclosureGroup(L10n.text("待合入提交")) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.commits) { commit in
                                HStack {
                                    Text(String(commit.id.prefix(12))).font(.caption.monospaced())
                                        .foregroundStyle(colors.secondaryText)
                                    Text(commit.subject).lineLimit(2)
                                    Spacer()
                                    Button(L10n.text("查看提交")) {
                                        app.workspace.selectedCommit = commit
                                        app.workspace.route = .history
                                        dismiss()
                                    }
                                }
                            }
                            if model.nextCommitOffset != nil {
                                Button(L10n.text("加载更多提交")) { model.loadMoreCommits() }.disabled(
                                    model.loadingCommits)
                            }
                        }
                    }.frame(maxHeight: 170)
                }.accessibilityElement(children: .contain).accessibilityIdentifier("comparison-commits")
            }
            if let result = model.result {
                if result.comparison.files.isEmpty {
                    Text(L10n.text("所选对象之间没有文件变化。")).foregroundStyle(colors.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HSplitView {
                        VStack(spacing: 8) {
                            TextField(L10n.text("筛选文件路径"), text: $model.filter)
                                .accessibilityIdentifier("comparison-filter")
                            List(selection: $comparisonDetail.selectedPath) {
                                ForEach(Array(model.files.prefix(model.visibleFiles))) { file in
                                    HStack {
                                        StatusBadge(symbol: String(file.status))
                                        Text(file.oldPath.map { $0 + " → " + file.path } ?? file.path)
                                            .lineLimit(2)
                                    }.tag(file.path).font(.caption)
                                        .accessibilityElement(children: .contain)
                                        .accessibilityIdentifier("comparison-file:" + file.path)
                                }
                            }.listStyle(.inset).scrollContentBackground(.hidden)
                                .accessibilityIdentifier("comparison-files")
                            if model.files.count > model.visibleFiles {
                                Button(L10n.text("加载更多文件")) { model.visibleFiles += 100 }
                            }
                        }.frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
                        CommitFilesView(
                            app: app, session: model.session, detail: model.detail,
                            usesWorkspaceInspector: false, showsFileList: false,
                            onRestore: { request in
                                app.restoreFileAfterReader(request)
                            })
                    }
                }
            } else {
                Spacer()
            }
        }.padding(24).frame(minWidth: 880, minHeight: 640).background(colors.canvas)
            .task { await model.loadReferences() }.onDisappear { model.cancel() }
            .onChange(of: model.base) { _, _ in model.clear() }
            .onChange(of: model.target) { _, _ in model.clear() }
            .onChange(of: model.kind) { _, _ in model.clear() }
            .onChange(of: model.filter) { _, _ in model.visibleFiles = 100 }
    }
    private func referenceField(_ label: String, value: Binding<String>, identifier: String) -> some View {
        HStack {
            Text(label).foregroundStyle(colors.secondaryText)
            TextField("", text: value).autocorrectionDisabled().accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
            Menu {
                ForEach(
                    Array(
                        model.references.filter {
                            value.wrappedValue.isEmpty
                                || $0.localizedCaseInsensitiveContains(value.wrappedValue)
                                || value.wrappedValue == "HEAD"
                        }.prefix(100)), id: \.self
                ) { reference in
                    Button(reference) { value.wrappedValue = reference }
                }
            } label: {
                Image(systemName: "chevron.down")
            }.menuIndicator(.hidden)
                .accessibilityLabel(label + " · " + L10n.text("选择引用"))
                .accessibilityIdentifier(identifier + "-references")
                .help(L10n.text("选择引用"))
        }
    }
}

struct CommitFilesView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Bindable var session: RepositorySession
    @Bindable var detail: CommitDetailState
    var stashContext = false
    var allowsFileHistory = true
    var allowsBlame = true
    var usesWorkspaceInspector = true
    var showsFileList = true
    var onRestore: ((FileModificationRequest) -> Void)? = nil
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
                    if !movesFilesToInspector && showsFileList {
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
                                    .contextMenu {
                                        if !stashContext {
                                            restoreMenu(file, comparison: comparison)
                                        }
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
                                    }.accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("commit-file:" + file.path)
                            }
                        }.listStyle(.inset).scrollContentBackground(.hidden).background(colors.canvas)
                            .frame(height: CGFloat(min(4, comparison.files.count)) * 29 + 12)
                            .accessibilityIdentifier("commit-files").accessibilityLabel(
                                stashContext ? L10n.text("储藏的文件变化") : L10n.text("本次提交的文件变化"))
                    }
                    if detail.diskDisplay == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            if movesFilesToInspector, let path = detail.selectedPath {
                                Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(
                                    .middle
                                )
                                .help(path)
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) {
                                    comparisonReadingControls
                                    Spacer(minLength: 0)
                                    comparisonActions(comparison)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    comparisonReadingControls
                                    HStack {
                                        comparisonActions(comparison)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }.font(.caption).padding(10).background(colors.chrome)
                    }
                    Divider()
                    if let file = comparison.files.first(where: { $0.path == detail.selectedPath }),
                        RasterComparisonView.supports(file.path)
                    {
                        RasterComparisonView(app: app, session: session, source: .commit(file, comparison))
                            .id("raster:\(comparison.commit.id):\(comparison.parent ?? ""):\(file.path)")
                    } else if detail.loadingFile {
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
                            if let file = comparison.files.first(where: { $0.path == detail.selectedPath }) {
                                EncodedContentView(
                                    app: app, session: session, source: .commit(file, comparison)
                                )
                                .id("encoded:\(comparison.commit.id):\(comparison.parent ?? ""):\(file.path)")
                            }
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

    private var comparisonReadingControls: some View {
        HStack(spacing: 12) {
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
                    ForEach([3, 20, 80, 200], id: \.self) { Text(L10n.count("%lld 行", $0)).tag($0) }
                }
                Toggle(L10n.text("忽略空白"), isOn: $app.workspace.diffOptions.ignoreWhitespace)
                Toggle(L10n.text("词级差异"), isOn: $app.workspace.wordDiff)
            }.fixedSize().tint(colors.accentText)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func comparisonActions(_ comparison: CommitComparison) -> some View {
        HStack(spacing: 10) {
            if !stashContext {
                Button {
                    app.presentSignature(
                        SignatureRequest(
                            session: session, objectID: comparison.commit.id, object: .commit,
                            title: comparison.commit.subject))
                } label: {
                    Label(L10n.text("验证签名"), systemImage: "checkmark.seal")
                }.accessibilityIdentifier("commit-signature").help(L10n.text("验证签名"))
            }
            if !stashContext,
                let file = comparison.files.first(where: { $0.path == detail.selectedPath })
            {
                restoreMenu(file, comparison: comparison)
            }
            if allowsBlame, !stashContext,
                let file = comparison.files.first(where: { $0.path == detail.selectedPath }),
                let target = BlameRequest.file(file, in: comparison, session: session)
            {
                Button {
                    guard app.session === session else { return }
                    app.blameRequest = target
                } label: {
                    Label(L10n.text("逐行归属…"), systemImage: "person.text.rectangle")
                }.accessibilityIdentifier("commit-blame").help(L10n.text("逐行归属…"))
            }
            Menu {
                Button(L10n.text("全部文件")) { app.exportComparisonPatch(comparison, session: session) }
                if let file = comparison.files.first(where: { $0.path == detail.selectedPath }) {
                    Button(L10n.text("此文件")) {
                        app.exportComparisonPatch(
                            comparison,
                            paths: Array(Set([file.oldPath, file.path].compactMap { $0 })),
                            session: session)
                    }
                }
            } label: {
                Label(L10n.text("导出补丁…"), systemImage: "square.and.arrow.up")
            }.accessibilityIdentifier("commit-export-patch").help(L10n.text("导出补丁…"))
            if let display = detail.display, !display.diff.binary {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        String(decoding: display.diff.raw, as: UTF8.self), forType: .string)
                } label: {
                    Label(L10n.text("复制补丁"), systemImage: "doc.on.doc")
                }.accessibilityIdentifier("commit-copy-patch").help(L10n.text("复制补丁"))
            }
        }.labelStyle(.iconOnly).fixedSize(horizontal: true, vertical: false)
    }

    private func restoreMenu(_ file: CommitFileChange, comparison: CommitComparison) -> some View {
        Menu {
            Button(L10n.text("恢复目标版本…")) {
                requestRestore(file, comparison: comparison, before: false)
            }
            if comparison.parent != nil {
                Button(L10n.text("恢复起点版本…")) {
                    requestRestore(file, comparison: comparison, before: true)
                }
            }
        } label: {
            Label(L10n.text("恢复文件…"), systemImage: "arrow.uturn.backward")
        }.disabled(app.session !== session || !session.canWrite || session.isBusy)
            .help(L10n.text("恢复文件…"))
            .accessibilityIdentifier("commit-file-restore:" + file.path)
    }

    private func requestRestore(_ file: CommitFileChange, comparison: CommitComparison, before: Bool) {
        guard app.session === session, session.canWrite, !session.isBusy,
            let revision = before ? comparison.parent : comparison.commit.id
        else { return }
        let request = FileModificationRequest(
            session: session,
            source: .history(
                revision: revision, sourcePath: before ? file.oldPath ?? file.path : file.path,
                destinationPath: file.path))
        if let onRestore { onRestore(request) } else { app.fileModificationRequest = request }
    }
}
