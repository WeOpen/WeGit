import SwiftUI
import WeGitCore

/// Wrapped split rows can change the document height and its scroll insets
/// without a horizontal scroll. Keep those layout changes in the same state
/// as the offset so viewport controls do not retain an earlier layout.
struct DiffScrollGeometry: Equatable {
    var contentOffset: CGPoint = .zero
    var contentSize: CGSize = .zero
    var contentInsets = EdgeInsets()

    init() {}

    init(_ geometry: ScrollGeometry) {
        contentOffset = geometry.contentOffset
        contentSize = geometry.contentSize
        contentInsets = geometry.contentInsets
    }

    var horizontalOffset: CGFloat { max(0, contentOffset.x) }
}

struct DiffContextControls: View {
    @Environment(\.themeColors) private var colors
    let gap: DiffContextGap
    let expansion: DiffContextExpansion
    let expandingGap: Int?
    var onExpand: () -> Void
    var onCancel: () -> Void
    var onCollapse: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if expandingGap == gap.id {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("读取上下文…"))
                    Button(L10n.text("取消展开")) { onCancel() }
                } else if expansion.hasMore {
                    let remaining = gap.count.map { $0 - expansion.consumed }
                    Button(
                        gap.expandsUpward
                            ? L10n.count("向上展开 %lld 行", min(20, remaining ?? 20))
                            : L10n.count("展开 %lld 行", min(20, remaining ?? 20))
                    ) {
                        onExpand()
                    }.accessibilityIdentifier("diff-context-expand-\(gap.id)")
                        .disabled(expandingGap != nil)
                    Text(remaining.map { L10n.count("%lld 行未显示", $0) } ?? L10n.text("后续上下文")).foregroundStyle(
                        colors.secondaryText)
                } else {
                    Text(gap.count == nil ? L10n.text("已到文件结尾") : L10n.text("此范围已完整展开")).foregroundStyle(
                        colors.secondaryText)
                }
                Spacer()
                if !expansion.lines.isEmpty {
                    Button(L10n.text("折叠上下文")) { onCollapse() }
                        .accessibilityIdentifier("diff-context-collapse-\(gap.id)")
                }
            }
            if let error = expansion.error { Text(error).foregroundStyle(colors.secondaryText) }
        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
            .background(colors.chrome)
            .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("上下文展开控制"))
    }
}
