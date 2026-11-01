import AppKit
import Observation
import SwiftUI
import WeGitCore

@Observable @MainActor final class PreviewModel {
    let domain = "com.willxue.wegit.StashPreview." + UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appending(
        path: "WeGitStashPreview-" + UUID().uuidString)
    let preferences: AppPreferences
    var service: RepositoryService?
    var status = RepositoryStatus()
    var refreshID = UUID()
    var busy = false
    var notice = "Private repository fixture"
    init() {
        preferences = AppPreferences(defaults: UserDefaults(suiteName: domain)!)
        preferences.appearance = "light"
        preferences.language = .simplifiedChinese
    }
    func start() async {
        guard service == nil else { return }
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["GIT_CONFIG_SYSTEM"] = "/dev/null"
            let engine = GitEngine(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: env)
            _ = try await engine.run(["init", "-b", "main"], in: root)
            for (key, value) in [
                ("user.name", "Stash Preview"), ("user.email", "preview@example.invalid"),
                ("commit.gpgsign", "false"), ("core.hooksPath", root.appending(path: "no-hooks").path),
            ] {
                _ = try await engine.run(["config", key, value], in: root)
            }
            try Data("let value = 1\n".utf8).write(to: root.appending(path: "Feature.swift"))
            try Data("# Private fixture\n".utf8).write(to: root.appending(path: "README.md"))
            _ = try await engine.run(["add", "."], in: root)
            _ = try await engine.run(["commit", "-m", "Fixture base"], in: root)
            try Data("let value = 2\n".utf8).write(to: root.appending(path: "Feature.swift"))
            _ = try await engine.run(["add", "Feature.swift"], in: root)
            try Data("let value = 3\n".utf8).write(to: root.appending(path: "Feature.swift"))
            try Data("# Private fixture\nUpdated documentation\n".utf8).write(
                to: root.appending(path: "README.md"))
            try Data("New file with brackets\n".utf8).write(to: root.appending(path: "New [1].txt"))
            let location = try await RepositoryService.discover(root, engine: engine)
            service = RepositoryService(location: location, engine: engine)
            await refresh()
            try root.path.write(
                to: Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "preview-root.txt"),
                atomically: true, encoding: .utf8)
        } catch { notice = error.localizedDescription }
    }
    func refresh() async {
        guard let service else { return }
        do {
            status = try await service.status()
            refreshID = UUID()
        } catch { notice = error.localizedDescription }
    }
    func perform(_ name: String, operation: @escaping @Sendable (RepositoryService) async throws -> String?) {
        guard !busy, let service else { return }
        busy = true
        notice = name
        Task {
            do { notice = try await operation(service) ?? "Done" } catch {
                notice = error.localizedDescription
            }
            await refresh()
            busy = false
        }
    }
    func cleanTracked() {
        guard !busy, let service else { return }
        busy = true
        Task {
            do { _ = try await service.engine.run(["reset", "--hard", "HEAD"], in: root) } catch {
                notice = error.localizedDescription
            }
            await refresh()
            busy = false
        }
    }
    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        if let own = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: own)
        }
    }
}
struct PreviewDetail: View {
    let service: RepositoryService
    let contents: StashContents
    let part: StashPart
    @State private var text = ""
    private var pair: (GitCommit, String?) {
        switch part {
        case .working: (contents.working, contents.index.id)
        case .index: (contents.index, contents.base)
        case .untracked: (contents.untracked ?? contents.working, nil)
        }
    }
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: "\(pair.0.id):\(part.rawValue)") {
                do {
                    let comparison = try await service.commitComparison(id: pair.0.id, parent: pair.1)
                    var blocks: [String] = []
                    for file in comparison.files {
                        if case .loaded(let diff) = try await service.readCommitFile(
                            file, comparison: comparison)
                        {
                            blocks.append(String(decoding: diff.raw, as: UTF8.self))
                        }
                    }
                    if !Task.isCancelled {
                        text = blocks.isEmpty ? "此部分没有文件变化" : blocks.joined(separator: "\n")
                    }
                } catch { if !Task.isCancelled { text = error.localizedDescription } }
            }
    }
}
struct PreviewRoot: View {
    @Bindable var model: PreviewModel
    var body: some View {
        VStack(spacing: 0) {
            if let service = model.service {
                StashBrowser(
                    service: service, status: model.status, canWrite: !model.busy,
                    writeReason: "Private preview busy", refreshID: model.refreshID,
                    perform: { name, operation in model.perform(name, operation: operation) },
                    showChanges: { model.notice = "Conflicts can be handled in product Changes view" }
                ) { contents, part in
                    PreviewDetail(service: service, contents: contents, part: part)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(model.notice).font(.caption)
                Spacer()
                Text("工作区 \(model.status.files.count) 项")
                Button("仅清理夹具已跟踪改动") { model.cleanTracked() }.disabled(model.busy)
                Button("刷新夹具") { Task { await model.refresh() } }
            }.padding(10)
        }.task { await model.start() }
            .toolbar {
                ToolbarItemGroup {
                    Text("Stash · 私有原生组件预览")
                    Button("浅色") { model.preferences.appearance = "light" }
                    Button("深色") { model.preferences.appearance = "dark" }
                    Button("English") { model.preferences.language = .english }
                    Button("中文") { model.preferences.language = .simplifiedChinese }
                }
            }
    }
}
@MainActor final class PreviewDriver: NSObject, NSApplicationDelegate {
    var cleanup: () -> Void = {}
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { cleanup() }
}
@main struct StashPreview: App {
    @State private var model = PreviewModel()
    @NSApplicationDelegateAdaptor(PreviewDriver.self) private var driver
    var body: some Scene {
        Window("Stash Preview", id: "stash-preview") {
            PreviewRoot(model: model).workbenchAppearance(model.preferences)
                .task { driver.cleanup = { model.cleanup() } }
        }.defaultSize(width: 1320, height: 740).defaultLaunchBehavior(.presented)
    }
}
