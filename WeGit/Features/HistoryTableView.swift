import SwiftUI
import WeGitCore

struct HistoryTableView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    let session: RepositorySession
    @Bindable var history: HistoryState

    private var selection: Binding<String?> {
        Binding(
            get: { app.workspace.selectedCommit?.id },
            set: { id in
                app.workspace.selectedCommit = history.commits.first { $0.id == id }
            })
    }

    var body: some View {
        GeometryReader { geometry in
            let referencesVisible = geometry.size.width >= 560
            let authorVisible = geometry.size.width >= 460
            let dateVisible = geometry.size.width >= 700
            Table(history.tableRows, selection: selection) {
                if history.anchor?.query.isEmpty == true {
                    TableColumn(L10n.text("图")) { row in
                        HistoryGraphCell(
                            row: row.graph, head: history.anchor?.head == row.id,
                            shallow: row.commit.shallowBoundary
                        )
                        .frame(minHeight: app.preferences.density == "compact" ? 28 : 42)
                        .padding(.vertical, -4)
                    }.width(min: 36, ideal: max(48, min(CGFloat(history.graphWidth) * 12, 160)), max: 800)
                }
                TableColumn(L10n.text("提交")) { row in
                    messageCell(
                        row.commit, referencesVisible: referencesVisible, authorVisible: authorVisible,
                        dateVisible: dateVisible)
                }.width(min: 160, ideal: 300, max: 1200)
                if referencesVisible {
                    TableColumn(L10n.text("引用")) { row in
                        let references = history.references[row.id] ?? []
                        HStack(spacing: 4) {
                            ForEach(Array(references.prefix(2).enumerated()), id: \.offset) {
                                index, reference in
                                ReferenceBadge(
                                    name: reference.name,
                                    selected: app.workspace.selectedCommit?.id == row.id,
                                    tone: reference.kind.badgeTone
                                ).layoutPriority(index == 0 ? 1 : 0)
                            }
                            if references.count > 2 {
                                Text("+\(references.count - 2)").font(.caption2)
                                    .foregroundStyle(colors.secondaryText)
                                    .fixedSize()
                            }
                        }.help(references.map(\.name).joined(separator: " · "))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                references.isEmpty
                                    ? "" : L10n.text("引用：") + references.map(\.name).joined(separator: " · "))
                    }.width(min: 75, ideal: 120, max: 400)
                }
                if authorVisible {
                    TableColumn(L10n.text("作者")) { row in
                        Text(row.commit.author).font(.caption).lineLimit(1).help(row.commit.authorEmail)
                    }
                    .width(min: 70, ideal: 100, max: 300)
                }
                if dateVisible {
                    TableColumn(L10n.text("日期")) { row in
                        Text(row.commit.date, format: .dateTime.year().month().day()).font(.caption)
                            .help(
                                row.commit.date.formatted(
                                    Date.FormatStyle(date: .complete, time: .complete).locale(L10n.locale)))
                    }.width(min: 85, ideal: 110, max: 180)
                }
            }.tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden).background(colors.canvas)
                .accessibilityIdentifier("history-list").accessibilityLabel(L10n.text("提交历史列表"))
                .help(L10n.text("拖动列边界调整宽度；窄窗口会把引用、作者与日期并入提交列"))
        }
        .background(
            ViewPerformanceProbe(spans: [ViewPerformanceSpan(name: "history", id: history.firstRenderID)]))
    }

    private func messageCell(
        _ commit: GitCommit, referencesVisible: Bool, authorVisible: Bool, dateVisible: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commit.subject).font(.system(size: 13, weight: .medium)).lineLimit(1).help(commit.subject)
            if !referencesVisible, let refs = history.references[commit.id], !refs.isEmpty {
                Text(refs.map(\.name).joined(separator: " · ")).font(.caption2)
                    .foregroundStyle(
                        app.workspace.selectedCommit?.id == commit.id ? colors.text : colors.link
                    )
                    .lineLimit(1)
            }
            HStack(spacing: 7) {
                if !authorVisible { Text(commit.author).lineLimit(1) }
                Text(commit.id.prefix(7)).monospaced().padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.primary.opacity(0.045), in: .rect(cornerRadius: 3))
                if !dateVisible { Text(commit.date, style: .relative).lineLimit(1) }
            }.font(.caption2)
                .foregroundStyle(
                    app.workspace.selectedCommit?.id == commit.id ? colors.text : colors.secondaryText)
            if commit.shallowBoundary {
                Text(L10n.text("浅克隆边界")).font(.caption2).foregroundStyle(colors.secondaryText)
            }
        }.padding(.vertical, app.preferences.density == "compact" ? 1 : 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(commit.subject)
            .accessibilityValue(
                L10n.text("提交 \(commit.id.prefix(12))，作者 \(commit.author)，\(commit.parents.count) 个父提交"))
    }
}

private struct HistoryGraphCell: View {
    @Environment(\.themeColors) private var colors
    let row: GraphRow
    let head: Bool
    let shallow: Bool
    var body: some View {
        Canvas { context, size in
            let laneColors: [Color] = [
                colors.link, colors.keyword, colors.positive, colors.modified, colors.negative,
            ]
            for column in row.incomingColumns {
                var path = Path()
                path.move(to: CGPoint(x: CGFloat(column) * 12 + 6, y: 0))
                path.addLine(to: CGPoint(x: CGFloat(column) * 12 + 6, y: size.height / 2))
                context.stroke(path, with: .color(laneColors[column % laneColors.count]), lineWidth: 1.5)
            }
            for (from, to) in row.connections {
                var path = Path()
                path.move(to: CGPoint(x: CGFloat(from) * 12 + 6, y: size.height / 2))
                path.addCurve(
                    to: CGPoint(x: CGFloat(to) * 12 + 6, y: size.height),
                    control1: CGPoint(x: CGFloat(from) * 12 + 6, y: size.height * 0.8),
                    control2: CGPoint(x: CGFloat(to) * 12 + 6, y: size.height * 0.8))
                context.stroke(
                    path, with: .color(laneColors[from % laneColors.count]),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: CGFloat(row.column) * 12 + 2, y: size.height / 2 - 4, width: 8, height: 8)),
                with: .color(laneColors[row.column % laneColors.count]))
            if head || shallow {
                let ring = Path(
                    ellipseIn: CGRect(
                        x: CGFloat(row.column) * 12, y: size.height / 2 - 6, width: 12, height: 12))
                context.stroke(
                    ring, with: .color(head ? colors.accent : Color.primary),
                    style: StrokeStyle(lineWidth: head ? 1.5 : 1, dash: shallow ? [2, 2] : []))
            }
        }.accessibilityAddTraits(.isImage).accessibilityLabel(
            shallow
                ? L10n.text("浅克隆边界")
                : head ? L10n.text("HEAD，分支列 \(row.column + 1)") : L10n.text("提交图，分支列 \(row.column + 1)"))
    }
}

extension GitReference.Kind {
    fileprivate var badgeTone: InterfaceTone {
        switch self {
        case .localBranch: .blue
        case .remoteBranch: .teal
        case .tag: .violet
        case .head: .green
        }
    }
}
