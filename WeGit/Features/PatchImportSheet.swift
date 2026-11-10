import SwiftUI
import WeGitCore

struct PatchImportRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let sourceName: String
    let patch: Data
}

struct PatchImportSheet: View {
    let app: AppState
    let request: PatchImportRequest
    @Environment(\.themeColors) private var colors
    @State private var layer = RecoveryLayer.worktree
    @State private var plan: PatchPlan?
    @State private var error: String?
    @State private var loading = true
    @State private var attempted = false
    private var current: Bool { app.session === request.session && app.patchImportRequest?.id == request.id }
    var body: some View {
        @Bindable var session = request.session
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle(title: L10n.text("应用文件补丁"), symbol: "doc.badge.plus")
            HStack {
                Text(request.sourceName).lineLimit(2).help(request.sourceName)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(request.patch.count), countStyle: .file))
                    .foregroundStyle(colors.secondaryText)
            }
            Picker(L10n.text("应用到"), selection: $layer) {
                ForEach(RecoveryLayer.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(attempted).accessibilityIdentifier("patch-target")
            if loading {
                ProgressView(L10n.text("预检查补丁…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(plan.files) { file in
                            HStack {
                                Text(file.oldPath.map { $0 + " → " + file.path } ?? file.path)
                                    .font(.callout.monospaced()).lineLimit(3).textSelection(.enabled).help(
                                        file.path)
                                Spacer()
                                Text(
                                    file.binary
                                        ? L10n.text("二进制") : "+\(file.additions ?? 0) −\(file.deletions ?? 0)"
                                )
                                .font(.caption).foregroundStyle(colors.secondaryText)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("patch-files")
            } else {
                Spacer()
            }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel,
                    result: session.operationFeedback, context: .standard, fallback: "")
            }
            HStack {
                if attempted, !session.isBusy {
                    Button(L10n.text("查看恢复记录")) {
                        app.pendingRecoveryAfterPatch = RecoveryBrowserRequest(
                            session: session, initialTab: 1)
                        close()
                    }.accessibilityIdentifier("patch-show-recovery")
                }
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : attempted ? L10n.text("关闭") : L10n.text("取消")) {
                    if session.isBusy { session.cancel() } else { close() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("patch-cancel")
                if !attempted {
                    Button(L10n.text("应用补丁")) { execute() }.workbenchPrimaryAction()
                        .keyboardShortcut(.defaultAction).disabled(
                            loading || plan == nil || !session.canWrite || session.isBusy
                        )
                        .accessibilityIdentifier("patch-execute")
                }
            }
        }.padding(24).frame(width: 650, height: 510).interactiveDismissDisabled(session.isBusy)
            .task(id: layer) { await prepare() }
    }
    private func prepare() async {
        guard current, !attempted else { return }
        loading = true
        plan = nil
        error = nil
        let requested = layer
        do {
            let value = try await request.session.service.preparePatch(request.patch, layer: requested)
            guard !Task.isCancelled, current, requested == layer else { return }
            plan = value
        } catch {
            guard !Task.isCancelled, current, requested == layer else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
    private func execute() {
        guard current, let plan, !attempted, request.session.canWrite, !request.session.isBusy else { return }
        attempted = true
        request.session.performResult(L10n.text("应用补丁")) { service in
            do {
                _ = try await service.executePatch(plan)
                return .completed(message: L10n.text("文件补丁已应用，原始内容已备份。"))
            } catch let unknown as RecoveryOutcomeUnknown {
                return .needsReview(message: unknown.localizedDescription)
            }
        }
    }
    private func close() {
        guard app.patchImportRequest?.id == request.id else { return }
        app.patchImportRequest = nil
    }
}
