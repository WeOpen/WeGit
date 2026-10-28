import AppKit
import SwiftUI
import WeGitCore

struct BlameRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let path: String
    let revision: String

    static func file(_ file: CommitFileChange, in comparison: CommitComparison, session: RepositorySession)
        -> Self?
    {
        guard let revision = file.status == "D" ? comparison.parent : comparison.commit.id else { return nil }
        return Self(session: session, path: file.path, revision: revision)
    }

    @MainActor var reader: RepositoryService {
        var engine = session.service.engine
        engine.environment["GIT_NO_REPLACE_OBJECTS"] = "1"
        engine.environment["GIT_NO_LAZY_FETCH"] = "1"
        return RepositoryService(location: session.location, engine: engine, queue: session.service.queue)
    }
}

private enum BlameInspection: Identifiable {
    case commit(GitCommit)
    case history(FileHistoryRequest)
    var id: String {
        switch self {
        case .commit(let commit): "commit:" + commit.id
        case .history(let request): "history:" + request.id.uuidString
        }
    }
}

struct BlameSheet: View {
    let app: AppState
    let request: BlameRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors
    @State private var state: BlameState
    @State private var inspection: BlameInspection?
    @State private var reload = UUID()

    init(app: AppState, request: BlameRequest) {
        self.app = app
        self.request = request
        _state = State(initialValue: BlameState(service: request.reader))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SheetTitle(title: L10n.text("逐行归属"), symbol: "person.text.rectangle")
                    .help(L10n.text("显示固定提交中的原始作者；Git 默认跟随重命名，不启用复制搜索或忽略提交。合并中的归属可能来自父历史。"))
                Spacer()
                if state.loading {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("取消读取")) { state.cancel(userInitiated: true) }
                        .accessibilityIdentifier("blame-cancel")
                }
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("blame-close")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(request.path).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
                Spacer()
                Text(request.revision.prefix(12)).font(.caption.monospaced()).textSelection(.enabled)
            }.accessibilityElement(children: .ignore)
                .accessibilityLabel(request.path + " · " + request.revision).accessibilityIdentifier(
                    "blame-target")
            Divider()
            if let page = state.page, let document = state.document {
                if page.lines.isEmpty {
                    EmptyPanel(title: L10n.text("文件为空"), symbol: "doc", message: "")
                } else {
                    GeometryReader { geometry in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(page.lines.enumerated()), id: \.element.id) { index, line in
                                    let startsGroup =
                                        index == 0 || page.lines[index - 1].commit.id != line.commit.id
                                        || page.lines[index - 1].originalPath != line.originalPath
                                    lineRow(
                                        line, document: document, startsGroup: startsGroup,
                                        width: max(160, geometry.size.width - 290))
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("blame-lines")
                            .id(page.lines.first?.number)
                    }
                }
            } else if state.loading {
                ProgressView(L10n.text("读取逐行归属…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyPanel(
                    title: state.cancelled ? L10n.text("已取消读取") : L10n.text("无法读取逐行归属"),
                    symbol: "doc.text.magnifyingglass", message: state.error ?? "")
            }
            if state.page != nil, let error = state.error {
                Text(error).foregroundStyle(colors.negative).textSelection(.enabled)
            }
            HStack {
                Button(L10n.text("上一页")) {
                    if let first = state.page?.previousLine { state.loadPage(firstLine: first) }
                }.disabled(state.loading || state.page?.previousLine == nil).accessibilityIdentifier(
                    "blame-previous")
                Button(L10n.text("下一页")) {
                    if let first = state.page?.nextLine { state.loadPage(firstLine: first) }
                }.disabled(state.loading || state.page?.nextLine == nil).accessibilityIdentifier("blame-next")
                if !state.loading, state.error != nil || state.cancelled {
                    Button(L10n.text("重试")) {
                        if state.document == nil { reload = UUID() } else { state.retryPage() }
                    }.accessibilityIdentifier("blame-retry")
                }
                Spacer()
                if let document = state.document, let page = state.page {
                    Text(
                        L10n.text(
                            "\(page.lines.first?.number ?? 0)–\(page.lines.last?.number ?? 0) / \(document.lineCount) 行"
                        )
                    )
                    .font(.caption.monospacedDigit()).foregroundStyle(colors.secondaryText)
                    .accessibilityIdentifier("blame-range")
                }
            }
        }.padding(20).frame(width: 920, height: 620).workbenchControlFamily()
            .task(id: reload) {
                guard app.session === request.session else {
                    dismiss()
                    return
                }
                await state.open(path: request.path, revision: request.revision)
            }
            .onDisappear { state.release() }
            .onChange(of: app.session.map(ObjectIdentifier.init)) { _, _ in
                if app.session !== request.session {
                    state.release()
                    dismiss()
                }
            }
            .sheet(item: $inspection) { target in
                Group {
                    switch target {
                    case .commit(let commit): BlameCommitSheet(app: app, request: request, commit: commit)
                    case .history(let history):
                        FileHistorySheet(app: app, request: history, allowsBlame: false)
                    }
                }.workbenchSheet(app.preferences)
            }
    }

    private func lineRow(_ line: BlameLine, document: BlameDocument, startsGroup: Bool, width: CGFloat)
        -> some View
    {
        let presentation = CodeTextPresentation(
            source: line.content, showWhitespace: app.preferences.showWhitespace)
        let font =
            app.preferences.codeFont == "system"
            ? NSFont.monospacedSystemFont(ofSize: app.codeSize, weight: .regular)
            : NSFont(name: app.preferences.codeFont, size: app.codeSize)
                ?? NSFont.monospacedSystemFont(ofSize: app.codeSize, weight: .regular)
        let attributed = NSAttributedString(
            string: presentation.displayed,
            attributes: [.font: font, .foregroundColor: colors.resolvedNSColor(.text)])
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if startsGroup {
                    HStack(spacing: 8) {
                        Button(String(line.commit.id.prefix(7))) { inspection = .commit(line.commit) }
                            .buttonStyle(.plain).foregroundStyle(colors.link).font(.caption.monospaced())
                            .accessibilityIdentifier("blame-commit:\(line.number)")
                        Text(line.commit.author).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            showHistory(line)
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }.buttonStyle(.plain).foregroundStyle(colors.link)
                            .help(L10n.text("查看文件历史…"))
                            .accessibilityLabel(L10n.text("查看文件历史…"))
                            .accessibilityIdentifier("blame-file-history:\(line.number)")
                    }
                    Text(
                        line.commit.date,
                        format: Date.FormatStyle(date: .numeric, time: .omitted).locale(L10n.locale)
                    )
                    .font(.caption2).foregroundStyle(colors.secondaryText)
                }
            }.frame(width: 210, alignment: .leading)
            Text(String(line.number)).font(.caption.monospacedDigit()).foregroundStyle(colors.secondaryText)
                .frame(width: 38, alignment: .trailing)
            DiffSelectableText(
                presentation: presentation, attributedText: attributed, selection: state.selection,
                lineID: line.number,
                wrappingWidth: width,
                lineEnding: line.number < document.lineCount || document.hasFinalNewline ? "\n" : "",
                readingLabel: L10n.text(
                    "第 \(line.number) 行，作者 \(line.commit.author)，提交 \(line.commit.id.prefix(12))")
            ).frame(width: width, alignment: .leading).accessibilityIdentifier("blame-code:\(line.number)")
        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            .background(startsGroup ? colors.chrome.opacity(0.55) : Color.clear)
            .accessibilityElement(children: .contain).accessibilityIdentifier("blame-line:\(line.number)")
            .help(line.originalPath + " · " + L10n.text("第 \(line.originalNumber) 行"))
            .contextMenu {
                Button(L10n.text("查看来源提交")) { inspection = .commit(line.commit) }
                Button(L10n.text("查看文件历史…")) {
                    showHistory(line)
                }
            }
    }

    private func showHistory(_ line: BlameLine) {
        inspection = .history(
            FileHistoryRequest(
                session: request.session, path: line.originalPath, tip: line.commit.id,
                readService: request.reader))
    }
}

private struct BlameCommitSheet: View {
    let app: AppState
    let request: BlameRequest
    let commit: GitCommit
    @Environment(\.dismiss) private var dismiss
    @State private var detail: CommitDetailState

    init(app: AppState, request: BlameRequest, commit: GitCommit) {
        self.app = app
        self.request = request
        self.commit = commit
        _detail = State(initialValue: CommitDetailState(service: request.reader))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(commit.subject).font(.headline).lineLimit(3)
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("blame-commit-close")
            }
            Text(commit.id).font(.caption.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("blame-inspected-commit")
            CommitFilesView(
                app: app, session: request.session, detail: detail,
                allowsFileHistory: false, allowsBlame: false, usesWorkspaceInspector: false)
        }.padding(20).frame(width: 920, height: 620)
            .task { await detail.select(commit, parent: commit.parents.first) }
            .onDisappear { detail.releaseCache() }
    }
}
