import SwiftUI

struct DiffNavigationControls: View {
    let count: Int
    let current: Int?
    let loading: Bool
    let navigate: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("上一差异块", systemImage: "chevron.up") { navigate((current ?? 0) - 1) }
                .disabled(loading || (current ?? 0) <= 0).accessibilityIdentifier("diff-hunk-previous")
            Button("下一差异块", systemImage: "chevron.down") { navigate(current.map { $0 + 1 } ?? 0) }
                .disabled(loading || current.map { $0 + 1 >= count } ?? (count == 0))
                .accessibilityIdentifier("diff-hunk-next")
            Spacer()
            Text("差异块 \(current.map { $0 + 1 } ?? 0) / \(count)")
                .monospacedDigit().accessibilityIdentifier("diff-hunk-position")
        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 7).background(.bar)
    }
}
