import AppKit
import WeGitCore

extension Notification.Name {
    static let applicationShortcutsChanged = Notification.Name("WeGit.ApplicationShortcutsChanged")
}

extension KeyboardShortcutBinding {
    init(event: NSEvent) {
        var modifiers = KeyboardShortcutModifiers()
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        self.init(
            key: event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? "",
            modifiers: modifiers)
    }

    var nativeModifiers: NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }
}

/// Only app commands are customizable. Responder and macOS commands stay owned by AppKit.
enum ApplicationShortcutCatalog {
    static var commands: [KeyboardShortcutCommand] {
        func command(
            _ id: ApplicationMenuCommand, _ title: String, key: String? = nil,
            modifiers: KeyboardShortcutModifiers = .command
        ) -> KeyboardShortcutCommand {
            KeyboardShortcutCommand(
                id: id.rawValue, title: title,
                defaultBinding: key.map { KeyboardShortcutBinding(key: $0, modifiers: modifiers) })
        }
        return [
            command(.newWindow, L10n.key("新建窗口", language: .simplifiedChinese), key: "n"),
            command(.openInNewWindow, L10n.key("在新窗口中打开", language: .simplifiedChinese)),
            command(
                .reopenWindow, L10n.key("重新打开关闭的窗口", language: .simplifiedChinese), key: "t",
                modifiers: [.command, .shift]),
            command(.openRepository, L10n.key("打开仓库…", language: .simplifiedChinese), key: "o"),
            command(.initializeRepository, L10n.key("新建仓库…", language: .simplifiedChinese)),
            command(
                .clone, L10n.key("克隆仓库…", language: .simplifiedChinese), key: "o",
                modifiers: [.command, .shift]),
            command(.switchRepository, L10n.key("切换仓库…", language: .simplifiedChinese), key: "k"),
            command(.importPatch, L10n.key("导入文件补丁…", language: .simplifiedChinese)),
            command(.importMailPatches, L10n.key("导入提交补丁…", language: .simplifiedChinese)),
            command(.exportWorkingPatch, L10n.key("导出未暂存补丁…", language: .simplifiedChinese)),
            command(.exportStagedPatch, L10n.key("导出暂存补丁…", language: .simplifiedChinese)),
            command(
                .sidebar, L10n.key("显示侧边栏", language: .simplifiedChinese), key: "s",
                modifiers: [.command, .control]),
            command(.inspector, L10n.key("显示检查器", language: .simplifiedChinese)),
            command(.switchBranch, L10n.key("切换分支…", language: .simplifiedChinese)),
            command(.refresh, L10n.key("刷新", language: .simplifiedChinese), key: "r"),
            command(
                .newBranch, L10n.key("新建分支…", language: .simplifiedChinese), key: "n",
                modifiers: [.command, .shift]),
            command(.stageAll, L10n.key("暂存全部", language: .simplifiedChinese)),
            command(.unstageAll, L10n.key("取消全部暂存", language: .simplifiedChinese)),
            command(.commit, L10n.key("提交", language: .simplifiedChinese), key: "\r"),
            command(.commitAndPush, L10n.key("提交并推送…", language: .simplifiedChinese)),
            command(
                .pull, L10n.key("拉取…", language: .simplifiedChinese), key: "l", modifiers: [.command, .shift]),
            command(
                .push, L10n.key("推送…", language: .simplifiedChinese), key: "u", modifiers: [.command, .shift]),
            command(.historyDepth, L10n.key("历史深度…", language: .simplifiedChinese)),
            command(.compareReferences, L10n.key("比较对象…", language: .simplifiedChinese)),
            command(.closeRepository, L10n.key("关闭仓库", language: .simplifiedChinese)),
            command(.activity, L10n.key("活动记录", language: .simplifiedChinese)),
            command(.terminal, L10n.key("在 Terminal 中打开", language: .simplifiedChinese)),
            command(.xcode, L10n.key("在 Xcode 中打开…", language: .simplifiedChinese)),
            command(.copyPath, L10n.key("复制仓库路径", language: .simplifiedChinese)),
            command(
                .search, L10n.key("搜索当前仓库…", language: .simplifiedChinese), key: "f",
                modifiers: [.command, .shift]),
            command(
                .palette, L10n.key("命令面板…", language: .simplifiedChinese), key: "p",
                modifiers: [.command, .shift]),
            command(.changes, L10n.key("更改", language: .simplifiedChinese), key: "1"),
            command(.history, L10n.key("提交历史", language: .simplifiedChinese), key: "2"),
            command(.branches, L10n.key("分支", language: .simplifiedChinese), key: "3"),
            command(.stashes, L10n.key("储藏", language: .simplifiedChinese), key: "4"),
            command(.tags, L10n.key("标签", language: .simplifiedChinese), key: "5"),
            command(
                .quickAccess, L10n.key("菜单栏快捷面板", language: .simplifiedChinese), key: "m",
                modifiers: [.command, .shift]),
        ]
    }
}
