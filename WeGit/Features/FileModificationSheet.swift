import SwiftUI
import WeGitCore

struct FileModificationRequest: Identifiable {
    enum Source {
        case selectedLines(FileDiff, Set<Int>)
        case history(revision: String, sourcePath: String, destinationPath: String)
    }
    let id = UUID()
    let session: RepositorySession
    let source: Source
    var path: String {
        switch source {
        case .selectedLines(let diff, _): diff.path
        case .history(_, _, let path): path
        }
    }
    var title: String {
        switch source {
        case .selectedLines: L10n.text("丢弃所选行")
        case .history: L10n.text("恢复历史文件")
        }
    }
}

struct FileModificationSheet: View {
    @Environment(\.themeColors) private var colors
    let app: AppState
    let request: FileModificationRequest
    @State private var layer = RecoveryLayer.worktree
    @State private var plan: FileModificationPlan?
    @State private var error: String?
    @State private var preparing = true
    @State private var attempted = false
    private var isCurrent: Bool {
        app.session === request.session && app.fileModificationRequest?.id == request.id
    }

    var body: some View {
        @Bindable var session = request.session
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle(title: request.title, symbol: "doc.badge.arrow.up")
            Text(request.path).font(.callout.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("file-modification-path")
            if case .history(let revision, let sourcePath, _) = request.source {
                LabeledContent(L10n.text("来源提交"), value: String(revision.prefix(12)))
                    .font(.callout.monospaced())
                if sourcePath != request.path {
                    LabeledContent(L10n.text("来源路径"), value: sourcePath).font(.callout.monospaced())
                }
                Picker(L10n.text("恢复到"), selection: $layer) {
                    ForEach(RecoveryLayer.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).disabled(attempted)
                    .accessibilityIdentifier("file-modification-layer")
            }
            if preparing {
                ProgressView(L10n.text("准备文件预览…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan {
                HStack {
                    if let count = plan.selectedLineCount { Text(L10n.count("%lld 行", count)) }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(plan.resultBytes), countStyle: .file))
                        .monospacedDigit().foregroundStyle(colors.secondaryText)
                }
                if plan.deletesFile {
                    Label(L10n.text("删除文件"), systemImage: "trash").foregroundStyle(colors.negative)
                    Spacer()
                } else if let preview = plan.resultPreview {
                    ScrollView([.vertical, .horizontal]) {
                        Text(preview).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(L10n.text("操作后的文件内容"))
                        .accessibilityIdentifier("file-modification-preview")
                } else {
                    Spacer()
                    Image(systemName: "doc").font(.largeTitle).foregroundStyle(colors.secondaryText)
                        .frame(maxWidth: .infinity).accessibilityHidden(true)
                    Spacer()
                }
            }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel,
                    result: session.operationFeedback, context: .standard, fallback: "")
            }
            HStack {
                if attempted, !session.isBusy {
                    Button(L10n.text("查看恢复记录")) {
                        app.pendingRecoveryAfterFileModification = RecoveryBrowserRequest(
                            session: session, initialTab: 1)
                        close()
                    }.accessibilityIdentifier("file-modification-recovery")
                }
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : attempted ? L10n.text("关闭") : L10n.text("取消")) {
                    if session.isBusy { session.cancel() } else { close() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("file-modification-cancel")
                if !attempted {
                    Button(request.title, role: .destructive) { execute() }
                        .keyboardShortcut(.defaultAction).workbenchPrimaryAction()
                        .disabled(preparing || plan == nil || !session.canWrite || session.isBusy)
                        .accessibilityIdentifier("file-modification-execute")
                }
            }
        }.padding(24).frame(width: 620, height: 510).interactiveDismissDisabled(session.isBusy)
            .task(id: layer) { await prepare() }
    }

    private func prepare() async {
        guard isCurrent, !attempted else { return }
        plan = nil
        error = nil
        preparing = true
        let requestedLayer = layer
        do {
            let result: FileModificationPlan
            switch request.source {
            case .selectedLines(let diff, let ids):
                result = try await request.session.service.prepareSelectedLineDiscard(
                    diff: diff, lineIDs: ids)
            case .history(let revision, let source, let destination):
                result = try await request.session.service.prepareFileRestore(
                    revision: revision, sourcePath: source, destinationPath: destination,
                    layer: requestedLayer)
            }
            guard !Task.isCancelled, isCurrent, layer == requestedLayer else { return }
            plan = result
        } catch {
            guard !Task.isCancelled, isCurrent, layer == requestedLayer else { return }
            self.error = error.localizedDescription
        }
        preparing = false
    }

    private func execute() {
        guard isCurrent, let plan, !attempted, request.session.canWrite, !request.session.isBusy else {
            return
        }
        attempted = true
        request.session.performResult(request.title) { service in
            do {
                _ = try await service.executeFileModification(plan)
                return .completed(message: L10n.text("文件更新完成，原始内容已备份。"))
            } catch let unknown as RecoveryOutcomeUnknown {
                return .needsReview(message: unknown.localizedDescription)
            }
        }
    }

    private func close() {
        guard app.fileModificationRequest?.id == request.id else { return }
        app.fileModificationRequest = nil
    }
}
