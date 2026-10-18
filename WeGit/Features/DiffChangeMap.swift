import SwiftUI
import WeGitCore

/// Right-edge overview of every hunk's position in the new file. Tapping a tick
/// routes through the same `navigate(to:)` path as the previous/next controls.
struct DiffChangeMap: View {
    @Environment(\.themeColors) private var colors
    let hunks: [DiffHunk]
    let current: Int?
    let navigate: (Int) -> Void

    private struct Tick {
        let id: Int
        let offset: CGFloat
        let extent: CGFloat
    }

    private var ticks: [Tick] {
        let placed = hunks.compactMap { hunk -> (id: Int, start: Int, count: Int)? in
            guard let range = newFileRange(hunk) else { return nil }
            return (hunk.id, range.start, range.count)
        }
        let total = CGFloat(placed.map { $0.start + $0.count }.max() ?? 1)
        return placed.map { tick in
            Tick(
                id: tick.id,
                offset: CGFloat(max(tick.start - 1, 0)) / total,
                extent: max(CGFloat(tick.count) / total, 0.015))
        }
    }

    private func newFileRange(_ hunk: DiffHunk) -> (start: Int, count: Int)? {
        for token in hunk.header.split(separator: " ") where token.hasPrefix("+") {
            let parts = token.dropFirst().split(separator: ",")
            guard let start = Int(parts.first ?? ""), start > 0 else { return nil }
            return (start, parts.count > 1 ? Int(parts[1]) ?? 1 : 1)
        }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for tick in ticks {
                    let rect = CGRect(
                        x: (size.width - 5) / 2, y: tick.offset * size.height,
                        width: 5, height: max(tick.extent * size.height, 2))
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 2),
                        with: .color(colors.accent.opacity(tick.id == current ? 1 : 0.45)))
                }
            }.contentShape(.rect)
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        guard geometry.size.height > 0, !ticks.isEmpty else { return }
                        let fraction = value.location.y / geometry.size.height
                        let target = ticks.min { abs($0.offset - fraction) < abs($1.offset - fraction) }
                        if let target { navigate(target.id) }
                    }
                )
        }
        .frame(width: 14)
        .help(L10n.text("点击跳转到差异块"))
        .accessibilityElement()
        .accessibilityLabel(L10n.text("差异变更地图"))
        .accessibilityIdentifier("diff-change-map")
    }
}
