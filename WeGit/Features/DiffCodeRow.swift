import AppKit
import SwiftUI
import WeGitCore

struct DiffCodeRow: View {
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
                Text(line.oldLine.map(String.init) ?? "").foregroundStyle(AppColors.secondaryText).frame(
                    width: 44, alignment: .trailing)
                Text(line.newLine.map(String.init) ?? "").foregroundStyle(AppColors.secondaryText).frame(
                    width: 44, alignment: .trailing)
            }
            Text(String(line.kind)).foregroundStyle(
                line.kind == "+"
                    ? AppColors.positive : line.kind == "-" ? AppColors.negative : AppColors.secondaryText
            ).frame(width: 28)
            lineText(line).fixedSize(horizontal: true, vertical: false).padding(.trailing, 24)
            Spacer(minLength: 0)
        }.font(codeFont).frame(
            maxWidth: .infinity, minHeight: codeSize + 9
        )
        .background(
            line.kind == "+" ? Color.green.opacity(0.10) : line.kind == "-" ? Color.red.opacity(0.10) : .clear
        )
        .accessibilityElement(children: .contain).accessibilityIdentifier("unified-diff-row")
        .accessibilityLabel(line.kind == "+" ? "新增行" : line.kind == "-" ? "删除行" : "上下文行")
    }

    private func splitLine(_ row: SplitDiffRow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                if preferences.showLineNumbers {
                    Text(row.old?.oldLine.map(String.init) ?? "").foregroundStyle(AppColors.secondaryText)
                        .frame(
                            width: 30, alignment: .trailing)
                }
                lineText(row.old, side: .old).fixedSize(horizontal: false, vertical: true)
                    .frame(width: splitCodeWidth, alignment: .topLeading)
            }.frame(width: columnWidth - 20, alignment: .topLeading).padding(.horizontal, 10)
                .padding(.vertical, 4).frame(maxHeight: .infinity, alignment: .top)
                .background(row.old?.kind == "-" ? Color.red.opacity(0.10) : .clear)
            Divider().frame(width: 1)
            HStack(alignment: .top, spacing: 10) {
                if preferences.showLineNumbers {
                    Text(row.new?.newLine.map(String.init) ?? "").foregroundStyle(AppColors.secondaryText)
                        .frame(
                            width: 30, alignment: .trailing)
                }
                lineText(row.new, side: .new).fixedSize(horizontal: false, vertical: true)
                    .frame(width: splitCodeWidth, alignment: .topLeading)
            }.frame(width: columnWidth - 20, alignment: .topLeading).padding(.horizontal, 10)
                .padding(.vertical, 4).frame(maxHeight: .infinity, alignment: .top)
                .background(row.new?.kind == "+" ? Color.green.opacity(0.10) : .clear)
        }.font(codeFont).fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: codeSize + 9)
            .accessibilityElement(children: .contain).accessibilityIdentifier("split-diff-row")
            .accessibilityLabel("原始与修改后的代码行")
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
                    ? "原始代码"
                    : side == .new
                        ? "修改后的代码" : line.kind == "+" ? "新增代码" : line.kind == "-" ? "删除的代码" : "上下文代码")
                    + "，第 \(side == .old ? line.oldLine ?? 0 : line.newLine ?? line.oldLine ?? 0) 行"
            )
            .accessibilityIdentifier("diff-code:\(line.id)")
        } else {
            Text(line?.content ?? " ").foregroundStyle(AppColors.secondaryText)
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
            string: presentation.displayed, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        func visible(_ range: NSRange) -> Bool {
            range.location != NSNotFound && range.location >= 0 && range.length >= 0
                && range.location <= presentation.visibleSource.utf16.count
                && range.length <= presentation.visibleSource.utf16.count - range.location
        }
        for token in highlighting.syntax[line.id] ?? [] where visible(token.range) {
            let color: Color
            switch token.kind {
            case .keyword: color = AppColors.keyword
            case .string: color = AppColors.string
            case .number: color = AppColors.link
            case .comment: color = AppColors.secondaryText
            }
            result.addAttribute(.foregroundColor, value: NSColor(color), range: token.range)
        }
        if wordDiff {
            for range in highlighting.words[line.id] ?? [] where visible(range) {
                result.addAttribute(
                    .backgroundColor,
                    value: line.kind == "-"
                        ? NSColor.systemRed.withAlphaComponent(0.22)
                        : NSColor.systemGreen.withAlphaComponent(0.24), range: range)
                result.addAttribute(
                    line.kind == "-" ? .strikethroughStyle : .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return result
    }
}
