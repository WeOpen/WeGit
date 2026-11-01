import SwiftUI
import WeGitCore

struct ConflictEditorRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let path: String
    let expectedHead: String?
}

struct ConflictEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var colors
    let app: AppState
    let request: ConflictEditorRequest
    @State private var resultSelection: TextSelection?
    @State private var document: ConflictEditorDocument?
    @State private var resultText = ""
    @State private var analysis = ConflictMarkerParser.analyze("")
    @State private var selectedBlock = 0
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var confirmsDiscard = false

    private var session: RepositorySession { request.session }
    private var hasUnsavedResult: Bool {
        guard let document else { return false }
        return resultText != document.result.text
    }
    private var canMarkResolved: Bool {
        guard document != nil, !loading, !saving, session.canWrite else { return false }
        return !hasUnsavedResult && analysis.resolved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if loading {
                ProgressView(L10n.text("读取冲突内容…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if document == nil, let error {
                VStack(spacing: 12) {
                    EmptyPanel(
                        title: L10n.text("无法打开冲突编辑器"),
                        symbol: "exclamationmark.triangle",
                        message: error)
                    Button(L10n.text("重试")) { Task { await load() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let document {
                editor(document)
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 980, minHeight: 680)
        .interactiveDismissDisabled(hasUnsavedResult || saving)
        .task(id: request.id) { await load() }
        .confirmationDialog(
            L10n.text("丢弃未保存的冲突结果？"), isPresented: $confirmsDiscard,
            titleVisibility: .visible
        ) {
            Button(L10n.text("丢弃并关闭"), role: .destructive) { dismissEditor() }
            Button(L10n.text("继续编辑"), role: .cancel) {}
        } message: {
            Text(L10n.text("工作区文件尚未写入这些编辑。"))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            SheetTitle(title: L10n.text("冲突编辑器"), symbol: "arrow.triangle.branch")
            VStack(alignment: .leading, spacing: 3) {
                Text(request.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                if let document {
                    Text(L10n.text("来源：\(document.sequencer.title) · 冲突块 \(analysis.blocks.count)"))
                        .font(.caption).foregroundStyle(colors.secondaryText)
                }
            }.textSelection(.enabled)
            Spacer()
            if hasUnsavedResult {
                Label(L10n.text("未保存"), systemImage: "pencil.circle")
                    .font(.caption).foregroundStyle(colors.modified)
                    .accessibilityIdentifier("conflict-editor-unsaved")
            }
            Button(L10n.text("关闭")) { close() }
                .keyboardShortcut(.cancelAction)
                .disabled(saving)
                .accessibilityIdentifier("conflict-editor-close")
        }
    }

    private func editor(_ document: ConflictEditorDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if analysis.malformed {
                Label(
                    L10n.text("结果包含不完整的冲突标记，不能标记已解决。"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption).foregroundStyle(colors.negative)
                .modifier(BannerSurface(tint: colors.negative))
                .accessibilityIdentifier("conflict-editor-malformed")
            }
            HStack(spacing: 8) {
                Button {
                    previousBlock()
                } label: {
                    Image(systemName: "chevron.left")
                }.workbenchIconButton().disabled(analysis.blocks.isEmpty || selectedBlock == 0)
                    .accessibilityLabel(L10n.text("上一个冲突块"))
                Text(
                    analysis.blocks.isEmpty
                        ? L10n.text("没有未处理冲突块")
                        : L10n.text("冲突块 \(selectedBlock + 1) / \(analysis.blocks.count)")
                )
                .font(.caption.monospacedDigit())
                .frame(minWidth: 130)
                Button {
                    nextBlock()
                } label: {
                    Image(systemName: "chevron.right")
                }.workbenchIconButton().disabled(
                    analysis.blocks.isEmpty || selectedBlock >= analysis.blocks.count - 1
                )
                .accessibilityLabel(L10n.text("下一个冲突块"))
                Spacer()
                if let block = currentBlock {
                    blockActions(block)
                }
            }
            LazyVGrid(
                columns: [GridItem(.flexible(minimum: 260)), GridItem(.flexible(minimum: 260))],
                spacing: 10
            ) {
                sourcePanel(document.base)
                sourcePanel(document.ours)
                sourcePanel(document.theirs)
                resultPanel(document.result)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let error {
                Text(error).font(.caption).foregroundStyle(colors.negative).lineLimit(2)
                    .textSelection(.enabled).accessibilityIdentifier("conflict-editor-error")
            } else {
                Text(
                    analysis.resolved
                        ? L10n.text("结果没有未处理标记。保存后仍需单独确认标记已解决。")
                        : L10n.text("保存只更新工作区文件，不会自动标记已解决。")
                )
                .font(.caption).foregroundStyle(colors.secondaryText)
            }
            Spacer()
            Button(L10n.text("保存结果")) { save() }
                .workbenchControlFamily()
                .disabled(!canSave)
                .accessibilityIdentifier("conflict-editor-save")
            Button(L10n.text("标记已解决")) { markResolved() }
                .workbenchPrimaryAction().tint(colors.primaryAction)
                .disabled(!canMarkResolved)
                .accessibilityIdentifier("conflict-editor-mark-resolved")
        }
    }

    private var canSave: Bool {
        document != nil && hasUnsavedResult && !loading && !saving && session.canWrite
    }

    private var currentBlock: ConflictMarkerBlock? {
        guard analysis.blocks.indices.contains(selectedBlock) else { return nil }
        return analysis.blocks[selectedBlock]
    }

    @ViewBuilder private func blockActions(_ block: ConflictMarkerBlock) -> some View {
        HStack(spacing: 6) {
            ForEach(ConflictEditorChoice.allCases, id: \.self) { choice in
                Button(choice.title) { accept(choice, block: block) }
                    .controlSize(.small)
                    .disabled(
                        (choice == .base && baseBytes(for: block) == nil) || saving || !session.canWrite
                    )
                    .help(
                        choice == .base && baseBytes(for: block) == nil
                            ? L10n.text("当前版本没有可靠的 BASE 块映射，已禁用自动接受。")
                            : choice.title
                    )
                    .accessibilityIdentifier("conflict-editor-accept-\(choice.rawValue)")
            }
        }
    }

    private func sourcePanel(_ buffer: ConflictEditorBuffer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(buffer.side.title).font(.caption.weight(.semibold))
                Text(buffer.source.title).font(.caption).foregroundStyle(colors.secondaryText)
                Spacer()
                if let revision = buffer.source.revision {
                    Text(String(revision.prefix(12))).font(.caption2.monospaced())
                        .foregroundStyle(colors.secondaryText).help(revision)
                }
            }.padding(9).background(colors.chrome)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(buffer.text).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.background(colors.surface)
        }
        .frame(minHeight: 220, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: AppStyle.controlRadius).stroke(colors.controlBorder))
        .accessibilityIdentifier("conflict-editor-\(buffer.side.rawValue)")
    }

    private func resultPanel(_ buffer: ConflictEditorBuffer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(ConflictEditorSide.result.title).font(.caption.weight(.semibold))
                Text(L10n.text("可编辑工作区结果")).font(.caption).foregroundStyle(colors.secondaryText)
                Spacer()
                if analysis.resolved {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(colors.positive)
                        .accessibilityLabel(L10n.text("没有未处理冲突标记"))
                }
            }.padding(9).background(colors.chrome)
            Divider()
            TextEditor(
                text: Binding(
                    get: { resultText },
                    set: { value in
                        updateResult(value)
                        error = nil
                    }), selection: $resultSelection
            )
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden).background(colors.surface)
            .padding(6).disabled(saving)
            .accessibilityIdentifier("conflict-editor-result")
        }
        .frame(minHeight: 220, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: AppStyle.controlRadius).stroke(colors.controlBorder))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conflict-editor-result-panel")
        .onChange(of: buffer.text) { _, value in
            if !hasUnsavedResult { updateResult(value) }
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let loaded = try await session.service.readConflictEditor(
                path: request.path, expectedHead: request.expectedHead)
            guard app.conflictEditorRequest?.id == request.id else { return }
            document = loaded
            updateResult(loaded.result.text)
            selectedBlock = 0
            navigateToSelectedBlock()
        } catch {
            guard app.conflictEditorRequest?.id == request.id else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func accept(_ choice: ConflictEditorChoice, block: ConflictMarkerBlock) {
        let base = choice == .base ? baseBytes(for: block) : nil
        guard choice != .base || base != nil else { return }
        do {
            updateResult(
                try ConflictMarkerParser.replacing(
                    text: resultText, block: block, with: choice, baseOverride: base))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func baseBytes(for block: ConflictMarkerBlock) -> Data? {
        guard let resolutions = document?.blockResolutions else { return nil }
        let matches = resolutions.filter {
            $0.oursBytes == block.oursBytes && $0.theirsBytes == block.theirsBytes
        }
        guard matches.count == 1 else { return nil }
        return matches[0].baseBytes
    }

    private func updateResult(_ text: String) {
        resultText = text
        analysis = ConflictMarkerParser.analyze(text)
        selectedBlock = min(selectedBlock, max(analysis.blocks.count - 1, 0))
    }

    private func previousBlock() {
        selectedBlock = max(0, selectedBlock - 1)
        navigateToSelectedBlock()
    }

    private func nextBlock() {
        selectedBlock = min(max(analysis.blocks.count - 1, 0), selectedBlock + 1)
        navigateToSelectedBlock()
    }

    private func navigateToSelectedBlock() {
        guard let block = currentBlock,
            let lower = String.Index(
                resultText.utf8.index(
                    resultText.utf8.startIndex, offsetBy: block.replacementRange.lowerBound),
                within: resultText),
            let upper = String.Index(
                resultText.utf8.index(
                    resultText.utf8.startIndex, offsetBy: block.replacementRange.upperBound),
                within: resultText)
        else {
            resultSelection = nil
            return
        }
        resultSelection = TextSelection(range: lower..<upper)
    }

    private func save() {
        guard let document, canSave else { return }
        saving = true
        error = nil
        Task { @MainActor in
            do {
                let updated = try await session.service.saveConflictResult(document, text: resultText)
                self.document = updated
                updateResult(updated.result.text)
                await session.refresh()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    private func markResolved() {
        guard let document, canMarkResolved else { return }
        saving = true
        error = nil
        Task { @MainActor in
            do {
                try await session.service.markConflictResolved(document)
                await session.refresh()
                dismissEditor()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    private func close() {
        guard !saving else { return }
        if hasUnsavedResult {
            confirmsDiscard = true
        } else {
            dismissEditor()
        }
    }

    private func dismissEditor() {
        app.conflictEditorRequest = nil
        dismiss()
    }
}
