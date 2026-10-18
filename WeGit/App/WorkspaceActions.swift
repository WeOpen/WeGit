import AppKit
import Foundation
import WeGitCore

@MainActor
struct WorkspaceCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var enabled = true
    var reason = ""
    var shortcut = ""
    let action: @MainActor () -> Void
}

extension AppState {
    var anyOperationRunning: Bool {
        preferences.configurationWriteInProgress || clone.isBusy || sessions.values.contains { $0.isBusy }
    }
    var canStageAll: Bool {
        session?.canWrite == true
            && session?.status.files.contains { !$0.conflict && ($0.unstaged || $0.untracked) } == true
    }
    var canUnstageAll: Bool {
        session?.canWrite == true && session?.status.files.contains(where: \.staged) == true
    }

    func presentClone() {
        clone.resetCompleted(defaultDirectory: preferences.defaultDirectory)
        if !clone.isBusy && clone.address.isEmpty { clone.parentPath = preferences.defaultDirectory }
        clonePresented = true
    }

    func commitCurrent() {
        guard let session, session.canCommit else { return }
        if session.amend
            && !confirm(
                title: L10n.text("修改上次提交？"),
                message: L10n.text("将改写 \(session.status.head?.prefix(12) ?? "")。已发布的提交可能需要单独处理后续推送。"),
                action: L10n.text("修改提交"))
        {
            return
        }
        session.commit()
    }

    func stageAll() {
        guard let session, canStageAll else { return }
        let paths = session.status.files.filter { !$0.conflict && ($0.unstaged || $0.untracked) }.map(\.path)
        let head = session.status.head
        session.perform(L10n.text("暂存全部")) { try await $0.stage(paths: paths, expectedHead: head) }
    }

    func unstageAll() {
        guard let session, canUnstageAll else { return }
        let paths = session.status.files.filter(\.staged).map(\.path)
        let head = session.status.head
        session.perform(L10n.text("取消全部暂存")) { try await $0.unstage(paths: paths, expectedHead: head) }
    }

    func presentSearch() {
        guard let session else { return }
        searchRequest = RepositorySearchRequest(session: session, route: workspace.route)
    }

    func presentBranchSwitcher() {
        guard let session else { return }
        branchSwitchRequest = BranchSwitchRequest(session: session)
    }

    func executeFromPalette(_ command: WorkspaceCommand) {
        guard command.enabled else { return }
        pendingPaletteCommand = command
        pendingPaletteSession = session
        pendingPaletteBranch = session?.status.branch
        palettePresented = false
    }

    func paletteDidDismiss() {
        guard let pending = pendingPaletteCommand else { return }
        let target = pendingPaletteSession
        let branch = pendingPaletteBranch
        pendingPaletteCommand = nil
        pendingPaletteSession = nil
        pendingPaletteBranch = nil
        guard session === target, session?.status.branch == branch else {
            error = L10n.text("仓库或分支已切换，请重新选择命令。")
            return
        }
        guard let command = commands.first(where: { $0.id == pending.id }) else { return }
        guard command.enabled else {
            error = command.reason
            return
        }
        command.action()
    }

    func dismissRepositoryPicker(perform action: RepositoryPickerAction) {
        pendingRepositoryPickerAction = action
        repositoryPickerPresented = false
    }

    func repositoryPickerDidDismiss() {
        guard let action = pendingRepositoryPickerAction else { return }
        pendingRepositoryPickerAction = nil
        switch action {
        case .open(let url): Task { await open(url) }
        case .browse: openPanel()
        case .clone: presentClone()
        }
    }

    func branchSwitchReason(_ branch: GitBranch, in session: RepositorySession) -> String? {
        if session.isBusy { return L10n.text("正在执行 \(session.activityLabel)") }
        if !session.canWrite { return L10n.text("请先读取最新仓库状态") }
        if session.status.sequencer != .none { return L10n.text("请先完成\(session.status.sequencer.title)") }
        if branch.current { return L10n.text("当前分支") }
        if branch.remote { return L10n.text("请先创建本地跟踪分支") }
        if branch.symbolicTarget != nil { return L10n.text("请选择实际本地分支") }
        if branch.worktreePath != nil { return L10n.text("此分支正在其他工作树中使用") }
        return nil
    }

    func switchBranch(
        _ branch: GitBranch, in session: RepositorySession, onSuccess: (@MainActor () -> Void)? = nil
    ) {
        guard self.session === session, branchSwitchReason(branch, in: session) == nil else { return }
        let head = session.status.head
        session.perform(
            L10n.text("切换分支"), onSuccess: onSuccess,
            operation: { try await $0.switchBranch(branch, expectedHead: head) }
        )
    }

    func mergeReason(_ branch: GitBranch, in session: RepositorySession) -> String? {
        if !session.canWrite { return session.writeReason }
        if session.status.sequencer != .none { return L10n.text("请先完成\(session.status.sequencer.title)") }
        if branch.current { return L10n.text("不能将当前分支合并到自身") }
        if branch.symbolicTarget != nil { return L10n.text("请选择实际分支") }
        if !session.status.files.isEmpty { return L10n.text("合并前请先处理工作区改动") }
        return nil
    }

    func openTerminal() {
        guard let session else { return }
        openTerminal(at: session.location.root)
    }

    func openTerminal(at target: URL) {
        var directory: ObjCBool = false
        guard target.isFileURL, FileManager.default.fileExists(atPath: target.path, isDirectory: &directory),
            directory.boolValue
        else {
            error = L10n.text("目录不存在，请更新仓库路径。")
            return
        }
        NSWorkspace.shared.open(
            [target], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error { Task { @MainActor in self.error = error.localizedDescription } }
        }
    }

    func copyRepositoryPath() {
        guard let session else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.location.root.path, forType: .string)
    }

    var commands: [WorkspaceCommand] {
        let available = session != nil
        let reason = session?.syncReason ?? L10n.text("请先打开仓库")
        var commands: [WorkspaceCommand] = [
            .init(id: "open", title: L10n.text("打开仓库…"), symbol: "folder", shortcut: "⌘O", action: openPanel),
            .init(
                id: "clone", title: L10n.text("克隆仓库…"), symbol: "square.on.square", shortcut: "⌘⇧O",
                action: presentClone),
            .init(
                id: "switch", title: L10n.text("切换仓库…"), symbol: "folder.badge.gearshape", shortcut: "⌘K",
                action: { self.repositoryPickerPresented = true }),
            .init(
                id: "search", title: L10n.text("搜索当前仓库…"), symbol: "magnifyingglass", enabled: available,
                reason: reason,
                shortcut: "⌘⇧F", action: presentSearch),
            .init(
                id: "refresh", title: L10n.text("刷新仓库"), symbol: "arrow.clockwise", enabled: available,
                reason: reason,
                shortcut: "⌘R", action: { Task { await self.session?.refresh() } }),
            .init(
                id: "branch", title: L10n.text("新建分支…"), symbol: "arrow.triangle.branch",
                enabled: session?.canWrite == true && session?.status.head != nil,
                reason: L10n.text("需要已读取且包含提交的仓库"), shortcut: "⌘⇧N", action: { self.branchPresented = true }),
            .init(
                id: "switch-branch", title: L10n.text("切换分支…"), symbol: "arrow.triangle.branch",
                enabled: session?.canWrite == true && session?.status.sequencer == Sequencer.none,
                reason: L10n.text("请先打开仓库并完成当前 Git 操作"),
                action: presentBranchSwitcher),
            .init(
                id: "stage", title: L10n.text("暂存全部更改"), symbol: "plus.circle", enabled: canStageAll,
                reason: L10n.text("需要未暂存或未跟踪的文件"), action: stageAll),
            .init(
                id: "unstage", title: L10n.text("取消全部暂存"), symbol: "minus.circle", enabled: canUnstageAll,
                reason: L10n.text("没有可以取消暂存的文件"), action: unstageAll),
            .init(
                id: "commit", title: session?.amend == true ? L10n.text("修改上次提交…") : L10n.text("提交"),
                symbol: "checkmark.circle",
                enabled: session?.canCommit == true,
                reason: session?.commitReason ?? reason, shortcut: "⌘↩", action: commitCurrent),
            .init(
                id: "pull", title: L10n.text("拉取…"), symbol: "arrow.down.to.line", enabled: session?.canSync == true,
                reason: reason, shortcut: "⌘⇧L", action: { self.presentSync(.pull) }),
            .init(
                id: "push", title: L10n.text("推送…"), symbol: "arrow.up.to.line", enabled: session?.canSync == true,
                reason: reason, shortcut: "⌘⇧U", action: { self.presentSync(.push) }),
            .init(
                id: "terminal", title: L10n.text("在 Terminal 中打开仓库"), symbol: "terminal", enabled: available,
                reason: reason, action: openTerminal),
            .init(
                id: "xcode", title: L10n.text("在 Xcode 中打开仓库…"), symbol: "hammer",
                enabled: available && xcodeURL != nil,
                reason: available ? L10n.text("需要已安装的 Xcode") : reason, action: openRepositoryInXcode),
            .init(
                id: "copy-path", title: L10n.text("复制仓库路径"), symbol: "doc.on.doc", enabled: available,
                reason: reason,
                action: copyRepositoryPath),
            .init(
                id: "activity", title: L10n.text("查看活动记录"), symbol: "clock",
                action: { self.activityPresented = true }),
            .init(
                id: "settings", title: L10n.text("设置…"), symbol: "gearshape", shortcut: "⌘,",
                action: { self.settingsRequestID = UUID() }),
        ]
        if let session {
            for remote in session.remotes {
                commands.append(
                    .init(
                        id: "fetch:" + remote, title: L10n.text("获取 \(remote)"), symbol: "arrow.clockwise",
                        enabled: session.canWrite,
                        reason: reason,
                        action: {
                            session.perform(L10n.text("获取 \(remote)")) { try await $0.fetch(remote: remote) }
                        }))
            }
        }
        for (index, route) in WorkspaceRoute.allCases.enumerated() {
            commands.append(
                .init(
                    id: "route:" + route.id, title: route.title, symbol: route.icon, enabled: available,
                    reason: reason, shortcut: "⌘\(index + 1)", action: { self.workspace.route = route }))
        }
        return commands
    }
}
