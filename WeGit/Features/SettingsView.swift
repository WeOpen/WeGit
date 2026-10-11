import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WeGitCore

struct SettingsView: View {
    @Bindable var app: AppState
    @Bindable var preferences: AppPreferences
    @State private var error: String?
    @State private var notice: String?

    init(app: AppState) {
        self.app = app
        preferences = app.preferences
    }

    var body: some View {
        TabView {
            general.tabItem { Label("通用", systemImage: "gearshape") }
            GitSettingsView(app: app).tabItem { Label("Git", systemImage: "arrow.triangle.branch") }
            appearance.tabItem { Label("外观", systemImage: "paintpalette") }
            diff.tabItem { Label("差异", systemImage: "square.split.2x1") }
            commit.tabItem { Label("提交", systemImage: "checkmark.circle") }
            advanced.tabItem { Label("高级", systemImage: "slider.horizontal.3") }
        }.frame(width: 700, height: 560).padding(12)
            .preferredColorScheme(
                app.appearance == "system" ? nil : app.appearance == "dark" ? .dark : .light
            )
            .alert("设置操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    private var general: some View {
        Form {
            Section("打开与克隆") {
                LabeledContent("默认目录") {
                    Text(app.preferences.defaultDirectory).lineLimit(2).truncationMode(.middle).textSelection(
                        .enabled)
                }
                Button("选择默认目录…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.directoryURL = URL(fileURLWithPath: app.preferences.defaultDirectory)
                    if panel.runModal() == .OK, let url = panel.url {
                        app.preferences.defaultDirectory = url.path
                    }
                }
            }
            Section("启动与窗口") {
                Toggle("启动时恢复上次仓库", isOn: $preferences.restoreRepository)
                Toggle("恢复窗口、分栏和仓库页面", isOn: $preferences.restoreWindow)
                Toggle("切换仓库前确认", isOn: $preferences.confirmRepositorySwitch)
                Text("切换仓库不会取消正在进行的 Git 操作；关闭仓库前需要等待或取消操作。")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            Section("风险确认") {
                Text("丢弃改动、修改提交、删除未合并分支和 Force Push With Lease 始终需要明确确认。")
                    .font(.callout)
            }
        }.formStyle(.grouped)
    }

    private var appearance: some View {
        Form {
            Section("界面") {
                Picker("主题", selection: $preferences.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Picker("列表密度", selection: $preferences.density) {
                    Text("舒适").tag("comfortable")
                    Text("紧凑").tag("compact")
                }
                Toggle("显示文件图标", isOn: $preferences.showFileIcons)
            }
            Section("差异文本") {
                Picker("代码字体", selection: $preferences.codeFont) {
                    Text("系统等宽字体").tag("system")
                    Text("Menlo").tag("Menlo")
                    Text("Monaco").tag("Monaco")
                }
                Slider(value: $preferences.codeSize, in: 11...24, step: 1) {
                    Text("字号 \(Int(app.preferences.codeSize)) pt")
                }
                Text("let changes = repository.status()")
                    .font(
                        app.preferences.codeFont == "system"
                            ? .system(size: app.codeSize, design: .monospaced)
                            : .custom(app.preferences.codeFont, size: app.codeSize)
                    )
                    .padding(.vertical, 12)
            }
        }.formStyle(.grouped)
    }

    private var diff: some View {
        Form {
            Section("默认阅读方式") {
                Picker("布局", selection: $preferences.splitDiff) {
                    Text("统一").tag(false)
                    Text("分栏").tag(true)
                }
                Picker("上下文行数", selection: $preferences.contextLines) {
                    ForEach([3, 20, 80, 200], id: \.self) { Text("\($0) 行").tag($0) }
                }
                Toggle("词级差异", isOn: $preferences.wordDiff)
                Toggle("显示行号", isOn: $preferences.showLineNumbers)
                Toggle("显示空格和 Tab 标记", isOn: $preferences.showWhitespace)
                Toggle("忽略空白差异（只读）", isOn: $preferences.ignoreWhitespace)
                Text("空白标记只改变显示，复制与补丁保留原文。忽略空白时禁用块级写入。仓库中的临时布局选择会单独保存。")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            }
        }.formStyle(.grouped)
    }

    private var commit: some View {
        Form {
            Section("草稿") {
                Toggle("按仓库保存提交草稿", isOn: $preferences.saveDrafts)
                Text("关闭后，新编辑不再持久保存；已经保存的草稿保留，便于手动恢复或清除。草稿不会同步或上传。")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                if let session = app.session {
                    LabeledContent("当前仓库", value: session.location.name)
                    if let saved = app.defaults.string(forKey: "draft-v2:" + session.location.persistenceID),
                        !saved.isEmpty, saved != session.message
                    {
                        Button("恢复已保存的草稿…") {
                            if app.confirm(
                                title: "恢复已保存的草稿？", message: "将替换当前草稿文本：\n\n\(saved)",
                                action: "恢复草稿", destructive: false)
                            {
                                session.message = saved
                            }
                        }.disabled(session.isBusy)
                    }
                    Button("清除此仓库的草稿…") {
                        if app.confirm(
                            title: "清除提交草稿？", message: "只清除 \(session.location.name) 的草稿文本，不修改 Git 文件或提交。",
                            action: "清除草稿")
                        {
                            session.message = ""
                            app.defaults.removeObject(forKey: "draft-v2:" + session.location.persistenceID)
                            app.defaults.removeObject(forKey: "draft:" + session.location.id)
                            session.legacyDraft = nil
                        }
                    }.disabled(session.isBusy)
                    if let legacy = session.legacyDraft {
                        Button("恢复此路径的旧版草稿…") {
                            if app.confirm(
                                title: "恢复旧版草稿？",
                                message: "旧版草稿只记录路径，无法确认是否属于当前仓库。恢复将替换当前草稿，请先核对：\n\n\(legacy)",
                                action: "恢复草稿", destructive: false)
                            {
                                session.message = legacy
                            }
                        }.disabled(session.isBusy)
                    }
                }
            }
            Section("提交与恢复") {
                Text("Amend 始终先确认历史改写。“提交并推送”会分别记录结果；推送失败后的重试不会再次提交。")
                Text("已有 Hook 与 GPG/SSH 签名配置继续由 Git 执行，失败时保留草稿。")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            }
        }.formStyle(.grouped)
    }

    private var advanced: some View {
        Form {
            Section("活动记录") {
                Picker("最多保留", selection: $preferences.activityLimit) {
                    ForEach([100, 500, 1000], id: \.self) { Text("\($0) 条").tag($0) }
                }
                Picker("最长保留时间", selection: $preferences.activityHours) {
                    Text("1 小时").tag(1)
                    Text("24 小时").tag(24)
                    Text("7 天").tag(168)
                }
                Text("活动摘要仅在本次运行的内存中保存，退出后清空；保留规则同时受数量与时间限制。")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                HStack {
                    Button("导出诊断摘要…") { exportDiagnostics() }
                    Button("清空活动记录") {
                        Task {
                            await app.engine.activity.clear()
                            notice = "已清空活动记录"
                        }
                    }
                }
                Text("诊断摘要包含版本、命令名称、时间与结果，不包含仓库路径、代码、Diff、提交消息、输出或凭证。")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                if let notice { Text(notice).font(.caption).foregroundStyle(AppColors.secondaryText) }
            }
            Section("界面状态") {
                Button("重置界面偏好…") {
                    if app.confirm(
                        title: "重置界面偏好？", message: "重置主题、密度、差异显示及仓库页面布局。Git 配置、仓库、最近记录和提交草稿会保留。",
                        action: "重置界面", destructive: false)
                    {
                        app.resetInterface()
                    }
                }.disabled(app.anyOperationRunning)
            }
        }.formStyle(.grouped)
    }

    private func exportDiagnostics() {
        Task {
            let entries = await app.engine.activity.all().map {
                DiagnosticEntry(
                    date: $0.date, command: $0.command, state: $0.state.title, exitCode: $0.exitCode,
                    duration: $0.duration)
            }
            let report = DiagnosticReport(
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                system: ProcessInfo.processInfo.operatingSystemVersionString, git: app.gitVersion,
                entries: entries)
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(report)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "WeGit-diagnostics.json"
                if panel.runModal() == .OK, let url = panel.url {
                    try data.write(to: url, options: .atomic)
                    notice = "诊断摘要已导出"
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct DiagnosticEntry: Encodable {
    let date: Date
    let command: String
    let state: String
    let exitCode: Int32?
    let duration: TimeInterval
}

private struct DiagnosticReport: Encodable {
    let appVersion: String
    let system: String
    let git: String
    let entries: [DiagnosticEntry]
}
