import SwiftUI
import WeGitCore

struct EmptyPanel: View {
    @Environment(\.themeColors) private var colors
    let title: String
    let symbol: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            WorkbenchEmblem(symbol: symbol)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(colors.secondaryText).multilineTextAlignment(
                .center
            ).frame(
                maxWidth: 360)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBadge: View {
    @Environment(\.themeColors) private var colors
    let symbol: String
    private var tint: Color {
        symbol == "U" || symbol == "D"
            ? colors.negative
            : symbol == "A" || symbol == "?" ? colors.positive : colors.modified
    }
    var body: some View {
        Text(symbol).font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(colors.text)
            .frame(width: 22, height: 22).background(tint.opacity(0.12), in: .rect(cornerRadius: 6))
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

    var body: some View {
        Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(.primary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background((tint ?? colors.secondaryText).opacity(0.09), in: .capsule)
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
                .foregroundStyle(colors.text)
                .frame(width: 34, height: 34)
                .background(colors.surface, in: .rect(cornerRadius: 10))
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
                    (focus?.wrappedValue ?? internalFocus) ? colors.focus : colors.border,
                    lineWidth: (focus?.wrappedValue ?? internalFocus) || contrast == .increased ? 1.5 : 0.5
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
    var body: some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .regular))
            .foregroundStyle(colors.text).opacity(0.8)
            .frame(width: 26, height: 26)
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: 7))
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

struct OperationFeedback: View {
    @Environment(\.themeColors) private var colors
    let busy: Bool
    let activity: String
    let notice: String?
    let fallback: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            } else if notice != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(colors.positive).accessibilityHidden(true)
                    .transition(.opacity)
            }
            Text(busy ? activity + "…" : notice ?? fallback).lineLimit(1)
                .contentTransition(.opacity)
        }
        .font(.caption).foregroundStyle(colors.secondaryText)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            (notice == nil ? colors.secondaryText : colors.positive).opacity(0.07), in: .capsule
        )
        .animation(reduceMotion || !preferences.interfaceMotion ? nil : AppMotion.feedback, value: busy)
        .animation(reduceMotion || !preferences.interfaceMotion ? nil : AppMotion.feedback, value: notice)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("operation-feedback")
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
            Text(subtitle).font(.caption).foregroundStyle(colors.secondaryText)
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
                        focused ? colors.focus : colors.border,
                        lineWidth: focused || contrast == .increased ? 1.5 : 0.5
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
        VStack(spacing: 4) {
            Text("\(count)").font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(count == 0 ? colors.secondaryText : colors.text)
            Text(L10n.text("已暂存")).font(.system(size: 11, weight: .medium)).foregroundStyle(
                colors.secondaryText)
        }.frame(width: 44, height: 49)
            .background(colors.surface, in: .rect(cornerRadius: 10))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.count("已暂存 %lld 个文件", count))
            .accessibilityIdentifier("commit-staged-count")
    }
}

struct ReferenceBadge: View {
    @Environment(\.themeColors) private var colors
    let name: String
    var selected = false

    var body: some View {
        Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(selected ? colors.selectionText : colors.text)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(colors.text.opacity(selected ? 0.07 : 0.045), in: .capsule)
            .help(name)
    }
}
