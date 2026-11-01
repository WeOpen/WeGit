import SwiftUI
import WeGitCore

enum StashPart: String, CaseIterable, Identifiable {
    case working, index, untracked
    var id: String { rawValue }
    var title: String {
        switch self {
        case .working: L10n.text("原未暂存内容")
        case .index: L10n.text("原暂存区内容")
        case .untracked: L10n.text("未跟踪内容")
        }
    }
}

private struct StashSaveRequest: Identifiable {
    let id = UUID()
    let status: RepositoryStatus
}

private struct StashActionRequest: Identifiable {
    enum Kind { case apply, pop, delete }
    let id = UUID()
    let kind: Kind
    let entry: GitStash
    let list: StashList
    let head: String?
    let branch: String
    let restoreIndex: Bool
}

/// The browser owns its selection/confirmation snapshot; the app adapter supplies
/// serialized session writes and the existing commit-file diff reader.
struct StashBrowser<Detail: View>: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.themeColors) private var colors
    let service: RepositoryService
    let status: RepositoryStatus
    let canWrite: Bool
    let writeReason: String
    let refreshID: UUID
    let perform:
        @MainActor (
            String, OperationFeedbackContext,
            @escaping @Sendable (RepositoryService) async throws -> OperationFeedbackOutcome
        ) -> Void
    let showChanges: () -> Void
    @ViewBuilder let detail: (StashContents, StashPart) -> Detail
    @State private var list: StashList?
    @State private var selection: String?
    @State private var contents: StashContents?
    @State private var part: StashPart = .working
    @State private var loading = false
    @State private var loadingContents = false
    @State private var listError: String?
    @State private var contentsError: String?
    @State private var limit = 200
    @State private var reload = UUID()
    @State private var restoreIndex = true
    @State private var contentsRetry = UUID()
    @State private var saveRequest: StashSaveRequest?
    @State private var actionRequest: StashActionRequest?
    private var selected: GitStash? { list?.entries.first { $0.id == selection } }
    private var canSave: Bool {
        canWrite && status.head != nil && status.sequencer == .none && status.conflicts.isEmpty
            && !status.files.isEmpty
    }
    private var canRestore: Bool {
        canWrite && !loading && !loadingContents && contents != nil && contentsError == nil
            && contents?.working.id == selected?.objectID && listError == nil && status.head != nil
            && status.sequencer == .none && status.files.allSatisfy(\.untracked)
    }

    private var saveReason: String {
        if !canWrite { return writeReason }
        if status.head == nil { return L10n.text("请先创建本地提交") }
        if status.sequencer != .none || !status.conflicts.isEmpty { return L10n.text("请先完成当前 Git 操作") }
        if status.files.isEmpty { return L10n.text("没有可保存的改动。") }
        return L10n.text("将改动保存为 Stash；不会自动切换分支。")
    }

    private var restoreReason: String {
        if !canWrite { return writeReason }
        if status.head == nil { return L10n.text("请先创建本地提交") }
        if status.sequencer != .none { return L10n.text("请先完成当前 Git 操作") }
        if loading || loadingContents { return L10n.text("正在读取储藏，请稍候。") }
        if contents == nil || listError != nil { return L10n.text("请先读取并选择一条有效记录。") }
        if !status.files.allSatisfy(\.untracked) { return L10n.text("请先提交或保存已跟踪文件的改动。") }
        return L10n.text("应用会保留记录；取出会在应用成功后删除。")
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PanelHeader(title: L10n.text("储藏"), symbol: "archivebox") {
                    Spacer()
                    Button(L10n.text("保存改动…"), systemImage: "plus") {
                        saveRequest = StashSaveRequest(status: status)
                    }.workbenchControlFamily().disabled(!canSave)
                        .help(saveReason)
                        .accessibilityIdentifier("stash-save")
                }
                Divider()
                if let listError {
                    EmptyPanel(
                        title: L10n.text("无法读取储藏"), symbol: "exclamationmark.triangle", message: listError)
                    Button(L10n.text("重试")) { reload = UUID() }.padding()
                } else if let list, !list.entries.isEmpty {
                    List(list.entries, selection: $selection) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.message).lineLimit(2)
                            HStack {
                                Text(entry.selector).monospaced()
                                Spacer()
                                Text(entry.createdAt, style: .date)
                            }.font(.caption).foregroundStyle(colors.secondaryText)
                        }.padding(.vertical, 4).tag(entry.id)
                            .accessibilityIdentifier("stash-record:" + entry.id)
                    }.listStyle(.inset).scrollContentBackground(.hidden).background(colors.canvas)
                        .accessibilityIdentifier("stash-list").accessibilityLabel(L10n.text("储藏列表"))
                    if list.hasMore {
                        Button(L10n.text("载入更多")) { limit = min(limit + 200, 10_000) }
                            .disabled(loading || limit >= 10_000).padding(10)
                    }
                } else if loading {
                    ProgressView(L10n.text("读取储藏…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyPanel(
                        title: L10n.text("没有储藏"), symbol: "archivebox", message: L10n.text("保存当前改动，稍后再恢复。")
                    )
                    .accessibilityIdentifier("stash-empty")
                }
                if loading && list != nil { ProgressView().controlSize(.small).padding(8) }
            }.frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
            recordDetail.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(colors.canvas)
        .task(id: "\(refreshID):\(reload):\(limit)") { await readList() }
        .task(id: "\(selected?.id ?? "none"):\(refreshID):\(contentsRetry)") { await readContents() }
        .sheet(item: $saveRequest) { request in
            StashSaveSheet(status: request.status, enabled: canWrite) { message, includeUntracked in
                let head = request.status.head
                let branch = request.status.branch
                let files = request.status.files
                saveRequest = nil
                perform(L10n.text("保存储藏"), .stashSave) { repository in
                    _ = try await repository.expectingBranch(branch).createStash(
                        message: message, includeUntracked: includeUntracked, expectedHead: head,
                        expectedFiles: files)
                    return .completed(message: L10n.text("改动已保存为储藏。"))
                }
            }.workbenchSheet(preferences)
        }
        .alert(
            actionRequest?.kind == .delete ? L10n.text("删除储藏？") : L10n.text("应用后删除储藏？"),
            isPresented: Binding(get: { actionRequest != nil }, set: { if !$0 { actionRequest = nil } }),
            presenting: actionRequest
        ) { request in
            Button(L10n.text("取消"), role: .cancel) { actionRequest = nil }
            Button(request.kind == .delete ? L10n.text("删除记录") : L10n.text("应用并删除"), role: .destructive) {
                actionRequest = nil
                execute(request)
            }.accessibilityIdentifier("stash-confirm-action")
        } message: { request in
            Text(
                request.entry.message + "\n" + request.entry.objectID.prefix(12) + "\n"
                    + (request.kind == .delete
                        ? L10n.text("删除后无法从列表恢复；不会删除工作区文件。")
                        : L10n.text("应用成功后才删除记录；产生冲突时保留记录。")))
        }
    }

    @ViewBuilder private var recordDetail: some View {
        if let entry = selected {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.message).font(.headline).textSelection(.enabled)
                    Text((entry.branch ?? L10n.text("来源分支未知")) + " · " + entry.objectID.prefix(12))
                        .font(.caption).foregroundStyle(colors.secondaryText)
                    HStack {
                        Toggle(L10n.text("恢复原暂存状态"), isOn: $restoreIndex)
                            .accessibilityIdentifier("stash-restore-index")
                        Spacer()
                        Button(L10n.text("应用")) { requestAction(.apply) }
                            .disabled(!canRestore).help(restoreReason).accessibilityIdentifier("stash-apply")
                        Button(L10n.text("取出…")) { requestAction(.pop) }
                            .disabled(!canRestore).help(restoreReason).accessibilityIdentifier("stash-pop")
                        Button(L10n.text("删除…"), role: .destructive) { requestAction(.delete) }
                            .disabled(!canWrite || loading || listError != nil).accessibilityIdentifier(
                                "stash-delete")
                    }.workbenchControlFamily()
                    Text(L10n.text("应用会保留记录；取出会在应用成功后删除。请先处理已跟踪文件的现有改动。"))
                        .font(.caption).foregroundStyle(colors.secondaryText)
                    if !status.conflicts.isEmpty {
                        Button(L10n.text("前往更改解决冲突"), action: showChanges)
                            .accessibilityIdentifier("stash-show-conflicts")
                    }
                    Picker(L10n.text("记录内容"), selection: $part) {
                        ForEach(
                            StashPart.allCases.filter {
                                $0 != .untracked || contents == nil || contents?.untracked != nil
                            }
                        ) {
                            Text($0.title).tag($0)
                        }
                    }.pickerStyle(.segmented).disabled(
                        loadingContents || contents?.working.id != entry.objectID
                    )
                    .accessibilityIdentifier("stash-content-part")
                }.padding(16)
                Divider()
                if loadingContents {
                    ProgressView(L10n.text("读取记录内容…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let contentsError {
                    VStack {
                        EmptyPanel(
                            title: L10n.text("无法读取记录内容"), symbol: "exclamationmark.triangle",
                            message: contentsError)
                        Button(L10n.text("重试")) { contentsRetry = UUID() }.padding()
                    }
                } else if let contents {
                    detail(contents, part)
                }
            }.id(entry.id)
        } else {
            EmptyPanel(
                title: L10n.text("选择一条储藏"), symbol: "archivebox",
                message: L10n.text("分别查看保存的工作区、暂存区与未跟踪文件。"))
        }
    }

    private func readList() async {
        loading = true
        listError = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            let result = try await service.stashes(limit: limit)
            guard !Task.isCancelled else { return }
            list = result
            if !result.entries.contains(where: { $0.id == selection }) {
                selection = result.entries.first?.id
            }
        } catch {
            if !Task.isCancelled { listError = error.localizedDescription }
        }
    }

    private func readContents() async {
        contents = nil
        contentsError = nil
        loadingContents = true
        defer { if !Task.isCancelled { loadingContents = false } }
        guard let entry = selected, let list else { return }
        do {
            let result = try await service.stashContents(entry, in: list)
            guard !Task.isCancelled, selected?.id == entry.id else { return }
            contents = result
            if part == .untracked && result.untracked == nil { part = .working }
        } catch {
            if !Task.isCancelled { contentsError = error.localizedDescription }
        }
    }

    private func requestAction(_ kind: StashActionRequest.Kind) {
        guard let entry = selected, let list, canWrite else { return }
        let request = StashActionRequest(
            kind: kind, entry: entry, list: list, head: status.head, branch: status.branch,
            restoreIndex: restoreIndex)
        if kind == .apply { execute(request) } else { actionRequest = request }
    }

    private func execute(_ request: StashActionRequest) {
        guard canWrite else { return }
        let title = request.kind == .delete ? L10n.text("删除储藏") : L10n.text("恢复储藏")
        perform(title, .standard) { repository in
            let pinned = repository.expectingBranch(request.branch)
            if request.kind == .delete {
                try await pinned.deleteStash(request.entry, in: request.list, expectedHead: request.head)
                return .completed(message: L10n.text("储藏已删除。"))
            }
            let outcome = try await pinned.restoreStash(
                request.entry, in: request.list, restoreIndex: request.restoreIndex,
                pop: request.kind == .pop, expectedHead: request.head)
            switch outcome {
            case .applied: return .completed(message: L10n.text("内容已应用，储藏已保留。"))
            case .popped: return .completed(message: L10n.text("内容已应用，储藏已删除。"))
            case .appliedNeedsReview(let reason):
                return .needsReview(
                    message: L10n.text("内容已应用。记录列表或删除结果需要核对，请勿重复恢复。"), details: reason)
            }
        }
    }
}

private struct StashSaveSheet: View {
    let status: RepositoryStatus
    let enabled: Bool
    let save: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeUntracked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("保存储藏")).font(.title2.bold())
            Text(status.displayBranch).font(.headline)
            TextField(L10n.text("记录名称（可选）"), text: $message).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("stash-message")
            Toggle(L10n.text("包含未跟踪文件"), isOn: $includeUntracked)
                .accessibilityIdentifier("stash-include-untracked")
            Text(L10n.text("忽略文件不会保存。保存后，所选范围内的改动从工作区移入记录。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(
                        Array(Set(status.files.filter { !$0.untracked || includeUntracked }.map(\.path)))
                            .sorted(), id: \.self
                    ) { path in
                        Text(path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 150)
            HStack {
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("保存")) { save(message, includeUntracked) }
                    .keyboardShortcut(.defaultAction).disabled(
                        !enabled || !status.files.contains { !$0.untracked || includeUntracked }
                    )
                    .accessibilityIdentifier("stash-create-confirm")
            }.workbenchControlFamily()
        }.padding(24).frame(width: 480)
    }
}
