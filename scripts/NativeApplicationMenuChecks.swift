import AppKit
import WeGitCore

@MainActor private final class Validator: NSObject, NSMenuItemValidation {
    var accepts = true
    var actions: [Selector?] = []
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        actions.append(item.action)
        item.title = "Native cached title"
        return accepts
    }
}

@main struct NativeApplicationMenuChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var passed: [String] = []
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else {
                throw NSError(
                    domain: "WeGit.NativeApplicationMenu", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: name])
            }
            passed.append(name)
        }
        func settle(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
        let first = Validator()
        let second = Validator()
        var target: Validator? = first
        var enabled = false
        var selectedCommand: ApplicationMenuCommand = .history
        var performed: [ApplicationMenuCommand] = []
        var dispatched: [(Selector, AnyObject)] = []
        let controller = NativeApplicationMenu(
            perform: { performed.append($0) }, enabled: { _ in enabled },
            selected: { $0 == selectedCommand },
            target: { _, _ in target },
            send: { selector, object, _ in
                dispatched.append((selector, object))
                return true
            })
        func menu(_ name: String) -> NSMenu {
            controller.mainMenu.items.first { $0.identifier?.rawValue == "native-menu-" + name }!.submenu!
        }
        func item(_ command: ApplicationMenuCommand, in name: String) -> NSMenuItem {
            menu(name).items.first { $0.representedObject as? String == command.rawValue }!
        }
        L10n.language = .simplifiedChinese
        controller.start()
        let file = controller.mainMenu.items[1]
        let close = item(.close, in: "file")
        let copy = item(.copy, in: "edit")
        try check("Eight native top-level menus", controller.mainMenu.items.count == 8)
        try check("Chinese File and Close at startup", file.title == "文件" && close.title == "关闭")
        try check("Plain AppKit items without framework label cache", type(of: close) == NSMenuItem.self)
        L10n.language = .english
        settle { file.title == "File" }
        try check(
            "Language observation updates File without replacing tree",
            file === controller.mainMenu.items[1] && file.title == "File")
        try check(
            "Close text and AX title update together",
            close.title == "Close" && close.accessibilityTitle() == "Close")
        try check(
            "Copy text and AX title update together",
            copy.title == "Copy" && copy.accessibilityTitle() == "Copy")
        let commit = item(.commit, in: "repository")
        try check("Repository action reads current disabled state", !controller.validateMenuItem(commit))
        menu("repository").performActionForItem(at: menu("repository").index(of: commit))
        try check("Disabled action does not execute", performed.isEmpty)
        enabled = true
        try check("Repository action reads changed state", controller.validateMenuItem(commit))
        menu("repository").performActionForItem(at: menu("repository").index(of: commit))
        try check("Enabled action dispatches once", performed == [.commit])
        try check(
            "Commit shortcut preserved",
            commit.keyEquivalent == "\r" && commit.keyEquivalentModifierMask == .command)
        _ = controller.validateMenuItem(item(.history, in: "workspace"))
        try check("Current route has native checkmark", item(.history, in: "workspace").state == .on)
        let stashes = item(.stashes, in: "workspace")
        try check(
            "Stash route has a native Command-4 shortcut",
            stashes.keyEquivalent == "4" && stashes.keyEquivalentModifierMask == .command)
        try check("Stash native label follows live English language", stashes.title == "Stashes")
        selectedCommand = .stashes
        _ = controller.validateMenuItem(stashes)
        try check("Stash native item reflects the active route", stashes.state == .on)
        let tags = item(.tags, in: "workspace")
        try check(
            "Tag route has native Command-5 and live English label",
            tags.keyEquivalent == "5" && tags.keyEquivalentModifierMask == .command && tags.title == "Tags")
        selectedCommand = .tags
        _ = controller.validateMenuItem(tags)
        try check("Tag native item reflects the active route", tags.state == .on)
        try check(
            "Responder receives the original action for validation",
            controller.validateMenuItem(copy) && first.actions.last! == NSSelectorFromString("copy:"))
        try check("Native validation cannot overwrite translated label", copy.title == "Copy")
        first.accepts = false
        try check("Responder rejection disables menu action", !controller.validateMenuItem(copy))
        menu("edit").performActionForItem(at: menu("edit").index(of: copy))
        try check("Rejected responder action is not sent", dispatched.isEmpty)
        target = second
        menu("edit").performActionForItem(at: menu("edit").index(of: copy))
        try check(
            "Execution resolves the latest responder", dispatched.count == 1 && dispatched[0].1 === second)
        try check("Execution preserves Copy selector", dispatched[0].0 == NSSelectorFromString("copy:"))
        target = nil
        try check("Absent responder disables Copy", !controller.validateMenuItem(copy))
        controller.mainMenu.removeAllItems()
        controller.mainMenu.addItem(withTitle: "Framework replacement", action: nil, keyEquivalent: "")
        settle { controller.mainMenu.items.count == 8 }
        try check(
            "Scene mutation restores the authoritative root tree",
            controller.mainMenu.items.count == 8 && controller.mainMenu.items[1] === file)
        menu("edit").removeAllItems()
        menu("edit").addItem(withTitle: "Framework replacement", action: nil, keyEquivalent: "")
        settle { menu("edit").items.contains { $0 === copy } }
        try check("Scene mutation restores owned command items", menu("edit").items.contains { $0 === copy })
        L10n.language = .simplifiedChinese
        settle { file.title == "文件" }
        try check(
            "Reverse language change updates existing items",
            close.title == "关闭" && copy.accessibilityTitle() == "拷贝")
        L10n.language = .english
        settle { file.title == "File" }
        try check(
            "Repeated switch has no duplicate menus",
            controller.mainMenu.items.count == 8 && menu("file").items.filter { $0 === close }.count == 1)
        let injected = NSMenuItem(
            title: L10n.menuTitle("Fill", language: .simplifiedChinese), action: nil, keyEquivalent: "")
        let device = NSMenuItem(
            title: L10n.text("移到“", language: .simplifiedChinese) + "Fixture 中文🙂”", action: nil,
            keyEquivalent: "")
        let windowName = NSMenuItem(
            title: "Fill", action: #selector(NSWindow.makeKeyAndOrderFront(_:)), keyEquivalent: "")
        menu("window").addItem(injected)
        menu("window").addItem(device)
        menu("window").addItem(windowName)
        controller.menuWillOpen(menu("window"))
        try check("AppKit window action translates on opening", injected.title == "Fill")
        try check("Device name remains verbatim", device.title == "Move to “Fixture 中文🙂”")
        L10n.language = .simplifiedChinese
        settle { file.title == "文件" }
        controller.menuWillOpen(menu("window"))
        try check(
            "AppKit actions reverse their language",
            injected.title == L10n.menuTitle("Fill", language: .simplifiedChinese))
        try check("User window titles never translate", windowName.title == "Fill")
        let data = try JSONSerialization.data(
            withJSONObject: ["passed": true, "checks": passed], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("\(passed.count) native application menu checks passed.")
    }
}
