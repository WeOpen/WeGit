import AppKit
import SwiftUI
import WeGitCore

struct DiffColumnHeaders: View {
    @Environment(\.themeColors) private var colors
    let columnWidth: CGFloat

    var body: some View {
        HStack(spacing: 1) {
            Text(L10n.text("原始内容")).padding(.horizontal, 12).frame(width: columnWidth, alignment: .leading)
            Text(L10n.text("修改后")).padding(.horizontal, 12).frame(width: columnWidth, alignment: .leading)
        }.font(.caption.weight(.medium)).foregroundStyle(colors.secondaryText)
            .padding(.vertical, 8).background(colors.chrome)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.text("差异列标题"))
            .accessibilityIdentifier("diff-column-headers")
    }
}

struct DiffCodeRow: View {
    @Environment(\.themeColors) private var colors
    @Environment(AppPreferences.self) private var preferences
    enum Content {
        case unified(DiffLine)
        case split(SplitDiffRow)
    }
    let content: Content
    let codeSize: Double
    let wordDiff: Bool
    let highlighting: DiffHighlighting
    var columnWidth: CGFloat = 440
    var selection: DiffTextSelection?
    var performanceID: UUID?
    private var codeFont: Font {
        preferences.codeFont == "system"
            ? .system(size: codeSize, design: .monospaced) : .custom(preferences.codeFont, size: codeSize)
    }

    var body: some View {
        switch content {
        case .unified(let line): unifiedLine(line)
        case .split(let row): splitLine(row)
        }
    }

    private func unifiedLine(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            if preferences.showLineNumbers {
                Text(line.oldLine.map(String.init) ?? "").foregroundStyle(colors.secondaryText).frame(
                    width: 44, alignment: .trailing)
                Text(line.newLine.map(String.init) ?? "").foregroundStyle(colors.secondaryText).frame(
                    width: 44, alignment: .trailing)
            }
            Text(String(line.kind)).foregroundStyle(
                line.kind == "+"
                    ? colors.positive : line.kind == "-" ? colors.negative : colors.secondaryText
            ).frame(width: 28)
            lineText(line).fixedSize(horizontal: true, vertical: false).padding(.trailing, 24)
            Spacer(minLength: 0)
        }.font(codeFont).frame(
            maxWidth: .infinity, minHeight: codeSize + 9
        )
        .background(
            line.kind == "+"
                ? colors.diffAdded
                : line.kind == "-" ? colors.diffRemoved : .clear
        )
        .accessibilityElement(children: .contain).accessibilityIdentifier("unified-diff-row")
        .accessibilityLabel(
            line.kind == "+" ? L10n.text("新增行") : line.kind == "-" ? L10n.text("删除行") : L10n.text("上下文行"))
    }

    private func splitLine(_ row: SplitDiffRow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                if preferences.showLineNumbers {
                    Text(row.old?.oldLine.map(String.init) ?? "").foregroundStyle(colors.secondaryText)
                        .frame(
                            width: 30, alignment: .trailing)
                }
                lineText(row.old, side: .old).fixedSize(horizontal: false, vertical: true)
                    .frame(width: splitCodeWidth, alignment: .topLeading)
            }.frame(width: columnWidth - 20, alignment: .topLeading).padding(.horizontal, 10)
                .padding(.vertical, 4).frame(maxHeight: .infinity, alignment: .top)
                .background(row.old?.kind == "-" ? colors.diffRemoved : .clear)
            Divider().frame(width: 1)
            HStack(alignment: .top, spacing: 10) {
                if preferences.showLineNumbers {
                    Text(row.new?.newLine.map(String.init) ?? "").foregroundStyle(colors.secondaryText)
                        .frame(
                            width: 30, alignment: .trailing)
                }
                lineText(row.new, side: .new).fixedSize(horizontal: false, vertical: true)
                    .frame(width: splitCodeWidth, alignment: .topLeading)
            }.frame(width: columnWidth - 20, alignment: .topLeading).padding(.horizontal, 10)
                .padding(.vertical, 4).frame(maxHeight: .infinity, alignment: .top)
                .background(row.new?.kind == "+" ? colors.diffAdded : .clear)
        }.font(codeFont).fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: codeSize + 9)
            .accessibilityElement(children: .contain).accessibilityIdentifier("split-diff-row")
            .accessibilityLabel(L10n.text("原始与修改后的代码行"))
    }

    @ViewBuilder private func lineText(_ line: DiffLine?, side: DiffCodeSide = .unified) -> some View {
        if let line, line.kind != "\\" {
            let presentation = CodeTextPresentation(
                source: line.content, showWhitespace: preferences.showWhitespace, truncated: line.truncated)
            DiffSelectableText(
                presentation: presentation, attributedText: highlight(line, presentation: presentation),
                selection: selection, lineID: line.id, side: side,
                wrappingWidth: side == .unified ? nil : splitCodeWidth,
                lineEnding: line.hasNewline ? "\n" : "", performanceID: performanceID,
                readingLabel: (side == .old
                    ? L10n.text("原始代码")
                    : side == .new
                        ? L10n.text("修改后的代码")
                        : line.kind == "+"
                            ? L10n.text("新增代码") : line.kind == "-" ? L10n.text("删除的代码") : L10n.text("上下文代码"))
                    + L10n.text(
                        "，第 \(side == .old ? line.oldLine ?? 0 : line.newLine ?? line.oldLine ?? 0) 行")
            )
            .accessibilityIdentifier("diff-code:\(line.id)")
        } else {
            Text(line?.content ?? " ").foregroundStyle(colors.secondaryText)
        }
    }

    private var splitCodeWidth: CGFloat {
        max(1, columnWidth - 20 - (preferences.showLineNumbers ? 40 : 0))
    }

    private func highlight(_ line: DiffLine, presentation: CodeTextPresentation) -> NSAttributedString {
        let font =
            preferences.codeFont == "system"
            ? NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
            : NSFont(name: preferences.codeFont, size: codeSize)
                ?? NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        let result = NSMutableAttributedString(
            string: presentation.displayed,
            attributes: [.font: font, .foregroundColor: colors.resolvedNSColor(.text)])
        func visible(_ range: NSRange) -> Bool {
            range.location != NSNotFound && range.location >= 0 && range.length >= 0
                && range.location <= presentation.visibleSource.utf16.count
                && range.length <= presentation.visibleSource.utf16.count - range.location
        }
        for token in highlighting.syntax[line.id] ?? [] where visible(token.range) {
            let color: Color
            switch token.kind {
            case .keyword: color = colors.keyword
            case .string: color = colors.string
            case .number: color = colors.link
            case .comment: color = colors.comment
            }
            result.addAttribute(.foregroundColor, value: NSColor(color), range: token.range)
        }
        if wordDiff {
            for range in highlighting.words[line.id] ?? [] where visible(range) {
                result.addAttribute(
                    .backgroundColor,
                    value: line.kind == "-"
                        ? colors.resolvedNSColor(.negative).withAlphaComponent(0.22)
                        : colors.resolvedNSColor(.positive).withAlphaComponent(0.24), range: range)
                result.addAttribute(
                    line.kind == "-" ? .strikethroughStyle : .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return result
    }
}
