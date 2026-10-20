import SwiftUI
import WeGitCore

/// Right-edge overview of every hunk's position in the new file. Tapping a tick
/// routes through the same `navigate(to:)` path as the previous/next controls.
struct DiffChangeMap: View {
    @Environment(\.themeColors) private var colors
    let hunks: [DiffHunk]
    let current: Int?
    let navigate: (Int) -> Void

    struct Tick {
        let id: Int
        let offset: CGFloat
        let extent: CGFloat

        func range(height: CGFloat) -> ClosedRange<CGFloat> {
            let start = offset * height
            return start...(start + max(extent * height, 2))
        }
    }

    static func target(at position: CGFloat, height: CGFloat, ticks: [Tick]) -> Int? {
        guard height > 0 else { return nil }
        // Canvas draws later ticks on top. Match that order when marks overlap.
        if let hit = ticks.last(where: { $0.range(height: height).contains(position) }) {
            return hit.id
        }
        func distance(_ tick: Tick) -> CGFloat {
            let range = tick.range(height: height)
            return max(range.lowerBound - position, position - range.upperBound)
        }
        return ticks.min { distance($0) < distance($1) }?.id
    }

    private var ticks: [Tick] { Self.ticks(for: hunks) }

    static func ticks(for hunks: [DiffHunk]) -> [Tick] {
        let placed = hunks.compactMap { hunk -> (id: Int, start: Int, count: Int)? in
            guard let range = newFileRange(hunk) else { return nil }
            return (hunk.id, range.start, range.count)
        }
        let total = CGFloat(max(placed.map { $0.start + $0.count }.max() ?? 1, 1))
        return placed.map { tick in
            Tick(
                id: tick.id,
                offset: CGFloat(max(tick.count == 0 ? tick.start : tick.start - 1, 0)) / total,
                extent: max(CGFloat(tick.count) / total, 0.015))
        }
    }

    private static func newFileRange(_ hunk: DiffHunk) -> (start: Int, count: Int)? {
        for token in hunk.header.split(separator: " ") where token.hasPrefix("+") {
            let parts = token.dropFirst().split(separator: ",")
            guard let start = Int(parts.first ?? ""), start >= 0, parts.count <= 2,
                let count = parts.count > 1 ? Int(parts[1]) : 1,
                count >= 0, start > 0 || count == 0
            else { return nil }
            return (start, count)
        }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for tick in ticks {
                    let range = tick.range(height: size.height)
                    let rect = CGRect(
                        x: (size.width - 5) / 2, y: range.lowerBound,
                        width: 5, height: range.upperBound - range.lowerBound)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 2),
                        with: .color(colors.accent.opacity(tick.id == current ? 1 : 0.45)))
                }
            }.contentShape(.rect)
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        if let target = Self.target(
                            at: value.location.y, height: geometry.size.height, ticks: ticks)
                        {
                            navigate(target)
                        }
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
