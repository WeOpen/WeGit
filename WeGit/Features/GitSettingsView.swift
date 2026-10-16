import AppKit
import SwiftUI
import WeGitCore

private struct GitSettingEditRequest: Identifiable {
    let id = UUID()
    let snapshot: GitSettingSnapshot
    let scope: GitSettingScope
    let service: GitConfigurationService
}

struct GitSettingsView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @State private var settings: [GitSettingSnapshot] = []
    @State private var scope = GitSettingScope.local
    @State private var loading = false
    @State private var error: String?
    @State private var edit: GitSettingEditRequest?
    @State private var pendingExecutable: String?
    @State private var loadID = UUID()

    private var service: GitConfigurationService {
        GitConfigurationService(
            engine: app.engine, location: app.session?.location,
            queue: app.session?.service.queue ?? RepositoryOperationQueue())
    }

    var body: some View {
        ThemedForm {
            Section(L10n.text("Git 可执行文件")) {
                LabeledContent(L10n.text("正在使用")) { Text(app.engine.executable.path).textSelection(.enabled) }
                LabeledContent(L10n.text("版本"), value: app.gitVersion)
                Text(
                    L10n.text(
                        "需要 Git \(GitInstallation.minimumVersion)+ 和运行时配置能力。自动检测依次检查系统/Xcode、Homebrew 和 PATH。"
                    )
                )
                .font(.caption).foregroundStyle(colors.secondaryText)
                HStack {
                    Button(L10n.text("选择 Git…")) { chooseGit() }.disabled(app.anyOperationRunning)
                    Button(L10n.text("恢复自动检测")) {
                        app.defaults.removeObject(forKey: "gitExecutable")
                        pendingExecutable = L10n.text("重启后自动检测")
                    }.disabled(app.anyOperationRunning)
                }
                if let pendingExecutable {
                    Text(pendingExecutable).font(.caption).foregroundStyle(colors.secondaryText)
                }
            }
            Section(L10n.text("身份与策略")) {
                Picker(L10n.text("写入作用域"), selection: $scope) {
                    Text(L10n.text("全局")).tag(GitSettingScope.global)
                    if app.session != nil { Text(L10n.text("当前仓库")).tag(GitSettingScope.local) }
                }.disabled(app.anyOperationRunning).accessibilityIdentifier("git-setting-scope")
                Text(
                    scope == .global
                        ? L10n.text("全局设置可被其他仓库继承；本地值仍可覆盖它。")
                        : L10n.text("只编辑当前仓库：\(app.session?.location.name ?? L10n.text("未打开仓库"))")
                )
                .font(.caption).foregroundStyle(colors.secondaryText)
                if loading { ProgressView(L10n.text("读取配置及来源…")).controlSize(.small) }
                ForEach(settings, id: \.key) { setting in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(setting.key.title).font(.headline)
                            Text(setting.effective?.value ?? L10n.text("未配置")).textSelection(.enabled)
                            if let record = setting.effective {
                                Text("\(record.scope) · \(record.origin)").font(.caption).foregroundStyle(
                                    colors.secondaryText
                                )
                                .textSelection(.enabled)
                            }
                            Text(
                                L10n.text(
                                    "\(scope.title)直接设置：\(setting.values(in: scope).last ?? L10n.text("未设置，使用继承值"))"
                                )
                            )
                            .font(.caption).foregroundStyle(colors.secondaryText)
                        }
                        Spacer()
                        Button(L10n.text("编辑…")) {
                            edit = GitSettingEditRequest(snapshot: setting, scope: scope, service: service)
                        }
                        .disabled(loading || app.anyOperationRunning)
                        .accessibilityIdentifier("edit-setting:" + setting.key.rawValue)
                    }
                }
                if let error { Text(error).foregroundStyle(colors.negative).font(.callout) }
                Button(L10n.text("重新读取配置")) { Task { await load() } }.disabled(
                    loading || app.anyOperationRunning)
            }
            Section(L10n.text("认证")) {
                Text(L10n.text("优先复用 Credential Helper、SSH Agent 和已配置的 AskPass。缺少凭证时使用独立窗口输入，等待超过 2 分钟自动取消。"))
                    .font(.callout)
                Text(L10n.text("不会自动信任新主机或关闭主机检查。签名继续使用现有 Git 配置。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)
            }
        }
        .task(id: app.session?.id) {
            if app.session == nil { scope = .global }
            if let stored = app.defaults.string(forKey: "gitExecutable"),
                stored != app.engine.executable.path
            {
                pendingExecutable = L10n.text("重启后使用：") + stored
            }
            await load()
        }
        .sheet(item: $edit) { request in
            GitSettingEditor(app: app, request: request) { _ in
                Task { await load() }
                for session in app.sessions.values { session.scheduleRefresh() }
            }
        }
    }

    private func load() async {
        let request = UUID()
        loadID = request
        let repository = app.session?.id
        loading = true
        error = nil
        let service = service
        do {
            let values = try await service.readAll()
            try Task.checkCancellation()
            guard loadID == request, app.session?.id == repository else { return }
            settings = values
            loading = false
        } catch {
            if !Task.isCancelled, loadID == request, app.session?.id == repository {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    private func chooseGit() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    let installation = try await GitInstallation.detect(preferred: url)
                    app.defaults.set(installation.executable.path, forKey: "gitExecutable")
                    pendingExecutable = L10n.text(
                        "重启后使用：\(installation.executable.path) · \(installation.version)")
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

private struct GitSettingEditor: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    let request: GitSettingEditRequest
    let onSaved: (GitSettingSnapshot) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: GitSettingSnapshot
    @State private var value: String
    @State private var isSaving = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    init(app: AppState, request: GitSettingEditRequest, onSaved: @escaping (GitSettingSnapshot) -> Void) {
        self.app = app
        self.request = request
        self.onSaved = onSaved
        _snapshot = State(initialValue: request.snapshot)
        _value = State(
            initialValue: request.snapshot.values(in: request.scope).last ?? request.snapshot.effective?.value
                ?? request.snapshot.key.choices.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("编辑\(snapshot.key.title)"), symbol: "slider.horizontal.3")
            Text(
                L10n.text(
                    "写入：\(request.scope.title)\(request.scope == .local ? " · " + (request.service.location?.name ?? "") : "")"
                )
            ).font(.headline)
            Text(snapshot.key.rawValue).font(.caption.monospaced()).foregroundStyle(colors.secondaryText)
            if snapshot.key.choices.isEmpty {
                TextField(snapshot.key.title, text: $value).textFieldStyle(.roundedBorder)
                    .disabled(isSaving)
                    .accessibilityIdentifier("git-setting-value")
            } else {
                Picker(L10n.text("配置值"), selection: $value) {
                    ForEach(snapshot.key.choices, id: \.self) { choice in
                        Text(choiceTitle(choice)).tag(choice)
                    }
                }.disabled(isSaving)
                Text(L10n.text("此设置不会改变已经打开的同步确认；下一次 Pull 会重新读取有效配置。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)
            }
            if let effective = snapshot.effective {
                Text(L10n.text("当前有效值：\(effective.value)\n来源：\(effective.scope) · \(effective.origin)"))
                    .font(.caption).foregroundStyle(colors.secondaryText).textSelection(.enabled)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(colors.negative).textSelection(.enabled)
            }
            if snapshot.values(in: request.scope).count > 1 {
                Text(L10n.text("当前作用域有多个直接值，保存会合并为一个值。")).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button(L10n.text("移除此作用域的设置")) { save(nil) }
                    .disabled(
                        isSaving || app.anyOperationRunning || snapshot.values(in: request.scope).isEmpty)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button(isSaving ? L10n.text("取消操作") : L10n.text("取消")) {
                    if isSaving { task?.cancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.text("保存到\(request.scope.title)")) { save(value) }.workbenchPrimaryAction().tint(
                    colors.primaryAction
                )
                .disabled(isSaving || app.anyOperationRunning || value.isEmpty)
                .accessibilityIdentifier("git-setting-save")
            }
            if error != nil {
                Button(L10n.text("重新读取，再编辑")) {
                    task = Task {
                        do {
                            snapshot = try await request.service.read(snapshot.key)
                            value = snapshot.values(in: request.scope).last ?? ""
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(isSaving)
            }
        }.padding(24).frame(width: 550).interactiveDismissDisabled(isSaving)
    }

    private func choiceTitle(_ choice: String) -> String {
        if snapshot.key == .pullRebase {
            switch choice {
            case "true": return L10n.text("变基（true）")
            case "merges": return L10n.text("变基并保留合并结构（merges）")
            default: return L10n.text("合并（false）")
            }
        }
        switch choice {
        case "only": return L10n.text("仅快进（only）")
        case "false": return L10n.text("创建合并提交（false）")
        default: return L10n.text("允许快进（true）")
        }
    }

    private func save(_ value: String?) {
        guard !isSaving, !app.anyOperationRunning else { return }
        isSaving = true
        app.preferences.configurationWriteInProgress = true
        error = nil
        let expected = snapshot
        task = Task {
            defer {
                isSaving = false
                app.preferences.configurationWriteInProgress = false
            }
            do {
                let result = try await request.service.set(value, scope: request.scope, expected: expected)
                onSaved(result)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
