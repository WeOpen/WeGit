import AppKit
import Observation
import SwiftUI
import WeGitCore

@Observable @MainActor final class AppState {
    let preferences: AppPreferences
    var sidebarVisible = true
    var lastAction = "No action"
    func presentSync(_ kind: Kind) { lastAction = kind == .push ? "Push invoked" : "Pull invoked" }
    enum Kind { case pull, push }
    var windowContentWidth: CGFloat = 1000
    let savesWindowState = false
    let nativeWindowStateName = "WeGitToolbarSurfacesProbe"
    let nativeSplitStatePrefix = "WeGitToolbarSurfacesProbe"
    let domain: String
    init() {
        domain = "com.willxue.wegit.ToolbarSurfacesProbe." + UUID().uuidString
        preferences = AppPreferences(defaults: UserDefaults(suiteName: domain)!)
        preferences.appearance = "light"
        preferences.language = .simplifiedChinese
    }
}
@MainActor final class Driver: NSObject, NSApplicationDelegate {
    var cleanup: () -> Void = {}
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { cleanup() }
}
@Observable @MainActor final class RepositorySession {
    var status = {
        var value = RepositoryStatus()
        value.branch = "main"
        value.head = "fixture"
        value.upstream = "origin/main"
        value.ahead = 12
        value.behind = 3
        return value
    }()
    var hasLoaded = true
    var isStale = false
    var canWrite = true
    var canSync = true
    var remotes = ["origin"]
    var syncReason = "选择远端、目标分支和同步方式"
    func perform(_ title: String, operation: @escaping (RepositoryService) async throws -> Void) {}
}
struct ProbeRoot: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @State private var session = RepositorySession()
    @State private var visibility: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List {
                Section("工作区") {
                    Label("更改", systemImage: "square.and.pencil")
                    Label("提交历史", systemImage: "clock")
                    Label("分支", systemImage: "arrow.triangle.branch")
                }
                Section("仓库") { Label("Private fixture", systemImage: "folder") }
            }.listStyle(.sidebar).scrollContentBackground(.hidden).background(colors.sidebar)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("更改").font(.headline).padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(colors.chrome)
                    Divider()
                    List {
                        Section("未暂存 (2)") {
                            Label("WorkspaceToolbar.swift", systemImage: "doc")
                            Label("AppColors.swift", systemImage: "doc")
                        }
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden).background(colors.surface)
                }.frame(width: 280).background(colors.canvas)
                VStack(alignment: .leading, spacing: 0) {
                    Text("WorkspaceToolbar.swift").font(.headline).padding().frame(
                        maxWidth: .infinity, alignment: .leading
                    ).background(colors.chrome)
                    Divider()
                    Text(
                        "  1  import SwiftUI\n  2  import WeGitCore\n  3  \n  4  struct RepositorySyncButtons: View {"
                    ).font(.system(size: 13, design: .monospaced)).padding(.vertical)
                    Text("  5      // upstream: origin/main").font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(colors.positive).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4).background(colors.diffAdded)
                    Spacer()
                    Text("Private native preview · product toolbar / palette / inspector form").font(.caption)
                        .foregroundStyle(colors.secondaryText).padding()
                }.frame(minWidth: 410, maxWidth: .infinity, maxHeight: .infinity).background(colors.surface)
                ThemedForm(backgroundRole: .sidebar) {
                    Section("仓库") {
                        LabeledContent("名称", value: "Private fixture")
                        LabeledContent("上游", value: "origin/main")
                        LabeledContent("领先 / 落后", value: "12 / 3")
                    }
                    Section("预览设置") {
                        Button("浅色") { app.preferences.appearance = "light" }
                        Button("深色") { app.preferences.appearance = "dark" }
                        Button("未知计数") {
                            session.status.ahead = nil
                            session.status.behind = nil
                        }
                        Button("已同步") {
                            session.status.ahead = 0
                            session.status.behind = 0
                        }
                        Button("领先 / 落后") {
                            session.status.ahead = 12
                            session.status.behind = 3
                            session.isStale = false
                        }
                        Button("状态过期") { session.isStale = true }
                        Button("禁用同步") { session.canSync.toggle() }
                        Text(app.lastAction)
                    }
                }.frame(width: 250)
            }.background(colors.border)
        }
        .navigationTitle("Private fixture")
        .background(
            WindowStateBridge(
                app: app, sidebarVisible: visibility != .detailOnly,
                toggleSidebar: {
                    visibility = visibility == .detailOnly ? .all : .detailOnly
                }
            ).frame(width: 0, height: 0).accessibilityHidden(true)
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("仓库", systemImage: "folder.badge.gearshape") {}.workbenchIconButton(toolbar: true)
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("main") {}
                } label: {
                    Label("main · origin/main", systemImage: "arrow.triangle.branch")
                }.workbenchGlassMenu(toolbar: true)
                RepositoryFetchMenu(session: session, inToolbar: true).labelStyle(.titleAndIcon)
                RepositorySyncButtons(app: app, session: session, inToolbar: true).labelStyle(.titleAndIcon)
                Button("刷新", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {}.workbenchIconButton(
                    toolbar: true)
                Button("搜索", systemImage: "magnifyingglass") {}.workbenchIconButton(toolbar: true)
                Button("检查器", systemImage: "sidebar.right") {}.workbenchIconButton(toolbar: true)
                Menu {
                    RepositoryFetchMenu(session: session)
                    Divider()
                    RepositorySyncButtons(app: app, session: session)
                } label: {
                    Label("更多", systemImage: "ellipsis")
                }.workbenchGlassMenu(icon: true, toolbar: true)
            }.sharedBackgroundVisibility(.hidden)
        }
    }
}
@main struct Probe: App {
    @State private var state = AppState()
    @NSApplicationDelegateAdaptor(Driver.self) private var driver
    var body: some Scene {
        Window("Toolbar Surfaces Probe", id: "probe-main") {
            ProbeRoot(app: state).workbenchAppearance(state.preferences).task {
                driver.cleanup = {
                    UserDefaults(suiteName: state.domain)?.removePersistentDomain(forName: state.domain)
                    if let domain = Bundle.main.bundleIdentifier {
                        UserDefaults.standard.removePersistentDomain(forName: domain)
                    }
                }
            }
        }.defaultSize(width: 1420, height: 720).defaultLaunchBehavior(.presented)
    }
}
