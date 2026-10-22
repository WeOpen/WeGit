import Foundation
import WeGitCore

@MainActor
extension NativeApplicationMenu {
    convenience init(app: AppState) {
        self.init(
            perform: { [weak app] command in
                guard let app else { return }
                switch command {
                case .openRepository: app.openPanel()
                case .clone: app.presentClone()
                case .switchRepository: app.repositoryPickerPresented = true
                case .sidebar: app.sidebarRequestID = UUID()
                case .inspector: app.workspace.inspector.toggle()
                case .switchBranch: app.presentBranchSwitcher()
                case .refresh: Task { await app.session?.refresh() }
                case .newBranch: app.branchPresented = true
                case .stageAll: app.stageAll()
                case .unstageAll: app.unstageAll()
                case .commit: app.commitCurrent()
                case .commitAndPush: app.presentSync(.commitAndPush)
                case .pull: app.presentSync(.pull)
                case .push: app.presentSync(.push)
                case .closeRepository: app.closeRepository()
                case .activity: app.activityPresented = true
                case .terminal: app.openTerminal()
                case .xcode: app.openRepositoryInXcode()
                case .copyPath: app.copyRepositoryPath()
                case .search: app.presentSearch()
                case .palette: app.palettePresented = true
                case .changes: app.workspace.route = .changes
                case .history: app.workspace.route = .history
                case .branches: app.workspace.route = .branches
                case .stashes: app.workspace.route = .stashes
                case .quickAccess: app.menuBarRequestID = UUID()
                #if DEBUG
                    case .recoverTrashFixture: app.recoverTrashFixture()
                #endif
                default: break
                }
            },
            enabled: { [weak app] command in
                guard let app else { return false }
                switch command {
                case .sidebar, .inspector, .changes, .history, .branches, .stashes, .refresh, .terminal,
                    .copyPath,
                    .search:
                    return app.session != nil
                case .switchBranch: return app.session?.canWrite == true
                case .newBranch: return app.session?.status.head != nil && app.session?.canWrite == true
                case .stageAll: return app.canStageAll
                case .unstageAll: return app.canUnstageAll
                case .commit: return app.session?.canCommit == true
                case .commitAndPush: return app.session?.canCommitAndPush == true
                case .pull, .push: return app.session?.canSync == true
                case .closeRepository:
                    return app.session != nil && app.session?.isBusy != true
                        && !app.preferences.configurationWriteInProgress
                case .xcode: return app.session != nil && app.xcodeURL != nil
                case .quickAccess: return app.preferences.showMenuBar && app.allowsMenuBarExtra
                #if DEBUG
                    case .recoverTrashFixture: return app.canRecoverTrashFixture
                #endif
                default: return true
                }
            },
            selected: { [weak app] command in
                guard let app else { return false }
                switch command {
                case .changes: return app.workspace.route == .changes
                case .history: return app.workspace.route == .history
                case .branches: return app.workspace.route == .branches
                case .stashes: return app.workspace.route == .stashes
                default: return false
                }
            },
            title: { [weak app] command in
                switch command {
                case .sidebar:
                    return L10n.menuTitle(app?.sidebarVisible == true ? "Hide Sidebar" : "Show Sidebar")
                case .inspector:
                    return L10n.menuTitle(
                        app?.workspace.inspector == true ? "Hide Inspector" : "Show Inspector")
                default: return nil
                }
            },
            appearance: { [weak app] in
                AppPresentation.appearance(for: app?.preferences.resolvedAppearance ?? "system")
            })
    }
}
