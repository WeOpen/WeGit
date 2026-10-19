import AppKit
import SwiftUI
import WeGitCore

@MainActor
enum MenuBarSymbol {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { _ in
            let rect = CGRect(x: -5, y: -7, width: 32, height: 32)
            NSColor.black.set()
            NSBezierPath(cgPath: BrandGeometry.path(in: rect, optical: true)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L10n.text("WeGit 快速访问")
        return image
    }()
}

struct MenuBarPanel: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    let showMainWindow: @MainActor () -> Void
    let showSettings: @MainActor () -> Void
    let closePanel: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BrandMark(tint: colors.brandBlue).frame(width: 56, height: 56).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.session?.location.name ?? "WeGit").font(.headline).lineLimit(1)
                    Text(L10n.text("快速访问")).font(.caption).foregroundStyle(colors.secondaryText)
                }
                Spacer()
                Button(L10n.text("打开主窗口"), systemImage: "macwindow") { inMainWindow {} }
                    .buttonStyle(MenuBarIconStyle()).help(L10n.text("打开 WeGit 主窗口"))
                    .accessibilityIdentifier("menu-bar-open-main")
            }
            if app.preferences.configurationWriteInProgress {
                Label(L10n.text("正在保存 Git 配置…"), systemImage: "gearshape")
                    .font(.caption).foregroundStyle(colors.modified)
            } else if app.clone.isBusy {
                Label(L10n.text("正在克隆仓库…"), systemImage: "arrow.down.to.line")
                    .font(.caption).foregroundStyle(colors.modified)
            }
            if let session = app.session {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(session.status.displayBranch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        RepositorySyncSummary(session: session)
                    }
                    Text(repositoryState(session)).font(.caption).foregroundStyle(colors.secondaryText)
                        .lineLimit(3).help(repositoryState(session))
                        .accessibilityIdentifier("menu-bar-repository-state")
                    HStack(spacing: 8) {
                        ForEach(WorkspaceRoute.allCases) { route in
                            Button(route.title, systemImage: route.icon) {
                                inMainWindow { app.workspace.route = route }
                            }.buttonStyle(MenuBarIconStyle()).frame(maxWidth: .infinity)
                                .help(L10n.text("打开\(route.title)"))
                                .accessibilityIdentifier("menu-bar-route-" + route.id)
                        }
                    }
                    HStack {
                        Button(L10n.text("刷新"), systemImage: "arrow.clockwise") {
                            Task { await session.refresh() }
                        }
                        .disabled(
                            session.isBusy || session.isRefreshing
                                || app.preferences.configurationWriteInProgress
                        )
                        .accessibilityIdentifier("menu-bar-refresh")
                        Spacer()
                        Button(L10n.text("拉取…"), systemImage: "arrow.down") {
                            inMainWindow { app.presentSync(.pull) }
                        }
                        .disabled(!session.canSync).help(session.syncReason)
                        .accessibilityIdentifier("menu-bar-pull")
                        Button(L10n.text("推送…"), systemImage: "arrow.up") {
                            inMainWindow { app.presentSync(.push) }
                        }
                        .disabled(!session.canSync).help(session.syncReason)
                        .accessibilityIdentifier("menu-bar-push")
                    }
                }.padding(12).workbenchSurface(radius: 12)
            } else {
                Text(app.isOpening ? L10n.text("正在打开仓库…") : L10n.text("打开一个仓库，开始查看改动。"))
                    .font(.callout).foregroundStyle(colors.secondaryText)
            }
            if !app.recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("最近与收藏")).font(.caption.weight(.medium)).foregroundStyle(
                        colors.secondaryText)
                    ForEach(app.recents.sorted { $0.pinned && !$1.pinned }.prefix(5)) { record in
                        Button {
                            inMainWindow { Task { await app.open(URL(fileURLWithPath: record.path)) } }
                        } label: {
                            HStack {
                                Image(systemName: record.pinned ? "pin" : "folder")
                                Text(record.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.caption2)
                            }.font(.callout)
                        }.buttonStyle(.plain).workbenchHoverRow().help(record.path)
                            .accessibilityIdentifier("menu-bar-recent:" + record.path)
                    }
                }
            }
            HStack {
                Button(L10n.text("打开…"), systemImage: "folder.badge.plus") {
                    inMainWindow { app.openPanel() }
                }
                Button(L10n.text("克隆…"), systemImage: "arrow.down.to.line") {
                    inMainWindow { app.presentClone() }
                }
                Spacer()
            }
            Divider()
            HStack {
                Button(L10n.text("设置…"), systemImage: "gearshape") {
                    inMainWindow { showSettings() }
                }.accessibilityIdentifier("menu-bar-settings")
                Spacer()
                Button(L10n.text("退出 WeGit")) {
                    closePanel()
                    NSApp.activate()
                    NSApp.terminate(nil)
                }.help(app.anyOperationRunning ? L10n.text("操作进行中，退出时会提示返回应用") : L10n.text("退出 WeGit"))
                    .accessibilityIdentifier("menu-bar-quit")
            }.font(.caption)
        }.padding(18).frame(width: 380).background(colors.canvas)
            .buttonStyle(MenuBarActionStyle())
            .onAppear { app.menuBarPresented = true }
            .task(id: app.session?.id) {
                guard let session = app.session else { return }
                session.activate()
                if !session.isBusy && !app.preferences.configurationWriteInProgress {
                    await session.refresh()
                }
            }
            .onDisappear {
                app.menuBarPresented = false
                if !app.mainWorkspaceMounted && !app.mainWindowRequested { app.session?.deactivate() }
            }
    }

    private func repositoryState(_ session: RepositorySession) -> String {
        if session.isBusy { return session.activityLabel + "…" }
        if let error = session.refreshError { return L10n.text("状态未更新：") + error }
        if session.isRefreshing || session.isStale || !session.hasLoaded { return L10n.text("正在核对仓库状态…") }
        let staged = session.status.files.lazy.filter(\.staged).count
        return L10n.text("\(session.status.files.count) 个文件有改动 · \(staged) 个已暂存")
    }

    private func inMainWindow(_ action: @escaping @MainActor () -> Void) {
        app.mainWindowRequested = true
        showMainWindow()
        if app.mainWorkspaceMounted { app.mainWindowRequested = false }
        NSApp.activate()
        closePanel()
        action()
    }
}

private struct MenuBarActionStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.padding(.horizontal, 6).padding(.vertical, 4)
        }.workbenchControlFamily().controlSize(.regular)
    }
}

private struct MenuBarIconStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
        }.workbenchIconButton().controlSize(.regular)
    }
}
