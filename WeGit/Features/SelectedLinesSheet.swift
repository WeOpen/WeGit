import SwiftUI
import WeGitCore

private struct SelectedLinesRequest: Identifiable {
    let id = UUID()
    let diff: FileDiff
    let lineIDs: Set<Int>
}

struct SelectedLinesControl: View {
    let app: AppState
    let session: RepositorySession
    let display: DiffDisplayState
    @State private var request: SelectedLinesRequest?

    var body: some View {
        let diff = display.diff
        let ids = display.selection.selectedLineIDs(includeContext: diff.layer == .untracked)
        if diff.canSelectLines, app.workspace.diffOptions == diff.options {
            HStack {
                Spacer()
                Button(diff.layer == .staged ? L10n.text("取消暂存所选行…") : L10n.text("暂存所选行…")) {
                    guard app.session === session else { return }
                    request = SelectedLinesRequest(diff: diff, lineIDs: ids)
                }.disabled(ids.isEmpty || !session.canWrite || session.isBusy)
                    .accessibilityIdentifier("diff-selected-lines-preview")
            }.padding(.horizontal, 12).padding(.vertical, 6)
                .sheet(item: $request) { value in
                    SelectedLinesSheet(app: app, session: session, request: value)
                        .workbenchSheet(app.preferences)
                }
        }
    }
}

private struct SelectedLinesSheet: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let app: AppState
    let session: RepositorySession
    let request: SelectedLinesRequest
    @State private var plan: SelectedLinesPlan?
    @State private var error: String?
    @State private var preparing = true
    @State private var attempted = false
    private var title: String {
        request.diff.layer == .staged ? L10n.text("取消暂存所选行") : L10n.text("暂存所选行")
    }

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle(title: title, symbol: "line.3.horizontal.decrease.circle")
            Text(request.diff.path).font(.callout.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("selected-lines-path")
            if preparing {
                ProgressView(L10n.text("预览所选行…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan {
                ScrollView([.vertical, .horizontal]) {
                    Text(preview(plan)).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("selected-lines-changes")
            }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel,
                    result: session.operationFeedback, context: .standard, fallback: "")
            }
            HStack {
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : attempted ? L10n.text("关闭") : L10n.text("取消")) {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("selected-lines-cancel")
                if !attempted {
                    Button(title) { execute() }.keyboardShortcut(.defaultAction)
                        .disabled(preparing || plan == nil || !session.canWrite)
                        .accessibilityIdentifier("selected-lines-execute")
                }
            }.workbenchControlFamily()
        }.padding(24).frame(width: 620, height: 470).interactiveDismissDisabled(session.isBusy)
            .task { await prepare() }
            .onChange(of: app.session?.id) { _, _ in if app.session !== session { dismiss() } }
    }

    private func prepare() async {
        guard app.session === session else { return }
        do {
            let result = try await session.service.prepareSelectedLines(
                diff: request.diff, lineIDs: request.lineIDs)
            guard !Task.isCancelled, app.session === session else { return }
            guard result.patch.count <= 64 * 1024 else {
                throw ModelFailure.unsupported(L10n.text("所选行预览过大，请缩小选择范围。"))
            }
            plan = result
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        preparing = false
    }

    private func execute() {
        guard app.session === session, let plan, !attempted else { return }
        attempted = true
        session.performResult(
            title, onSuccess: { dismiss() },
            operation: { service in
                do {
                    try await service.executeSelectedLines(plan)
                    return .completed(message: L10n.text("暂存区更新完成"))
                } catch let uncertain as SelectedLinesOutcomeUnknown {
                    return .needsReview(message: uncertain.localizedDescription)
                }
            })
    }

    /// The preview describes the actual index direction; reversing a staged
    /// patch reverses the visible +/- markers while preserving context bytes.
    private func preview(_ plan: SelectedLinesPlan) -> String {
        var inHunk = false
        var output: [String] = []
        for row in String(decoding: plan.patch, as: UTF8.self).components(separatedBy: "\n") {
            if row.hasPrefix("@@ ") {
                inHunk = true
                continue
            }
            guard inHunk, !row.isEmpty else { continue }
            if plan.layer == .staged, row.first == "+" || row.first == "-" {
                output.append((row.first == "+" ? "-" : "+") + row.dropFirst())
            } else {
                output.append(row)
            }
        }
        return output.joined(separator: "\n")
    }
}
