import SwiftUI
import WeGitCore

struct ResetRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let target: String
}

struct RecoveryBrowserRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
}

struct ResetSheet: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let app: AppState
    let request: ResetRequest
    @State private var mode: ResetMode = .soft
    @State private var plan: ResetPlan?
    @State private var preparing = true
    @State private var error: String?
    @State private var approved = false
    @State private var attempted = false

    var body: some View {
        @Bindable var session = request.session
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: "Reset", symbol: "arrow.uturn.backward")
            Picker("Reset", selection: $mode) {
                ForEach(ResetMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(attempted).accessibilityIdentifier("reset-mode")
            Text(mode.impact).foregroundStyle(colors.secondaryText)
            if let plan {
                RecoveryContext(label: L10n.text("当前分支"), value: plan.branch, identifier: "reset-branch")
                RecoveryContext(label: "HEAD", value: plan.head, identifier: "reset-head")
                RecoveryContext(label: L10n.text("目标提交"), value: plan.target.id, identifier: "reset-target")
                Text(plan.target.subject).font(.headline).lineLimit(3)
                if !plan.publishedTrackingRefs.isEmpty {
                    Label(
                        L10n.text("当前提交在本地远端跟踪引用中可达；Reset 不会改变远端。"), systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(colors.modified)
                }
                Divider()
                HStack {
                    Text(L10n.text("受影响的文件")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(String(plan.files.count)).monospacedDigit()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.files, id: \.self) {
                            Text($0).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160).accessibilityIdentifier("reset-files")
                Text(
                    L10n.text(
                        "备份大小：\(ByteCountFormatter.string(fromByteCount: Int64(plan.backupBytes), countStyle: .file))"
                    )
                )
                .font(.caption).foregroundStyle(colors.secondaryText)
                if mode == .hard {
                    Toggle(L10n.text("备份完整后替换工作文件"), isOn: $approved)
                        .accessibilityIdentifier("reset-hard-confirm")
                }
            }
            if preparing { ProgressView(L10n.text("准备 Reset…")) }
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
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("reset-cancel")
                if !attempted {
                    Button("Reset", role: mode == .hard ? .destructive : nil) { execute() }
                        .workbenchPrimaryAction().keyboardShortcut(.defaultAction)
                        .disabled(preparing || plan == nil || !session.canWrite || mode == .hard && !approved)
                        .accessibilityIdentifier("reset-execute")
                }
            }
        }.padding(24).frame(width: 600).interactiveDismissDisabled(session.isBusy)
            .task(id: mode) { await prepare() }
            .onChange(of: app.session?.id) { _, _ in if app.session !== session { dismiss() } }
    }

    private func prepare() async {
        plan = nil
        error = nil
        preparing = true
        approved = false
        let requested = mode
        do {
            let value = try await request.session.service.prepareReset(
                target: request.target, mode: requested)
            guard !Task.isCancelled, mode == requested else { return }
            plan = value
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        preparing = false
    }
    private func execute() {
        guard let plan, !attempted, app.session === request.session else { return }
        attempted = true
        request.session.performResult("Reset", onSuccess: { dismiss() }) {
            _ = try await $0.executeReset(plan)
            return .completed(message: L10n.text("Reset 完成，原 HEAD 和内容已备份。"))
        }
    }
}

private struct RecoveryRestoreRequest: Identifiable {
    let id = UUID()
    let record: RecoveryRecord
}

struct RecoveryBrowser: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let app: AppState
    let request: RecoveryBrowserRequest
    @State private var tab = 0
    @State private var ref = "HEAD"
    @State private var entries: [ReflogEntry] = []
    @State private var records: [RecoveryRecord] = []
    @State private var selectedObject: String?
    @State private var selectedRecord: RecoveryRecord?
    @State private var branch = "recovery-" + String(UUID().uuidString.prefix(8)).lowercased()
    @State private var switchAfterCreation = false
    @State private var loading = false
    @State private var error: String?
    @State private var offset = 0
    @State private var more = false
    @State private var revision = UUID()
    @State private var restore: RecoveryRestoreRequest?

    var body: some View {
        @Bindable var session = request.session
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle(title: L10n.text("恢复"), symbol: "clock.arrow.circlepath")
            Picker(L10n.text("恢复来源"), selection: $tab) {
                Text("Reflog").tag(0)
                Text(L10n.text("内容备份")).tag(1)
            }.pickerStyle(.segmented).accessibilityIdentifier("recovery-source")
            if tab == 0 {
                Picker(L10n.text("引用"), selection: $ref) {
                    Text("HEAD").tag("HEAD")
                    ForEach(session.branches.filter { !$0.remote }.prefix(500)) { Text($0.name).tag($0.id) }
                }.accessibilityIdentifier("reflog-ref")
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(entries) { entry in
                            Button {
                                selectedObject = entry.objectExists ? entry.object : nil
                            } label: {
                                HStack(spacing: 12) {
                                    Text(entry.date?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                                        .frame(width: 140, alignment: .leading)
                                    Text(String(entry.object.prefix(12))).font(.callout.monospaced()).frame(
                                        width: 100, alignment: .leading)
                                    Text(entry.message).lineLimit(2).frame(
                                        maxWidth: .infinity, alignment: .leading)
                                    if !entry.objectExists {
                                        Text(L10n.text("对象已失效")).foregroundStyle(colors.secondaryText)
                                    }
                                }.padding(8).contentShape(Rectangle())
                                    .background(
                                        selectedObject == entry.object
                                            ? colors.selectionBackground : colors.surface)
                            }.buttonStyle(.plain).disabled(!entry.objectExists).accessibilityIdentifier(
                                "reflog:" + entry.id)
                        }
                    }
                }.accessibilityIdentifier("reflog-list")
                if more {
                    Button(L10n.text("加载更多")) {
                        offset = entries.count
                        revision = UUID()
                    }.disabled(loading || offset >= 900)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(records) { record in
                            Button {
                                selectedRecord = record
                                selectedObject = record.head
                            } label: {
                                HStack {
                                    Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    Text(record.operation).font(.callout.monospaced())
                                    Spacer()
                                    Text(
                                        ByteCountFormatter.string(
                                            fromByteCount: Int64(record.totalBytes), countStyle: .file))
                                    Text(
                                        record.state == .needsVerification
                                            ? L10n.text("待核对")
                                            : record.state == .prepared
                                                ? L10n.text("未执行")
                                                : record.state == .restored
                                                    ? L10n.text("已恢复") : L10n.text("已完成"))
                                }.padding(10).contentShape(Rectangle())
                                    .background(
                                        selectedRecord?.id == record.id
                                            ? colors.selectionBackground : colors.surface)
                            }.buttonStyle(.plain).accessibilityIdentifier(
                                "recovery-record:" + record.id.uuidString)
                        }
                    }
                }.accessibilityIdentifier("recovery-records")
                if let record = selectedRecord {
                    RecoveryContext(
                        label: L10n.text("原 HEAD"), value: record.head ?? "—",
                        identifier: "recovery-original-head")
                    HStack {
                        Button(L10n.text("恢复内容…")) { restore = RecoveryRestoreRequest(record: record) }
                            .disabled(!session.canWrite).accessibilityIdentifier("recovery-restore")
                        Spacer()
                        Button(L10n.text("删除备份…"), role: .destructive) { delete(record) }.disabled(
                            !session.canWrite)
                    }
                }
            }
            if let selectedObject {
                Divider()
                RecoveryContext(
                    label: L10n.text("恢复提交"), value: selectedObject, identifier: "recovery-object")
                HStack {
                    TextField(L10n.text("恢复分支名称"), text: $branch).textFieldStyle(.roundedBorder)
                    Toggle(L10n.text("创建后切换"), isOn: $switchAfterCreation)
                    Button(L10n.text("创建恢复分支")) { createBranch(selectedObject) }
                        .disabled(!session.canWrite || branch.isEmpty).accessibilityIdentifier(
                            "recovery-create-branch")
                }
            }
            if loading { ProgressView(L10n.text("读取恢复记录…")) }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            OperationFeedback(
                busy: session.isBusy, activity: session.activityLabel,
                result: session.operationFeedback, context: .standard, fallback: "")
            HStack {
                Button(L10n.text("刷新")) {
                    offset = 0
                    revision = UUID()
                }.disabled(loading)
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : L10n.text("关闭")) {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("recovery-close")
            }
        }.padding(24).frame(width: 820, height: 620).interactiveDismissDisabled(session.isBusy)
            .task(id: "\(revision):\(ref):\(tab)") { await load() }
            .sheet(item: $restore, onDismiss: { revision = UUID() }) { value in
                RecoveryRestoreSheet(app: app, session: session, record: value.record).workbenchSheet(
                    app.preferences)
            }
            .onChange(of: ref) { _, _ in
                offset = 0
                entries = []
                selectedObject = nil
            }
            .onChange(of: tab) { _, _ in
                offset = 0
                selectedObject = nil
                selectedRecord = nil
            }
            .onChange(of: app.session?.id) { _, _ in if app.session !== session { dismiss() } }
    }
    private func load() async {
        loading = true
        error = nil
        do {
            if tab == 0 {
                let page = try await request.session.service.reflog(ref: ref, offset: offset)
                guard !Task.isCancelled else { return }
                if offset == 0 { entries = page } else { entries += page }
                more = page.count == 100
            } else {
                let values = try await request.session.service.recoveryRecords()
                guard !Task.isCancelled else { return }
                records = values
                if let selectedRecord { self.selectedRecord = values.first { $0.id == selectedRecord.id } }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
    private func createBranch(_ oid: String) {
        let name = branch
        let head = request.session.status.head
        let switchTo = switchAfterCreation
        request.session.perform(L10n.text("创建恢复分支"), onSuccess: { revision = UUID() }) {
            try await $0.createBranch(name, start: oid, switchTo: switchTo, expectedHead: head)
        }
    }
    private func delete(_ record: RecoveryRecord) {
        guard
            app.confirm(
                title: L10n.text("删除这份内容备份？"),
                message: L10n.text("删除后，未提交内容无法再从这份备份恢复。Git 提交和 Reflog 不受影响。"),
                action: L10n.text("删除备份"), destructive: true)
        else { return }
        request.session.perform(
            L10n.text("删除备份"),
            onSuccess: {
                selectedRecord = nil
                revision = UUID()
            }
        ) {
            try await $0.removeRecoveryRecord(record)
        }
    }
}

private struct RecoveryRestoreSheet: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let app: AppState
    let session: RepositorySession
    let record: RecoveryRecord
    @State private var layer: RecoveryLayer = .worktree
    @State private var plan: RecoveryRestorePlan?
    @State private var error: String?
    @State private var loading = false
    @State private var attempted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("恢复内容"), symbol: "arrow.counterclockwise")
            Picker(L10n.text("恢复到"), selection: $layer) {
                ForEach(RecoveryLayer.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(attempted).accessibilityIdentifier("recovery-layer")
            RecoveryContext(
                label: L10n.text("原 HEAD"), value: record.head ?? "—", identifier: "restore-source")
            RecoveryContext(
                label: L10n.text("当前 HEAD"), value: plan?.currentHead ?? "—", identifier: "restore-head")
            Text(L10n.text("当前内容会先备份；恢复不会移动 HEAD。")).foregroundStyle(colors.secondaryText)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(record.files) {
                        Text($0.path).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 220)
            if loading { ProgressView(L10n.text("核对备份…")) }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            if attempted {
                OperationFeedback(
                    busy: session.isBusy, activity: session.activityLabel,
                    result: session.operationFeedback, context: .standard, fallback: "")
            }
            HStack {
                Spacer()
                Button(session.isBusy ? L10n.text("取消操作") : L10n.text("取消")) {
                    if session.isBusy { session.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                if !attempted {
                    Button(L10n.text("恢复")) { execute() }.workbenchPrimaryAction().keyboardShortcut(
                        .defaultAction
                    )
                    .disabled(
                        plan == nil || loading || !session.canWrite
                            || layer == .worktree && record.files.isEmpty
                    )
                    .accessibilityIdentifier("recovery-execute")
                }
            }
        }.padding(24).frame(width: 620).interactiveDismissDisabled(session.isBusy)
            .task(id: layer) {
                loading = true
                plan = nil
                error = nil
                do {
                    let value = try await session.service.prepareRecoveryRestore(record, layer: layer)
                    guard !Task.isCancelled else { return }
                    plan = value
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                }
                loading = false
            }
    }
    private func execute() {
        guard let plan, !attempted else { return }
        attempted = true
        session.performResult(L10n.text("恢复内容"), onSuccess: { dismiss() }) {
            _ = try await $0.executeRecoveryRestore(plan)
            return .completed(message: L10n.text("内容已恢复，HEAD 保持不变。"))
        }
    }
}

private struct RecoveryContext: View {
    @Environment(\.themeColors) private var colors
    let label: String
    let value: String
    let identifier: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(colors.secondaryText).frame(width: 110, alignment: .leading)
            Text(value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
            Spacer(minLength: 0)
        }.accessibilityElement(children: .ignore).accessibilityLabel(label + ": " + value)
            .accessibilityIdentifier(identifier)
    }
}
