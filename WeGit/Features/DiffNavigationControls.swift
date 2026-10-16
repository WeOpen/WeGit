import SwiftUI
import WeGitCore

struct DiffNavigationControls: View {
    @Environment(\.themeColors) private var colors
    let count: Int
    let current: Int?
    let loading: Bool
    let navigate: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(L10n.text("上一差异块"), systemImage: "chevron.up") { navigate((current ?? 0) - 1) }
                .workbenchIconButton()
                .disabled(loading || (current ?? 0) <= 0).accessibilityIdentifier("diff-hunk-previous")
            Button(L10n.text("下一差异块"), systemImage: "chevron.down") { navigate(current.map { $0 + 1 } ?? 0) }
                .workbenchIconButton()
                .disabled(loading || current.map { $0 + 1 >= count } ?? (count == 0))
                .accessibilityIdentifier("diff-hunk-next")
            Spacer()
            Text(L10n.text("差异块 \(current.map { $0 + 1 } ?? 0) / \(count)"))
                .monospacedDigit().accessibilityIdentifier("diff-hunk-position")
        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 7).background(colors.chrome)
    }
}
