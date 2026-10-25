import AppKit
import SwiftUI
import WeGitCore

@MainActor
private struct CatalogContent: View {
    @Bindable var preferences: AppPreferences
    @State private var query = ""
    @State private var layout = 0
    @Environment(\.themeColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                BrandMark().frame(width: 40, height: 40)
                Text("WeGit · 组件样册").font(.system(size: 21, weight: .medium))
                Spacer()
                Button("浅色") { preferences.appearance = "light" }
                    .accessibilityIdentifier("catalog-light")
                Button("深色") { preferences.appearance = "dark" }
                    .accessibilityIdentifier("catalog-dark")
            }
            Divider()
            HStack(spacing: 12) {
                Button("提交", systemImage: "checkmark") {}.workbenchPrimaryAction()
                Button("获取", systemImage: "arrow.clockwise") {}
                Button("推送", systemImage: "arrow.up") {}.disabled(true)
                Button("搜索", systemImage: "magnifyingglass") {}.workbenchIconButton()
                    .accessibilityLabel("搜索")
                Spacer()
                ProgressView("读取中…").controlSize(.mini)
            }
            HStack(spacing: 16) {
                WorkbenchSearchField(prompt: "筛选文件路径", text: $query, identifier: "catalog-search")
                WorkbenchGlassTabs(
                    title: "差异布局", selection: $layout,
                    tabs: [GlassTab(value: 0, title: "统一"), GlassTab(value: 1, title: "分栏")],
                    identifier: "catalog-layout"
                )
                .frame(width: 180)
            }
            HStack(spacing: 10) {
                ReferenceBadge(name: "main")
                ReferenceBadge(name: "v1.1.1")
                ReferenceBadge(name: "feature/paper-and-celadon")
                Spacer()
                StatusBadge(symbol: "M")
                DiffChangeSummary(additions: 12, deletions: 4)
                CountBadge(value: "24", tone: .blue)
                CountBadge(value: "8", tone: .teal)
                CountBadge(value: "3", tone: .violet)
            }
            HStack(alignment: .top, spacing: 16) {
                #if V111_BASELINE
                    OperationFeedback(busy: false, activity: "", notice: "提交完成", fallback: "")
                    OperationFeedback(busy: false, activity: "", notice: "结果需要核对", fallback: "")
                #else
                    OperationFeedback(
                        busy: false, activity: "", result: .success(message: "提交完成"),
                        context: .commit, fallback: "")
                    OperationFeedback(
                        busy: false, activity: "",
                        result: .needsReview(message: "结果需要核对", details: "请核对真实目标，避免重复操作。"),
                        fallback: "")
                #endif
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    FileTypeIcon(path: "Workbench.swift")
                    Text("Workbench.swift").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("Sources/Interface").font(.caption).foregroundStyle(colors.secondaryText)
                }
                Text("let changes = repository.status()")
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                Text("+ let committed = changes.staged")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(colors.text)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading).background(colors.diffAdded)
            }.padding(14).workbenchSurface()
            HStack(spacing: 20) {
                EmptyPanel(title: "工作区干净", symbol: "checkmark.circle", message: "没有未提交的改动。")
                EmptyPanel(title: "暂无提交", symbol: "clock.arrow.circlepath", message: "提交后在这里查看历史。")
                EmptyPanel(title: "暂无储藏", symbol: "archivebox", message: "保存改动后可以继续工作。")
            }.frame(height: 170)
            Divider()
            HStack {
                Toggle("界面动效", isOn: $preferences.interfaceMotion)
                    .accessibilityIdentifier("catalog-motion")
                Spacer()
                Button("舒适") { preferences.density = "comfortable" }
                Button("紧凑") { preferences.density = "compact" }
            }.font(.caption)
        }
        .padding(20).frame(width: 780, height: 700)
        .workbenchControlFamily().workbenchAppearance(preferences)
    }
}

@MainActor
private final class CatalogDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let domain = "org.weopen.WeGit.V111Catalog." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set("light", forKey: "appearance")
        defaults.set("zh-Hans", forKey: "language")
        defaults.set(false, forKey: "showMenuBar")
        defaults.set(false, forKey: "interfaceMotion")
        let preferences = AppPreferences(defaults: defaults)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 780, height: 700),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        #if V111_BASELINE
            window.title = "WeGit 组件基线"
        #else
            window.title = "WeGit v1.1.1 组件样册"
        #endif
        window.identifier = NSUserInterfaceItemIdentifier("catalog")
        window.contentView = NSHostingView(rootView: CatalogContent(preferences: preferences))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
private enum CatalogApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = CatalogDelegate()
        application.delegate = delegate
        application.run()
    }
}
