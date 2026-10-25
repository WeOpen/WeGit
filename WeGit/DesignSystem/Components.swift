import SwiftUI
import WeGitCore

struct EmptyPanel: View {
    @Environment(\.themeColors) private var colors
    let title: String
    let symbol: String
    let message: String
    var artwork: HeritageArtwork.Kind? = nil

    var body: some View {
        VStack(spacing: 12) {
            if let artwork {
                HeritageArtwork(kind: artwork)
            } else {
                WorkbenchEmblem(symbol: symbol)
            }
            Text(title).font(.title3.weight(.semibold))
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(colors.secondaryText).multilineTextAlignment(
                    .center
                ).frame(maxWidth: 360)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBadge: View {
    @Environment(\.themeColors) private var colors
    let symbol: String
    private var tint: Color {
        switch symbol {
        case "U", "D": colors.negative
        case "A": colors.positive
        case "R", "?": colors.tone(.blue)
        case "C": colors.tone(.teal)
        case "T": colors.tone(.violet)
        default: colors.modified
        }
    }
    var body: some View {
        Text(symbol).font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22).background(tint.opacity(0.10), in: .rect(cornerRadius: 4))
            .accessibilityLabel(
                L10n.text("状态：")
                    + ([
                        "U": L10n.text("冲突"), "A": L10n.text("新增"), "M": L10n.text("修改"),
                        "D": L10n.text("删除"), "R": L10n.text("重命名"), "C": L10n.text("复制"),
                        "T": L10n.text("类型变化"),
                        "?": L10n.text("未跟踪"),
                    ][symbol] ?? symbol))
    }
}

struct CountBadge: View {
    @Environment(\.themeColors) private var colors
    let value: String
    var tint: Color?
    var tone: InterfaceTone = .blue

    var body: some View {
        let color = tint ?? colors.tone(tone)
        Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 7).frame(minWidth: 24, minHeight: 20)
            .background(color.opacity(0.10), in: .capsule)
    }
}

struct PanelHeader<Actions: View>: View {
    @Environment(\.themeColors) private var colors
    let title: String
    let symbol: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 9) {
            WorkbenchGlyph(symbol: symbol)
            Text(title).font(.system(size: 13, weight: .semibold))
            actions
        }.padding(.horizontal, AppStyle.panelInset).padding(.vertical, 10).background(colors.chrome)
    }
}

struct SheetTitle: View {
    @Environment(\.themeColors) private var colors
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .foregroundStyle(colors.symbolTint(symbol))
                .frame(width: 34, height: 34)
                .background(
                    colors.symbolTint(symbol).opacity(0.10), in: .rect(cornerRadius: AppStyle.controlRadius)
                )
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
        }
    }
}

/// Keeps the editable native field and its identifier intact inside a shared search surface.
struct WorkbenchSearchField: View {
    @Environment(\.themeColors) private var colors
    let prompt: String
    @Binding var text: String
    let identifier: String
    var focus: FocusState<Bool>.Binding?
    @FocusState private var internalFocus: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                .foregroundStyle(colors.secondaryText).accessibilityHidden(true)
            TextField(prompt, text: $text).textFieldStyle(.plain)
                .autocorrectionDisabled()
                .focused(focus ?? $internalFocus)
                .accessibilityLabel(prompt).accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button {
                    text = ""
                    (focus ?? $internalFocus).wrappedValue = true
                } label: {
                    Image(systemName: "xmark").foregroundStyle(colors.secondaryText)
                }.workbenchIconButton().controlSize(.mini).frame(width: 24, height: 24)
                    .accessibilityLabel(L10n.text("清除\(prompt)"))
                    .accessibilityIdentifier(identifier + "-clear")
                    .help(L10n.text("清除筛选并继续输入"))
            }
        }
        .padding(.horizontal, 9).frame(minHeight: AppStyle.controlHeight)
        .background(colors.surface, in: .rect(cornerRadius: AppStyle.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppStyle.controlRadius)
                .strokeBorder(
                    (focus?.wrappedValue ?? internalFocus) ? colors.focus : colors.controlBorder,
                    lineWidth: contrast == .increased ? 2 : (focus?.wrappedValue ?? internalFocus) ? 1.5 : 1
                )
                .allowsHitTesting(false)
        }
    }
}

struct FileTypeIcon: View {
    @Environment(\.themeColors) private var colors
    let path: String
    private var symbol: String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift", "js", "ts", "jsx", "tsx", "py", "rs", "go", "c", "h", "cpp": "curlybraces"
        case "json", "yml", "yaml", "toml", "plist": "slider.horizontal.3"
        case "png", "jpg", "jpeg", "webp", "gif", "svg": "photo"
        case "md", "txt", "rst": "doc.text"
        case "sh", "bash", "zsh": "terminal"
        default: "doc"
        }
    }
    private var tint: Color {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift", "js", "json", "yml", "yaml", "toml": colors.tone(.amber)
        case "py", "ts", "tsx", "jsx": colors.tone(.blue)
        case "go", "md", "txt", "rst": colors.tone(.teal)
        case "png", "jpg", "jpeg", "webp", "gif", "svg", "c", "h", "cpp": colors.tone(.violet)
        case "rs": colors.tone(.rose)
        case "sh", "bash", "zsh": colors.tone(.green)
        default: colors.tone(.blue)
        }
    }
    var body: some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(tint.opacity(0.10), in: .rect(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

struct DiffChangeSummary: View {
    @Environment(\.themeColors) private var colors
    let additions: Int
    let deletions: Int
    var body: some View {
        HStack(spacing: 7) {
            Text("+\(additions)").foregroundStyle(colors.positive)
            Text("−\(deletions)").foregroundStyle(colors.negative)
        }.font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(colors.surface, in: .rect(cornerRadius: 6))
    }
}

struct BannerSurface: ViewModifier {
    @Environment(\.themeColors) private var colors
    let tint: Color
    func body(content: Content) -> some View {
        content.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.07))
            .overlay(alignment: .leading) {
                Rectangle().fill(tint).frame(width: 3).allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(tint.opacity(0.14)).frame(height: 0.5).allowsHitTesting(false)
            }
    }
}

struct DetailHeader: View {
    @Environment(\.themeColors) private var colors
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline).lineLimit(1).truncationMode(.middle).help(title)
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(colors.secondaryText)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorkbenchMessageField: View {
    @Environment(\.themeColors) private var colors
    @Binding var message: String
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        TextField(L10n.text("提交消息；⌥↩ 换行"), text: $message, axis: .vertical)
            .lineLimit(2...5).textFieldStyle(.plain).focused($focused)
            .font(.system(size: 13)).padding(10)
            .background(colors.surface, in: .rect(cornerRadius: AppStyle.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: AppStyle.controlRadius)
                    .strokeBorder(
                        focused ? colors.focus : colors.controlBorder,
                        lineWidth: contrast == .increased ? 2 : focused ? 1.5 : 1
                    ).allowsHitTesting(false)
            }
            .accessibilityLabel(L10n.text("提交消息")).accessibilityIdentifier("commit-message")
            .help(L10n.text("⌥↩ 换行添加详细描述，⌘↩ 提交已暂存内容"))
    }
}

struct CommitReadiness: View {
    @Environment(\.themeColors) private var colors
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(count == 0 ? colors.secondaryText : colors.text)
            Text(L10n.text("已暂存")).font(.system(size: 12)).foregroundStyle(
                colors.secondaryText)
        }.frame(height: 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.count("已暂存 %lld 个文件", count))
            .accessibilityIdentifier("commit-staged-count")
    }
}

struct ReferenceBadge: View {
    @Environment(\.themeColors) private var colors
    let name: String
    var selected = false
    var symbol: String? = nil
    var tone: InterfaceTone? = nil

    var body: some View {
        let tint = tone.map { colors.tone($0) } ?? colors.symbolTint(symbol ?? "arrow.triangle.branch")
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                    .accessibilityHidden(true)
            }
            Text(name).font(.system(size: 11, weight: .medium))
                .lineLimit(1).truncationMode(.middle).accessibilityLabel(name)
        }
        .foregroundStyle(selected ? colors.text : tint)
        .padding(.horizontal, 7).frame(minHeight: HeritageTokens.referenceHeight)
        .background(
            selected ? colors.surface : tint.opacity(0.09),
            in: HeritageReferenceShape()
        )
        .overlay {
            HeritageReferenceShape().strokeBorder(
                selected ? colors.controlBorder : colors.border, lineWidth: 0.5
            )
            .allowsHitTesting(false)
        }
        .help(name)
    }
}
