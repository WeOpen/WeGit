import AppKit
import SwiftUI
import WeGitCore

struct CommitMessageRequest: Identifiable {
    enum Source { case history, template }
    let id = UUID()
    let session: RepositorySession
    let source: Source
    let draftRevision: UInt64
    @MainActor init(session: RepositorySession, source: Source) {
        self.session = session
        self.source = source
        draftRevision = session.draftRevision
    }
}

struct CommitMessageSheet: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let app: AppState
    let request: CommitMessageRequest
    @State private var messages: [String] = []
    @State private var selection: Int? = 0
    @State private var template: CommitMessageTemplate?
    @State private var loading = false
    @State private var error: String?
    private var chosen: String? {
        if request.source == .template { return template?.text }
        guard let selection, messages.indices.contains(selection) else { return nil }
        return messages[selection]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(
                title: request.source == .history ? L10n.text("消息历史") : L10n.text("提交消息模板"),
                symbol: request.source == .history ? "clock.arrow.circlepath" : "doc.text")
            if loading { ProgressView() }
            if request.source == .history, !messages.isEmpty {
                HSplitView {
                    List(Array(messages.enumerated()), id: \.offset, selection: $selection) { item in
                        Text(
                            item.element.split(separator: "\n", omittingEmptySubsequences: false).first.map(
                                String.init) ?? ""
                        )
                        .foregroundStyle(selection == item.offset ? colors.selectionText : colors.text)
                        .lineLimit(3).tag(item.offset).accessibilityIdentifier(
                            "message-history:\(item.offset)")
                    }.listStyle(.inset).scrollContentBackground(.hidden).background(colors.canvas)
                        .frame(minWidth: 180, idealWidth: 230, maxWidth: 270)
                    preview.frame(minWidth: 360)
                }.frame(height: 330)
            } else if request.source == .template, let template {
                Text(template.url.path).font(.caption.monospaced()).foregroundStyle(colors.secondaryText)
                    .textSelection(.enabled).accessibilityIdentifier("message-template-path")
                preview.frame(height: 330)
                DisclosureGroup(L10n.text("配置来源")) {
                    Text(template.source.scope + " · " + template.source.origin)
                        .font(.caption).textSelection(.enabled)
                }
            } else if !loading && error == nil {
                Text(request.source == .history ? L10n.text("没有保存的提交消息。") : L10n.text("尚未配置提交消息模板。"))
                    .foregroundStyle(colors.secondaryText).frame(maxWidth: .infinity, minHeight: 100)
            }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            HStack {
                if request.source == .history {
                    if request.session.canUndoHistoryClear {
                        Button(L10n.text("撤销清空")) {
                            request.session.undoHistoryClear()
                            do { messages = try request.session.savedMessages() } catch {
                                self.error = error.localizedDescription
                            }
                            selection = messages.isEmpty ? nil : 0
                        }.accessibilityIdentifier("message-history-undo-clear")
                    }
                    Button(L10n.text("清空历史"), role: .destructive) {
                        request.session.clearSavedMessages()
                        messages = []
                        error = nil
                    }.disabled(loading).accessibilityIdentifier("message-history-clear")
                } else if template != nil {
                    Button(L10n.text("导出原文")) { exportTemplate() }
                        .accessibilityIdentifier("message-template-export")
                }
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.session.message.isEmpty ? L10n.text("使用消息") : L10n.text("替换草稿")) {
                    guard let chosen, app.session === request.session else { return }
                    guard
                        request.session.replaceDraft(
                            chosen, owner: app.windowID, revision: request.draftRevision)
                    else {
                        error = L10n.text("草稿已变化，请关闭后重新选择消息。")
                        return
                    }
                    dismiss()
                }.keyboardShortcut(.defaultAction).workbenchPrimaryAction()
                    .disabled(
                        loading || chosen == nil || request.session.isBusy
                            || !request.session.canEditDraft(owner: app.windowID)
                    )
                    .accessibilityIdentifier("message-source-use")
            }.workbenchControlFamily()
        }.accessibilityElement(children: .contain).padding(24).frame(width: 730).task { await load() }
            .onChange(of: app.session?.id) { _, _ in if app.session !== request.session { dismiss() } }
    }
    @ViewBuilder private var preview: some View {
        if let chosen {
            ScrollView {
                Text(chosen).font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.background(colors.canvas).accessibilityIdentifier("message-source-preview")
        } else if template != nil {
            Text(L10n.text("模板不是可读取的 UTF-8 消息，可导出原文。"))
                .foregroundStyle(colors.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func load() async {
        loading = true
        do {
            if request.source == .history {
                messages = try request.session.savedMessages()
            } else {
                let value = try await GitConfigurationService(
                    engine: app.engine, location: request.session.location
                )
                .readCommitMessageTemplate()
                guard !Task.isCancelled else { return }
                template = value
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        loading = false
    }
    private func exportTemplate() {
        guard let template else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = template.url.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            do { try template.bytes.write(to: url, options: .atomic) } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
