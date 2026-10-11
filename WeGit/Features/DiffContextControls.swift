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
                    Text("读取上下文…")
                    Button("取消展开") { onCancel() }
                } else if expansion.hasMore {
                    let remaining = gap.count.map { $0 - expansion.consumed }
                    Button(
                        gap.expandsUpward
                            ? "向上展开 \(min(20, remaining ?? 20)) 行" : "展开 \(min(20, remaining ?? 20)) 行"
                    ) {
                        onExpand()
                    }.accessibilityIdentifier("diff-context-expand-\(gap.id)")
                        .disabled(expandingGap != nil)
                    Text(remaining.map { "\($0) 行未显示" } ?? "后续上下文").foregroundStyle(AppColors.secondaryText)
                } else {
                    Text(gap.count == nil ? "已到文件结尾" : "此范围已完整展开").foregroundStyle(AppColors.secondaryText)
                }
                Spacer()
                if !expansion.lines.isEmpty {
                    Button("折叠上下文") { onCollapse() }
                        .accessibilityIdentifier("diff-context-collapse-\(gap.id)")
                }
            }
            if let error = expansion.error { Text(error).foregroundStyle(AppColors.secondaryText) }
        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
            .background(.quaternary.opacity(0.2))
            .accessibilityElement(children: .contain).accessibilityLabel("上下文展开控制")
    }
}
