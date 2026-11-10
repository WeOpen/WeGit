import AppKit
import SwiftUI
import WeGitCore

struct IgnoreRuleRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let path: String
}

struct IgnoreRuleSheet: View {
    let app: AppState
    let request: IgnoreRuleRequest
    @Environment(\.themeColors) private var colors
    @State private var kind = IgnoreRuleKind.file
    @State private var scope = IgnoreRuleScope.repository
    @State private var plan: IgnoreRulePlan?
    @State private var outcome: IgnoreRuleOutcome?
    @State private var error: String?
    @State private var details: String?
    @State private var retainedInput: URL?
    @State private var preparing = true
    @State private var attempted = false
    @State private var undoAttempted = false
    private var current: Bool { app.session === request.session && app.ignoreRuleRequest?.id == request.id }
    private var kinds: [IgnoreRuleKind] {
        [.file] + (request.path.contains("/") ? [.directory] : [])
            + ((request.path as NSString).pathExtension.isEmpty ? [] : [.fileExtension])
    }
    var body: some View {
        @Bindable var session = request.session
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle(title: L10n.text("忽略文件"), symbol: "eye.slash")
            Text(request.path).font(.callout.monospaced()).textSelection(.enabled).lineLimit(3).help(
                request.path)
            Picker(L10n.text("匹配范围"), selection: $kind) {
                ForEach(kinds, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(attempted).accessibilityIdentifier("ignore-rule-kind")
            Picker(L10n.text("保存位置"), selection: $scope) {
                ForEach(IgnoreRuleScope.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(attempted).accessibilityIdentifier("ignore-rule-scope")
            if let plan {
                Text(plan.pattern).font(.callout.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("ignore-rule-pattern")
                Divider()
                HStack {
                    Text(L10n.text("匹配的未跟踪文件"))
                    Spacer()
                    Text(String(plan.matchedPaths.count)).monospacedDigit()
                }.font(.subheadline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.matchedPaths, id: \.self) { path in
                            Text(path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).help(
                                path)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier(
                    "ignore-rule-matches")
            } else if preparing {
                ProgressView(L10n.text("准备忽略规则…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if let details, !details.isEmpty {
                DisclosureGroup(L10n.text("查看脱敏详情")) {
                    ScrollView {
                        Text(details).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }.font(.caption)
            }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel,
                    result: session.operationFeedback, context: .standard, fallback: "")
            }
            HStack {
                if let outcome, !undoAttempted {
                    Button(L10n.text("撤销")) { undo(outcome) }.disabled(session.isBusy || !session.canWrite)
                        .accessibilityIdentifier("ignore-rule-undo")
                }
                if let retainedInput {
                    Button(L10n.text("在 Finder 中检查")) {
                        NSWorkspace.shared.activateFileViewerSelecting([retainedInput])
                    }
                }
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : attempted ? L10n.text("关闭") : L10n.text("取消")) {
                    if session.isBusy { session.cancel() } else { close() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("ignore-rule-cancel")
                if !attempted {
                    Button(L10n.text("保存规则")) { execute() }.workbenchPrimaryAction()
                        .keyboardShortcut(.defaultAction).disabled(
                            preparing || plan == nil || !session.canWrite || session.isBusy
                        )
                        .accessibilityIdentifier("ignore-rule-execute")
                }
            }
        }.padding(24).frame(width: 600, height: 510).interactiveDismissDisabled(session.isBusy)
            .task(id: kind.rawValue + ":" + scope.rawValue) { await prepare() }
    }
    private func prepare() async {
        guard current, !attempted else { return }
        preparing = true
        plan = nil
        error = nil
        details = nil
        let requested = (kind, scope)
        do {
            let value = try await request.session.service.prepareIgnoreRule(
                path: request.path, kind: kind, scope: scope)
            guard !Task.isCancelled, current, requested.0 == kind, requested.1 == scope else { return }
            plan = value
        } catch {
            guard !Task.isCancelled, current, requested.0 == kind, requested.1 == scope else { return }
            self.error = error.localizedDescription
            details = (error as? GitFailure).map { String(Redaction.text($0.details).prefix(8192)) }
        }
        preparing = false
    }
    private func execute() {
        guard current, let plan, !attempted, request.session.canWrite, !request.session.isBusy else { return }
        attempted = true
        request.session.performResult(L10n.text("保存忽略规则")) { service in
            do {
                let value = try await service.executeIgnoreRule(plan)
                await MainActor.run { if current { outcome = value } }
                return .completed(message: L10n.text("忽略规则已保存。"))
            } catch let unknown as IgnoreWriteOutcomeUnknown {
                await MainActor.run { if current { retainedInput = unknown.retainedInput } }
                return .needsReview(message: unknown.localizedDescription)
            } catch let unknown as RecoveryOutcomeUnknown {
                return .needsReview(message: unknown.localizedDescription)
            }
        }
    }
    private func undo(_ outcome: IgnoreRuleOutcome) {
        guard current, !undoAttempted, request.session.canWrite, !request.session.isBusy else { return }
        undoAttempted = true
        request.session.performResult(L10n.text("撤销忽略规则")) { service in
            try await service.undoIgnoreRule(outcome)
            return .completed(message: L10n.text("忽略规则已撤销。"))
        }
    }
    private func close() {
        guard app.ignoreRuleRequest?.id == request.id else { return }
        app.ignoreRuleRequest = nil
    }
}
