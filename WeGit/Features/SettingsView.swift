import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WeGitCore

struct SettingsView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Bindable var preferences: AppPreferences
    @State private var error: String?
    @State private var notice: String?
    @State private var selectedTab: Int
    @State private var themeEditorPresented = false

    init(app: AppState) {
        self.app = app
        preferences = app.preferences
        let stored =
            app.defaults.object(forKey: "settingsTab") as? Int
            ?? UserDefaults.standard.integer(forKey: "com_apple_SwiftUI_Settings_selectedTabIndex")
        _selectedTab = State(initialValue: (0..<6).contains(stored) ? stored : 0)
    }

    var body: some View {
        VStack(spacing: 12) {
            WorkbenchGlassTabs(
                title: L10n.text("设置分类"), selection: $selectedTab,
                tabs: [
                    GlassTab(value: 0, title: L10n.text("通用"), symbol: "gearshape"),
                    GlassTab(value: 1, title: "Git", symbol: "arrow.triangle.branch"),
                    GlassTab(value: 2, title: L10n.text("外观"), symbol: "paintpalette"),
                    GlassTab(value: 3, title: L10n.text("差异"), symbol: "square.split.2x1"),
                    GlassTab(value: 4, title: L10n.text("提交"), symbol: "checkmark.circle"),
                    GlassTab(value: 5, title: L10n.text("高级"), symbol: "slider.horizontal.3"),
                ], height: 40, identifier: "settings-tabs")
            Group {
                switch selectedTab {
                case 1: GitSettingsView(app: app)
                case 2: appearance
                case 3: diff
                case 4: commit
                case 5: advanced
                default: general
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: 700, height: 560).padding(12)
            .background(colors.canvas)
            .onChange(of: selectedTab) { _, value in
                app.defaults.set(value, forKey: "settingsTab")
            }
            .animation(nil, value: app.appearance)
            .sheet(isPresented: $themeEditorPresented) {
                ThemeEditor(preferences: preferences)
                    .workbenchControlFamily().workbenchAppearance(preferences)
            }
            .alert(
                L10n.text("设置操作未完成"),
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button(L10n.text("好"), role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    private var general: some View {
        ThemedForm {
            Section(L10n.text("语言")) {
                Picker(L10n.text("界面语言"), selection: $preferences.language) {
                    Text(L10n.text("跟随系统")).tag(AppLanguage.system)
                    Text(verbatim: L10n.text("简体中文")).tag(AppLanguage.simplifiedChinese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }.accessibilityIdentifier("settings-language")
                Text(L10n.text("界面和应用菜单立即切换，无需重新启动。macOS 提供的系统面板可能沿用系统语言。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)

            }
            Section(L10n.text("打开与克隆")) {
                LabeledContent(L10n.text("默认目录")) {
                    Text(app.preferences.defaultDirectory).lineLimit(2).truncationMode(.middle).textSelection(
                        .enabled)
                }
                Button(L10n.text("选择默认目录…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.directoryURL = URL(fileURLWithPath: app.preferences.defaultDirectory)
                    if panel.runModal() == .OK, let url = panel.url {
                        app.preferences.defaultDirectory = url.path
                    }
                }
            }
            Section(L10n.text("启动与窗口")) {
                Toggle(L10n.text("在菜单栏显示 WeGit"), isOn: $preferences.showMenuBar)
                    .accessibilityLabel(L10n.text("在菜单栏显示 WeGit")).accessibilityIdentifier(
                        "settings-menu-bar")
                Text(L10n.text("从菜单栏查看仓库状态、最近仓库与常用操作，关闭主窗口后也可重新打开。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)
                Toggle(L10n.text("启动时恢复上次仓库"), isOn: $preferences.restoreRepository)
                    .accessibilityLabel(L10n.text("启动时恢复上次仓库")).accessibilityIdentifier(
                        "settings-restore-repository")
                Toggle(L10n.text("恢复窗口、分栏和仓库页面"), isOn: $preferences.restoreWindow)
                    .accessibilityLabel(L10n.text("恢复窗口、分栏和仓库页面"))
                Toggle(L10n.text("切换仓库前确认"), isOn: $preferences.confirmRepositorySwitch)
                    .accessibilityLabel(L10n.text("切换仓库前确认"))
                Text(L10n.text("切换仓库不会取消正在进行的 Git 操作；关闭仓库前需要等待或取消操作。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)
            }
            Section(L10n.text("风险确认")) {
                Text(L10n.text("丢弃改动、修改提交、删除未合并分支和 Force Push With Lease 始终需要明确确认。"))
                    .font(.callout)
            }
        }
    }

    private var appearance: some View {
        ThemedForm {
            Section(L10n.text("界面")) {
                Picker(L10n.text("主题"), selection: $preferences.appearance) {
                    Text(L10n.text("跟随系统")).tag("system")
                    Text(L10n.text("浅色")).tag("light")
                    Text(L10n.text("深色")).tag("dark")
                    Text(L10n.text("自定义")).tag("custom")
                }.accessibilityLabel(L10n.text("主题")).accessibilityIdentifier("settings-appearance")
                Picker(L10n.text("列表密度"), selection: $preferences.density) {
                    Text(L10n.text("舒适")).tag("comfortable")
                    Text(L10n.text("紧凑")).tag("compact")
                }.accessibilityLabel(L10n.text("列表密度")).accessibilityIdentifier("settings-density")
                Toggle(L10n.text("显示文件图标"), isOn: $preferences.showFileIcons)
                    .accessibilityLabel(L10n.text("显示文件图标"))
                Toggle(L10n.text("界面动效"), isOn: $preferences.interfaceMotion)
                    .accessibilityLabel(L10n.text("界面动效")).accessibilityIdentifier(
                        "settings-interface-motion")
                Text(L10n.text("欢迎标记与操作反馈使用短动画，并遵循 macOS 的“减少动态效果”设置。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)
            }
            Section(L10n.text("自定义配色")) {
                LabeledContent(L10n.text("已保存主题"), value: preferences.customTheme.name)
                Button(L10n.text("编辑自定义主题…")) { themeEditorPresented = true }
                    .accessibilityIdentifier("settings-custom-theme")
                Text(L10n.text("自定义配色独立保存，内置浅色与深色保持不变。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)
                if preferences.customThemeLoadFailed {
                    Text(L10n.text("上次的自定义主题无法读取，当前使用初始配色。"))
                        .font(.caption).foregroundStyle(colors.modified)
                }
            }
            Section(L10n.text("差异文本")) {
                Picker(L10n.text("代码字体"), selection: $preferences.codeFont) {
                    Text(L10n.text("系统等宽字体")).tag("system")
                    Text("Menlo").tag("Menlo")
                    Text("Monaco").tag("Monaco")
                }.accessibilityLabel(L10n.text("代码字体")).accessibilityIdentifier("settings-code-font")
                Slider(value: $preferences.codeSize, in: 11...24, step: 1) {
                    Text(L10n.text("字号 \(Int(app.preferences.codeSize)) pt"))
                }.accessibilityIdentifier("settings-code-size")
                Text("let changes = repository.status()")
                    .font(
                        app.preferences.codeFont == "system"
                            ? .system(size: app.codeSize, design: .monospaced)
                            : .custom(app.preferences.codeFont, size: app.codeSize)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).workbenchSurface()
            }
        }
    }

    private var diff: some View {
        ThemedForm {
            Section(L10n.text("默认阅读方式")) {
                Picker(L10n.text("布局"), selection: $preferences.splitDiff) {
                    Text(L10n.text("统一")).tag(false)
                    Text(L10n.text("分栏")).tag(true)
                }
                Picker(L10n.text("上下文行数"), selection: $preferences.contextLines) {
                    ForEach([3, 20, 80, 200], id: \.self) { Text(L10n.count("%lld 行", $0)).tag($0) }
                }
                Toggle(L10n.text("词级差异"), isOn: $preferences.wordDiff)
                    .accessibilityLabel(L10n.text("词级差异"))
                Toggle(L10n.text("显示行号"), isOn: $preferences.showLineNumbers)
                    .accessibilityLabel(L10n.text("显示行号"))
                Toggle(L10n.text("显示空格和 Tab 标记"), isOn: $preferences.showWhitespace)
                    .accessibilityLabel(L10n.text("显示空格和 Tab 标记")).accessibilityIdentifier(
                        "settings-whitespace")
                Toggle(L10n.text("忽略空白差异（只读）"), isOn: $preferences.ignoreWhitespace)
                    .accessibilityLabel(L10n.text("忽略空白差异（只读）"))
                Text(L10n.text("空白标记只改变显示，复制与补丁保留原文。忽略空白时禁用块级写入。仓库中的临时布局选择会单独保存。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)
            }
        }
    }

    private var commit: some View {
        ThemedForm {
            Section(L10n.text("草稿")) {
                Toggle(L10n.text("按仓库保存提交草稿"), isOn: $preferences.saveDrafts)
                    .accessibilityLabel(L10n.text("按仓库保存提交草稿")).accessibilityIdentifier(
                        "settings-save-drafts")
                Text(L10n.text("关闭后，新编辑不再持久保存；已经保存的草稿保留，便于手动恢复或清除。草稿不会同步或上传。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)
                if let session = app.session {
                    LabeledContent(L10n.text("当前仓库"), value: session.location.name)
                    if let saved = app.defaults.string(forKey: "draft-v2:" + session.location.persistenceID),
                        !saved.isEmpty, saved != session.message
                    {
                        Button(L10n.text("恢复已保存的草稿…")) {
                            if app.confirm(
                                title: L10n.text("恢复已保存的草稿？"), message: L10n.text("将替换当前草稿文本：\n\n\(saved)"),
                                action: L10n.text("恢复草稿"), destructive: false)
                            {
                                session.message = saved
                            }
                        }.disabled(session.isBusy)
                    }
                    Button(L10n.text("清除此仓库的草稿…")) {
                        if app.confirm(
                            title: L10n.text("清除提交草稿？"),
                            message: L10n.text("只清除 \(session.location.name) 的草稿文本，不修改 Git 文件或提交。"),
                            action: L10n.text("清除草稿"))
                        {
                            session.message = ""
                            app.defaults.removeObject(forKey: "draft-v2:" + session.location.persistenceID)
                            app.defaults.removeObject(forKey: "draft:" + session.location.id)
                            session.legacyDraft = nil
                        }
                    }.disabled(session.isBusy)
                    if let legacy = session.legacyDraft {
                        Button(L10n.text("恢复此路径的旧版草稿…")) {
                            if app.confirm(
                                title: L10n.text("恢复旧版草稿？"),
                                message: L10n.text("旧版草稿只记录路径，无法确认是否属于当前仓库。恢复将替换当前草稿，请先核对：\n\n\(legacy)"),
                                action: L10n.text("恢复草稿"), destructive: false)
                            {
                                session.message = legacy
                            }
                        }.disabled(session.isBusy)
                    }
                }
            }
            Section(L10n.text("提交与恢复")) {
                Text(L10n.text("Amend 始终先确认历史改写。“提交并推送”会分别记录结果；推送失败后的重试不会再次提交。"))
                Text(L10n.text("已有 Hook 与 GPG/SSH 签名配置继续由 Git 执行，失败时保留草稿。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)
            }
        }
    }

    private var advanced: some View {
        ThemedForm {
            Section(L10n.text("活动记录")) {
                Picker(L10n.text("最多保留"), selection: $preferences.activityLimit) {
                    ForEach([100, 500, 1000], id: \.self) { Text(L10n.text("\($0) 条")).tag($0) }
                }
                Picker(L10n.text("最长保留时间"), selection: $preferences.activityHours) {
                    Text(L10n.text("1 小时")).tag(1)
                    Text(L10n.text("24 小时")).tag(24)
                    Text(L10n.text("7 天")).tag(168)
                }
                Text(L10n.text("活动摘要仅在本次运行的内存中保存，退出后清空；保留规则同时受数量与时间限制。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)
                HStack {
                    Button(L10n.text("导出诊断摘要…")) { exportDiagnostics() }
                    Button(L10n.text("清空活动记录")) {
                        Task {
                            await app.engine.activity.clear()
                            notice = L10n.text("已清空活动记录")
                        }
                    }
                }
                Text(L10n.text("诊断摘要包含版本、命令名称、时间与结果，不包含仓库路径、代码、Diff、提交消息、输出或凭证。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)
                if let notice { Text(notice).font(.caption).foregroundStyle(colors.secondaryText) }
            }
            Section(L10n.text("界面状态")) {
                Button(L10n.text("重置界面偏好…")) {
                    if app.confirm(
                        title: L10n.text("重置界面偏好？"),
                        message: L10n.text("重置主题、密度、差异显示及仓库页面布局。Git 配置、仓库、最近记录和提交草稿会保留。"),
                        action: L10n.text("重置界面"), destructive: false)
                    {
                        app.resetInterface()
                    }
                }.disabled(app.anyOperationRunning)
            }
        }
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
                    notice = L10n.text("诊断摘要已导出")
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
