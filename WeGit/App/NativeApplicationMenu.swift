import AppKit
import Observation
import WeGitCore

enum ApplicationMenuCommand: String {
    case about, settings, hide, hideOthers, showAll, quit
    case openRepository, clone, switchRepository, close, closeAll
    case undo, redo, cut, copy, paste, pasteMatchingStyle, delete, selectAll, emojiSymbols
    case sidebar, inspector, fullScreen, minimize, minimizeAll, zoom, zoomAll, showMainWindow,
        bringAllToFront, help
    case switchBranch, refresh, newBranch, stageAll, unstageAll, commit, commitAndPush
    case pull, push, closeRepository, activity, terminal, xcode, copyPath, search, palette
    case changes, history, branches, stashes, tags, quickAccess
    #if DEBUG
        case recoverTrashFixture
    #endif

    var responderAction: Selector? {
        let name: String
        switch self {
        case .undo: name = "undo:"
        case .redo: name = "redo:"
        case .cut: name = "cut:"
        case .copy: name = "copy:"
        case .paste: name = "paste:"
        case .pasteMatchingStyle: name = "pasteAsPlainText:"
        case .delete: name = "delete:"
        case .selectAll: name = "selectAll:"
        case .close: name = "performClose:"
        case .fullScreen: name = "toggleFullScreen:"
        case .minimize: name = "performMiniaturize:"
        case .zoom: name = "performZoom:"
        default: return nil
        }
        return NSSelectorFromString(name)
    }
}

/// The menu owns plain AppKit items. SwiftUI scenes supply window-opening hooks
/// but never supply command items or cached labels to this tree.
@MainActor
final class NativeApplicationMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    let mainMenu = NSMenu()
    private let windowMenu = NSMenu()
    private let servicesMenu = NSMenu()
    private let helpMenu = NSMenu()
    private var labels: [(NSMenuItem, @MainActor () -> String)] = []
    private let performAppCommand: @MainActor (ApplicationMenuCommand) -> Void
    private let appCommandEnabled: @MainActor (ApplicationMenuCommand) -> Bool
    private let appCommandSelected: @MainActor (ApplicationMenuCommand) -> Bool
    private let dynamicTitle: @MainActor (ApplicationMenuCommand) -> String?
    private let preferredAppearance: @MainActor () -> NSAppearance
    private let targetForAction: @MainActor (Selector, NSMenuItem) -> AnyObject?
    private let sendAction: @MainActor (Selector, AnyObject, NSMenuItem) -> Bool
    private var mainMenuObservation: NSKeyValueObservation?
    private var scheduled = false
    private var started = false
    private var installing = false
    private var ownedTrees: [(NSMenu, [NSMenuItem])] = []
    var showMainWindow: @MainActor () -> Void = {}
    var showSettings: @MainActor () -> Void = {}

    init(
        perform: @escaping @MainActor (ApplicationMenuCommand) -> Void,
        enabled: @escaping @MainActor (ApplicationMenuCommand) -> Bool,
        selected: @escaping @MainActor (ApplicationMenuCommand) -> Bool = { _ in false },
        title: @escaping @MainActor (ApplicationMenuCommand) -> String? = { _ in nil },
        appearance: @escaping @MainActor () -> NSAppearance = { NSApp.effectiveAppearance },
        target: @escaping @MainActor (Selector, NSMenuItem) -> AnyObject? = {
            NSApp.target(forAction: $0, to: nil, from: $1) as AnyObject?
        },
        send: @escaping @MainActor (Selector, AnyObject, NSMenuItem) -> Bool = {
            NSApp.sendAction($0, to: $1, from: $2)
        }
    ) {
        performAppCommand = perform
        appCommandEnabled = enabled
        appCommandSelected = selected
        dynamicTitle = title
        preferredAppearance = appearance
        targetForAction = target
        sendAction = send
        super.init()
        build()
        ownedTrees =
            [(mainMenu, mainMenu.items)]
            + mainMenu.items.compactMap { item in
                guard let submenu = item.submenu else { return nil }
                return (submenu, submenu.items)
            }
    }

    func start() {
        guard !started else { return }
        started = true
        // Scene activation can install a framework menu even with commandsRemoved.
        // Keep one authoritative tree, rather than editing framework-owned items.
        mainMenuObservation = NSApp.observe(\.mainMenu, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleInstall() }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowChanged), name: name, object: nil)
        }
        for name in [
            NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification, NSMenu.didChangeItemNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(menuChanged), name: name, object: nil)
        }
        observeLanguage()
    }

    private func observeLanguage() {
        withObservationTracking {
            _ = L10n.language
            refreshLabels()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLanguage() }
        }
        install()
    }

    @objc private func windowChanged(_ notification: Notification) { scheduleInstall() }

    @objc private func menuChanged(_ notification: Notification) {
        guard !installing, let changed = notification.object as? NSMenu,
            ownedTrees.contains(where: { $0.0 === changed })
        else { return }
        scheduleInstall()
    }

    private var needsRepair: Bool {
        if NSApp.mainMenu !== mainMenu { return true }
        return ownedTrees.contains { menu, items in
            if menu === windowMenu || menu === helpMenu {
                return items.contains { expected in !menu.items.contains { $0 === expected } }
            }
            return menu.items.count != items.count || zip(menu.items, items).contains { $0 !== $1 }
        }
    }

    private func scheduleInstall() {
        guard needsRepair, !scheduled else {
            updateSettingsWindowTitle()
            return
        }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.install()
        }
    }

    private func install() {
        guard !installing else { return }
        installing = true
        defer { installing = false }
        for (menu, items) in ownedTrees {
            if menu === windowMenu || menu === helpMenu {
                for (index, item) in items.enumerated() where !menu.items.contains(where: { $0 === item }) {
                    menu.insertItem(item, at: min(index, menu.items.count))
                }
            } else if menu.items.count != items.count || zip(menu.items, items).contains(where: { $0 !== $1 })
            {
                menu.removeAllItems()
                for item in items { menu.addItem(item) }
            }
        }
        refreshLabels()
        if NSApp.mainMenu !== mainMenu { NSApp.mainMenu = mainMenu }
        if NSApp.windowsMenu !== windowMenu { NSApp.windowsMenu = windowMenu }
        if NSApp.servicesMenu !== servicesMenu { NSApp.servicesMenu = servicesMenu }
        if NSApp.helpMenu !== helpMenu { NSApp.helpMenu = helpMenu }
        updateSettingsWindowTitle()
    }

    private func updateSettingsWindowTitle() {
        for window in NSApp.windows
        where window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
            let title = L10n.text("WeGit 设置")
            if window.title != title { window.title = title }
        }
    }

    func refreshLabels() {
        for (item, title) in labels {
            item.title = title()
            if let submenu = item.submenu { submenu.title = item.title }
        }
        updateSettingsWindowTitle()
    }

    private func menu(
        _ identifier: String, _ title: @escaping @MainActor () -> String, content: NSMenu? = nil
    ) -> NSMenu {
        let item = NSMenuItem(title: title(), action: nil, keyEquivalent: "")
        item.identifier = .init("native-menu-" + identifier)
        let menu = content ?? NSMenu()
        menu.title = title()
        menu.delegate = self
        item.submenu = menu
        mainMenu.addItem(item)
        labels.append((item, title))
        return menu
    }

    private func add(
        _ command: ApplicationMenuCommand, to menu: NSMenu, key: String = "",
        modifiers: NSEvent.ModifierFlags = .command, alternate: Bool = false,
        title: @escaping @MainActor () -> String
    ) {
        let item = NSMenuItem(title: title(), action: #selector(execute), keyEquivalent: key)
        item.target = self
        item.isAlternate = alternate
        item.identifier = .init("native-command-" + command.rawValue)
        item.representedObject = command.rawValue
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
        labels.append(
            (
                item,
                { [weak self] in
                    if command == .fullScreen {
                        return L10n.menuTitle(
                            NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
                                ? "Exit Full Screen" : "Enter Full Screen")
                    }
                    return self?.dynamicTitle(command) ?? title()
                }
            ))
    }

    private func build() {
        let application = menu("app", { "WeGit" })
        add(.about, to: application) { L10n.menuTitle("About WeGit") }
        application.addItem(.separator())
        add(.settings, to: application, key: ",") { L10n.menuTitle("Settings…") }
        application.addItem(.separator())
        let services = NSMenuItem(title: L10n.menuTitle("Services"), action: nil, keyEquivalent: "")
        services.submenu = servicesMenu
        application.addItem(services)
        labels.append((services, { L10n.menuTitle("Services") }))
        application.addItem(.separator())
        add(.hide, to: application, key: "h") { L10n.menuTitle("Hide WeGit") }
        add(.hideOthers, to: application, key: "h", modifiers: [.command, .option]) {
            L10n.menuTitle("Hide Others")
        }
        add(.showAll, to: application) { L10n.menuTitle("Show All") }
        application.addItem(.separator())
        add(.quit, to: application, key: "q") { L10n.menuTitle("Quit WeGit") }

        let file = menu("file", { L10n.menuTitle("File") })
        add(.openRepository, to: file, key: "o") { L10n.text("打开仓库…") }
        add(.clone, to: file, key: "o", modifiers: [.command, .shift]) { L10n.text("克隆仓库…") }
        add(.switchRepository, to: file, key: "k") { L10n.text("切换仓库…") }
        file.addItem(.separator())
        add(.close, to: file, key: "w") { L10n.menuTitle("Close") }
        add(.closeAll, to: file, key: "w", modifiers: [.command, .option]) { L10n.menuTitle("Close All") }

        let edit = menu("edit", { L10n.menuTitle("Edit") })
        add(.undo, to: edit, key: "z") { L10n.menuTitle("Undo") }
        add(.redo, to: edit, key: "z", modifiers: [.command, .shift]) { L10n.menuTitle("Redo") }
        edit.addItem(.separator())
        add(.cut, to: edit, key: "x") { L10n.menuTitle("Cut") }
        add(.copy, to: edit, key: "c") { L10n.menuTitle("Copy") }
        add(.paste, to: edit, key: "v") { L10n.menuTitle("Paste") }
        add(.pasteMatchingStyle, to: edit, key: "v", modifiers: [.command, .option, .shift]) {
            L10n.menuTitle("Paste and Match Style")
        }
        add(.delete, to: edit) { L10n.menuTitle("Delete") }
        add(.selectAll, to: edit, key: "a") { L10n.menuTitle("Select All") }

        edit.addItem(.separator())
        add(.emojiSymbols, to: edit, key: " ", modifiers: [.command, .control]) {
            L10n.menuTitle("Emoji & Symbols")
        }

        let view = menu("view", { L10n.menuTitle("View") })
        add(.sidebar, to: view, key: "s", modifiers: [.command, .control]) { L10n.menuTitle("Show Sidebar") }
        add(.inspector, to: view) { L10n.menuTitle("Show Inspector") }
        view.addItem(.separator())
        add(.fullScreen, to: view, key: "f", modifiers: [.command, .control]) {
            L10n.menuTitle("Enter Full Screen")
        }

        let repository = menu("repository", { L10n.text("仓库") })
        add(.switchBranch, to: repository) { L10n.text("切换分支…") }
        add(.refresh, to: repository, key: "r") { L10n.text("刷新") }
        add(.newBranch, to: repository, key: "n", modifiers: [.command, .shift]) { L10n.text("新建分支…") }
        repository.addItem(.separator())
        add(.stageAll, to: repository) { L10n.text("暂存全部") }
        add(.unstageAll, to: repository) { L10n.text("取消全部暂存") }
        add(.commit, to: repository, key: "\r") { L10n.text("提交") }
        add(.commitAndPush, to: repository) { L10n.text("提交并推送…") }
        repository.addItem(.separator())
        add(.pull, to: repository, key: "l", modifiers: [.command, .shift]) { L10n.text("拉取…") }
        add(.push, to: repository, key: "u", modifiers: [.command, .shift]) { L10n.text("推送…") }
        add(.closeRepository, to: repository) { L10n.text("关闭仓库") }
        add(.activity, to: repository) { L10n.text("活动记录") }
        add(.terminal, to: repository) { L10n.text("在 Terminal 中打开") }
        add(.xcode, to: repository) { L10n.text("在 Xcode 中打开…") }
        add(.copyPath, to: repository) { L10n.text("复制仓库路径") }
        add(.search, to: repository, key: "f", modifiers: [.command, .shift]) { L10n.text("搜索当前仓库…") }
        add(.palette, to: repository, key: "p", modifiers: [.command, .shift]) { L10n.text("命令面板…") }

        let workspace = menu("workspace", { L10n.text("工作区") })
        #if DEBUG
            add(.recoverTrashFixture, to: workspace) { L10n.text("核对并恢复回收夹具") }
        #endif
        add(.changes, to: workspace, key: "1") { L10n.text("更改") }
        add(.history, to: workspace, key: "2") { L10n.text("提交历史") }
        add(.branches, to: workspace, key: "3") { L10n.text("分支") }
        add(.stashes, to: workspace, key: "4") { L10n.text("暂存记录") }
        add(.tags, to: workspace, key: "5") { L10n.text("标签") }
        workspace.addItem(.separator())
        add(.quickAccess, to: workspace, key: "m", modifiers: [.command, .shift]) { L10n.text("菜单栏快捷面板") }

        let window = menu("window", { L10n.menuTitle("Window") }, content: windowMenu)
        add(.minimize, to: window, key: "m") { L10n.menuTitle("Minimize") }
        add(.minimizeAll, to: window, key: "m", modifiers: [.command, .option], alternate: true) {
            L10n.menuTitle("Minimize All")
        }
        add(.zoom, to: window) { L10n.menuTitle("Zoom") }
        add(.zoomAll, to: window, modifiers: .option, alternate: true) { L10n.menuTitle("Zoom All") }
        window.addItem(.separator())
        add(.showMainWindow, to: window) { L10n.text("显示 WeGit 主窗口") }
        add(.bringAllToFront, to: window) { L10n.menuTitle("Bring All to Front") }
        let help = menu("help", { L10n.menuTitle("Help") }, content: helpMenu)
        add(.help, to: help) { L10n.menuTitle("WeGit Help") }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshLabels()
        if menu === windowMenu { refreshWindowList() }
        for item in menu.items where item.target === self {
            item.isEnabled = validateMenuItem(item)
            #if DEBUG
                if item.representedObject as? String == ApplicationMenuCommand.recoverTrashFixture.rawValue {
                    item.isHidden = !item.isEnabled
                }
            #endif
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === windowMenu || menu === helpMenu { localizeSystemItems(menu) }
    }

    private func refreshWindowList() {
        for item in windowMenu.items where item.identifier?.rawValue.hasPrefix("native-window-") == true {
            windowMenu.removeItem(item)
        }
        let windows = NSApp.windows.filter {
            $0.isVisible && $0.styleMask.contains(.titled) && $0.styleMask.contains(.closable)
                && $0.sheetParent == nil && !$0.isModalPanel
        }
        let missing = windows.filter { window in
            !windowMenu.items.contains {
                $0.target === window && $0.action == #selector(NSWindow.makeKeyAndOrderFront(_:))
            }
        }
        guard !missing.isEmpty else { return }
        let divider = NSMenuItem.separator()
        divider.identifier = .init("native-window-divider")
        windowMenu.addItem(divider)
        for (index, window) in missing.enumerated() {
            let item = NSMenuItem(
                title: window.title, action: #selector(NSWindow.makeKeyAndOrderFront(_:)), keyEquivalent: "")
            item.identifier = .init("native-window-" + String(index))
            item.target = window
            item.state = window.isKeyWindow ? .on : .off
            windowMenu.addItem(item)
        }
    }

    /// AppKit inserts window tiling and Help search controls after menu validation.
    /// These are native items, outside SwiftUI's cached command model.
    private func localizeSystemItems(_ menu: NSMenu) {
        var translations: [String: String] = [:]
        for key in Self.systemTitles {
            translations[key] = L10n.menuTitle(key)
            translations[L10n.menuTitle(key, language: .simplifiedChinese)] = L10n.menuTitle(key)
        }
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if item.action == #selector(NSWindow.makeKeyAndOrderFront(_:)) { continue }
                if let title = translations[item.title], item.title != title { item.title = title }
                for prefix in [
                    L10n.text("移到“", language: .simplifiedChinese), L10n.text("移到“", language: .english),
                ]
                where item.title.hasPrefix(prefix) && item.title.hasSuffix("”") {
                    let device = String(item.title.dropFirst(prefix.count).dropLast())
                    let title = L10n.text("移到“\(device)”")
                    if item.title != title { item.title = title }
                }
                func searchFields(_ view: NSView) {
                    if let field = view as? NSSearchField {
                        field.placeholderString = L10n.menuTitle("Search")
                        field.setAccessibilityLabel(L10n.menuTitle("Search"))
                    }
                    for child in view.subviews { searchFields(child) }
                }
                if let view = item.view { searchFields(view) }
                if let child = item.submenu { visit(child) }
            }
        }
        visit(menu)
    }

    private static let systemTitles = [
        "Fill", "Center", "Move & Resize", "Full Screen Tile", "Halves", "Left", "Right", "Top", "Bottom",
        "Quarters", "Top Left", "Top Right", "Bottom Left", "Bottom Right", "Arrange", "Left & Right",
        "Left & Quarters", "Right & Left", "Right & Quarters", "Top & Bottom", "Top & Quarters",
        "Bottom & Top", "Bottom & Quarters", "Return to Previous Size", "Left of Screen", "Right of Screen",
        "Remove Window from Set", "Minimize All", "Zoom All", "Arrange in Front",
    ]

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let raw = item.representedObject as? String, let command = ApplicationMenuCommand(rawValue: raw)
        else { return false }
        item.state = appCommandSelected(command) ? .on : .off
        if let selector = command.responderAction {
            guard let target = targetForAction(selector, item) else { return false }
            // A responder may change the validation item's title (Undo Typing,
            // Close Window, etc.). Keep that separate from our translated item.
            let probe = NSMenuItem(title: item.title, action: selector, keyEquivalent: item.keyEquivalent)
            if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(probe) }
            if let validator = target as? NSUserInterfaceValidations {
                return validator.validateUserInterfaceItem(probe)
            }
            return true
        }
        switch command {
        case .about, .settings, .hide, .hideOthers, .showAll, .quit, .showMainWindow, .bringAllToFront, .help,
            .emojiSymbols:
            return true
        case .minimizeAll:
            return NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.miniaturizable) }
        case .zoomAll: return NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.resizable) }
        case .closeAll: return NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.closable) }
        default: return appCommandEnabled(command)
        }
    }

    @objc private func execute(_ item: NSMenuItem) {
        guard validateMenuItem(item), let raw = item.representedObject as? String,
            let command = ApplicationMenuCommand(rawValue: raw)
        else { return }
        if let selector = command.responderAction, let target = targetForAction(selector, item) {
            _ = sendAction(selector, target, item)
            return
        }
        switch command {
        case .about:
            let alert = NSAlert()
            alert.alertStyle = .informational
            AppPresentation.configure(alert, appearance: preferredAppearance())
            alert.messageText = "WeGit"
            alert.informativeText = L10n.text(
                "版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") · MIT")
            alert.addButton(withTitle: L10n.text("好"))
            alert.window.title = L10n.menuTitle("About WeGit")
            alert.runModal()
        case .emojiSymbols: NSApp.orderFrontCharacterPalette(item)
        case .minimizeAll:
            for window in NSApp.windows where window.isVisible && window.styleMask.contains(.miniaturizable) {
                window.performMiniaturize(item)
            }
        case .zoomAll:
            for window in NSApp.windows where window.isVisible && window.styleMask.contains(.resizable) {
                window.performZoom(item)
            }
        case .settings: showSettings()
        case .hide: NSApp.hide(item)
        case .hideOthers: NSApp.hideOtherApplications(item)
        case .showAll: NSApp.unhideAllApplications(item)
        case .quit: NSApp.terminate(item)
        case .showMainWindow: showMainWindow()
        case .bringAllToFront: NSApp.arrangeInFront(item)
        case .closeAll:
            for window in NSApp.windows
            where window.isVisible && window.styleMask.contains(.closable) && window.sheetParent == nil {
                window.performClose(item)
            }
        case .help: NSWorkspace.shared.open(URL(string: "https://github.com/WeOpen/WeGit#readme")!)
        default:
            if ![.copyPath, .refresh, .quickAccess].contains(command) { showMainWindow() }
            performAppCommand(command)
        }
    }
}
