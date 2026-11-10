import AppKit
import Observation
import SwiftUI
import WeGitCore

/// One store and one update operation belong to the application, across all workspaces.
@Observable @MainActor final class ApplicationDeliveryServices {
    let shortcuts: KeyboardShortcutPersistence?
    let shortcutError: String?
    let updates: UpdateState?
    let updateError: String?
    private(set) var shortcutRevision = 0
    @ObservationIgnored private var updateWindow: NSWindowController?
    @ObservationIgnored private(set) var updateBridge: UpdateApplicationBridge?

    init(defaults: UserDefaults) {
        do {
            shortcuts = try KeyboardShortcutPersistence(
                defaults: defaults, catalog: ApplicationShortcutCatalog.commands)
            shortcutError = nil
        } catch {
            shortcuts = nil
            shortcutError = error.localizedDescription
        }
        do {
            let info = Bundle.main.infoDictionary ?? [:]
            guard
                let version = (info["WeGitReleaseVersion"] ?? info["CFBundleShortVersionString"]) as? String,
                let buildText = info["CFBundleVersion"] as? String, let build = UInt64(buildText)
            else { throw UpdateFailure.configurationMissing }
            let variant = UpdateVariant(rawValue: info["WeGitDistributionVariant"] as? String ?? "universal")
            guard let variant else { throw UpdateFailure.configurationMissing }
            let installed = try InstalledUpdateVersion(version: version, build: build, variant: variant)
            let ring =
                UpdateTrustConfiguration.isConfigured ? try UpdateTrustConfiguration.productionRing() : nil
            updates = UpdateState(installed: installed, ring: ring, retentionTarget: Bundle.main.bundleURL)
            updateError = nil
        } catch {
            updates = nil
            updateError = error.localizedDescription
        }
    }

    func shortcutOverride(for command: ApplicationMenuCommand) -> KeyboardShortcutOverride? {
        guard let shortcuts, shortcuts.catalog.contains(where: { $0.id == command.rawValue }) else {
            return nil
        }
        return KeyboardShortcutOverride(binding: shortcuts.binding(for: command.rawValue))
    }

    func shortcutsChanged() {
        shortcutRevision += 1
        NotificationCenter.default.post(name: .applicationShortcutsChanged, object: self)
    }

    func configureUpdates(app: AppState) {
        guard updateBridge == nil, Bundle.main.bundleIdentifier == "com.willxue.wegit",
            FileManager.default.isExecutableFile(
                atPath: Bundle.main.bundleURL.appending(path: "Contents/Helpers/WeGitUpdater").path)
        else { return }
        let bridge = UpdateApplicationBridge(app: app)
        updateBridge = bridge
        updates?.configureInstaller { [weak bridge] request in
            guard let bridge else { throw UpdateFailure.configurationMissing }
            try await bridge.install(request)
        }
    }

    func showUpdates(preferences: AppPreferences) {
        if let updateWindow {
            updateWindow.window?.title = L10n.text("软件更新")
            updateWindow.showWindow(nil)
            updateWindow.window?.makeKeyAndOrderFront(nil)
            return
        }
        let content = Group {
            if let updates {
                UpdateView(state: updates) { [weak self] in self?.updateWindow?.close() }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L10n.text("软件更新")).font(.title2.weight(.semibold))
                    Text(verbatim: updateError ?? UpdateFailure.configurationMissing.localizedDescription)
                        .textSelection(.enabled)
                    Link(L10n.text("官网下载"), destination: URL(string: "https://wegit.willxue.com/")!)
                }.padding(24).frame(width: 540)
            }
        }.workbenchControlFamily().workbenchAppearance(preferences)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.setAccessibilityIdentifier("update-window")
        window.styleMask = [.titled, .closable]
        window.title = L10n.text("软件更新")
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        updateWindow = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
