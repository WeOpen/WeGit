import SwiftUI
import WeGitCore

struct CommandPalette: View {
    @Environment(\.themeColors) private var colors
    @Bindable var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: String?
    @FocusState private var searchFocused: Bool
    private var commands: [WorkspaceCommand] {
        app.commands.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetTitle(title: L10n.text("命令面板"), symbol: "command")
            WorkbenchSearchField(
                prompt: L10n.text("输入命令…"), text: $query, identifier: "command-search", focus: $searchFocused
            )
            .onSubmit { execute() }
            .onKeyPress(.downArrow) {
                move(1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                move(-1)
                return .handled
            }
            List(selection: $selected) {
                ForEach(commands) { command in
                    HStack(spacing: 10) {
                        Image(systemName: command.symbol).frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(command.title)
                            if !command.enabled {
                                Text(command.reason).font(.caption).foregroundStyle(colors.secondaryText)
                            }
                        }
                        Spacer()
                        Text(command.shortcut).font(.caption).foregroundStyle(colors.secondaryText)
                    }.foregroundStyle(command.enabled ? colors.text : .secondary)
                        .padding(.vertical, 3).tag(command.id).contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            selected = command.id
                            execute()
                        }
                }
            }.accessibilityIdentifier("command-results")
            HStack {
                Text(L10n.text("↑↓ 选择 · Return 执行")).font(.caption).foregroundStyle(colors.secondaryText)
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("执行")) { execute() }.keyboardShortcut(.defaultAction)
                    .disabled(commands.first { $0.id == selected }?.enabled != true)
            }
        }.padding(20).frame(width: 540, height: 450)
            .task {
                selectInitial()
                searchFocused = true
            }
            .onChange(of: query) { _, _ in selectInitial() }
    }

    private func move(_ step: Int) {
        guard !commands.isEmpty else { return }
        let index = commands.firstIndex { $0.id == selected } ?? 0
        selected = commands[min(max(index + step, 0), commands.count - 1)].id
    }

    private func selectInitial() { selected = commands.first(where: \.enabled)?.id ?? commands.first?.id }

    private func execute() {
        guard let command = commands.first(where: { $0.id == selected }), command.enabled else { return }
        app.executeFromPalette(command)
    }
}
