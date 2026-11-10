import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WeGitCore

struct ThemeEditor: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @Bindable var preferences: AppPreferences
    @State private var draft: CustomTheme
    @State private var livePreview = false
    @State private var error: String?
    @State private var themeID: UUID?
    @State private var original: CustomTheme
    @State private var previewOwner = UUID()

    init(preferences: AppPreferences, themeID: UUID? = nil, createNew: Bool = false) {
        self.preferences = preferences
        let id = createNew ? nil : themeID ?? preferences.activeCustomThemeID
        let theme =
            id.flatMap { selected in preferences.customThemes.first { $0.id == selected }?.theme }
            ?? preferences.customTheme
        _themeID = State(initialValue: id)
        _draft = State(initialValue: theme)
        _original = State(initialValue: theme)
    }

    private var validationError: String? {
        do {
            _ = try draft.validated()
            return nil
        } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SheetTitle(title: L10n.text("自定义主题"), symbol: "paintpalette")
                Spacer()
                Toggle(L10n.text("实时预览"), isOn: $livePreview).toggleStyle(.switch)
                    .accessibilityIdentifier("theme-live-preview")
            }.padding(18).background(colors.chrome)
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField(L10n.text("主题名称"), text: $draft.name)
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("theme-name")
                            Picker(L10n.text("控件外观"), selection: $draft.controls) {
                                Text(L10n.text("浅色")).tag(ThemeControlAppearance.light)
                                Text(L10n.text("深色")).tag(ThemeControlAppearance.dark)
                            }.accessibilityIdentifier("theme-controls")
                        }
                        colorSection(L10n.text("表面"), roles: [.canvas, .chrome, .sidebar, .surface, .border])
                        colorSection(L10n.text("文字与强调"), roles: [.accent, .text, .secondaryText])
                        colorSection(
                            L10n.text("Git 状态与差异"),
                            roles: [.positive, .negative, .modified, .diffAdded, .diffRemoved])
                        colorSection(L10n.text("语法高亮"), roles: [.keyword, .string, .number, .comment])
                    }.padding(18)
                }.frame(minWidth: 410, idealWidth: 460)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ThemePreview(theme: draft)
                        if let validationError {
                            Label(validationError, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(colors.negative)
                                .accessibilityIdentifier("theme-validation-error")
                        } else if !draft.contrastIssues.isEmpty {
                            DisclosureGroup(L10n.text("部分文字对比度低于 4.5:1")) {
                                ForEach(draft.contrastIssues) { issue in
                                    HStack(alignment: .top) {
                                        Text(issue.foreground.title + " / " + issue.background.title)
                                        Spacer()
                                        Text(verbatim: String(format: "%.2f:1", issue.ratio))
                                            .monospacedDigit()
                                    }.font(.caption)
                                }
                            }.foregroundStyle(colors.modified).accessibilityIdentifier(
                                "theme-contrast-warning")
                            Text(L10n.text("提示不会自动修改你的颜色。实际玻璃材质与系统控件还需检查。"))
                                .font(.caption).foregroundStyle(colors.secondaryText)
                        }
                    }.padding(18)
                }.frame(minWidth: 300, idealWidth: 330)
            }.background(colors.canvas)
            Divider()
            HStack(spacing: 10) {
                Button(L10n.text("导入…"), action: importTheme).accessibilityIdentifier("theme-import")
                Button(L10n.text("导出…"), action: exportTheme).disabled(validationError != nil)
                    .accessibilityIdentifier("theme-export")
                Button(L10n.text("恢复初始配色")) { draft = .starter }
                    .accessibilityIdentifier("theme-reset")
                Spacer()
                Button(L10n.text("保存")) { save(activate: false) }.disabled(validationError != nil)
                    .accessibilityIdentifier("theme-save")
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("theme-cancel")
                Button(L10n.text("应用主题")) {
                    save(activate: true)
                }.workbenchPrimaryAction().tint(colors.primaryAction)
                    .disabled(validationError != nil).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("theme-apply")
            }.padding(16).background(colors.chrome)
        }.frame(width: 860, height: 680)
            .onChange(of: draft) { _, value in
                if livePreview {
                    _ = preferences.previewCustomTheme(value, owner: previewOwner, sourceID: themeID)
                }
            }
            .onChange(of: livePreview) { _, value in
                if !preferences.previewCustomTheme(
                    value ? draft : nil, owner: previewOwner, sourceID: themeID)
                {
                    livePreview = false
                    error = CustomThemeLibrary.Failure.previewInUse.localizedDescription
                }
            }
            .onDisappear { _ = preferences.previewCustomTheme(nil, owner: previewOwner) }
            .alert(
                L10n.text("主题操作未完成"),
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button(L10n.text("好"), role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    private func save(activate: Bool) {
        do {
            _ = try preferences.saveCustomTheme(
                draft, id: themeID, expected: themeID == nil ? nil : original, activate: activate,
                owner: previewOwner)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func colorSection(_ title: String, roles: [ThemeColorRole]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(roles) { role in
                HStack {
                    Text(role.title)
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        TextField(text: Binding(get: { draft[role] }, set: { draft[role] = $0 })) {
                            Text(verbatim: "#RRGGBB")
                        }.font(.system(.caption, design: .monospaced)).textFieldStyle(.roundedBorder)
                            .frame(width: 92).accessibilityLabel(role.title)
                            .accessibilityIdentifier("theme-color-" + role.rawValue)
                        ColorPicker(role.title, selection: colorBinding(role), supportsOpacity: false)
                            .labelsHidden().frame(width: 40)
                            .accessibilityLabel(L10n.text("\(role.title)颜色选择器"))
                            .accessibilityIdentifier(
                                "theme-well-" + role.rawValue)
                    }
                }.accessibilityElement(children: .contain)
            }
        }
    }

    private func colorBinding(_ role: ThemeColorRole) -> Binding<Color> {
        Binding {
            AppColors(custom: draft, dark: draft.controls == .dark).color(role)
        } set: { value in
            guard let color = NSColor(value).usingColorSpace(.sRGB) else { return }
            func channel(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
            draft[role] = String(
                format: "#%02X%02X%02X", channel(color.redComponent),
                channel(color.greenComponent), channel(color.blueComponent))
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            draft = try CustomTheme.decode(handle.read(upToCount: CustomTheme.maximumFileSize + 1) ?? Data())
            original = draft
            themeID = nil
        } catch { self.error = error.localizedDescription }
    }

    private func exportTheme() {
        do {
            let data = try draft.encoded()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "WeGit-theme.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}

struct ThemePreview: View {
    let theme: CustomTheme
    private var colors: AppColors { AppColors(custom: theme, dark: theme.controls == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BrandMark().frame(width: 34, height: 34)
                Text(theme.name).font(.headline).lineLimit(1)
                Spacer()
                Image(systemName: "sidebar.right")
            }.padding(12).background(colors.chrome)
            Rectangle().fill(colors.border).frame(height: 1)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("更改")).font(.caption.weight(.semibold))
                        .padding(6).foregroundStyle(colors.selectionText).background(
                            colors.accent, in: .capsule)
                    Text(L10n.text("提交历史")).font(.caption).foregroundStyle(colors.secondaryText)
                    Spacer(minLength: 20)
                }.padding(10).frame(width: 100).background(colors.sidebar)
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: "main").font(.caption.weight(.medium))
                    Text(L10n.text("新增")).font(.caption).foregroundStyle(colors.positive)
                    Text(L10n.text("删除")).font(.caption).foregroundStyle(colors.negative)
                    Text(L10n.text("修改")).font(.caption).foregroundStyle(colors.modified)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 150)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "// WeGit").foregroundStyle(colors.comment)
                HStack(spacing: 0) {
                    Text(verbatim: "let ").foregroundStyle(colors.keyword)
                    Text(verbatim: "branch = ").foregroundStyle(colors.text)
                    Text(verbatim: "\"main\"").foregroundStyle(colors.string)
                }
                Text(verbatim: "+ count = 42").foregroundStyle(colors.text)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6).background(colors.diffAdded)
                Text(verbatim: "− count = 41").foregroundStyle(colors.text)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6).background(colors.diffRemoved)
            }.font(.system(.caption, design: .monospaced)).padding(12)
                .background(colors.surface)
        }.foregroundStyle(colors.text).background(colors.canvas)
            .clipShape(.rect(cornerRadius: 12)).overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(colors.border)
            }.environment(\.themeColors, colors)
            .accessibilityIdentifier("theme-preview")
    }
}

private struct ThemeLibraryEditorRequest: Identifiable {
    let id = UUID()
    let themeID: UUID?
    let createNew: Bool
}

struct ThemeLibraryView: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    @Bindable var preferences: AppPreferences
    @State private var editor: ThemeLibraryEditorRequest?
    @State private var error: String?
    @State private var pendingDelete: CustomThemeEntry?
    @State private var deleted: CustomThemeEntry?
    @State private var rebuilding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("主题库"), symbol: "paintpalette")
            if preferences.themeLibraryLoadFailed {
                HStack {
                    Text(CustomThemeLibrary.Failure.invalid.localizedDescription).foregroundStyle(
                        colors.negative)
                    Button(L10n.text("恢复旧主题…")) { rebuilding = true }
                }
            }
            HStack {
                Button(L10n.text("新增主题")) {
                    editor = ThemeLibraryEditorRequest(themeID: nil, createNew: true)
                }
                .accessibilityIdentifier("theme-library-add")
                Button(L10n.text("导入 JSON…")) { importFile() }.accessibilityIdentifier("theme-library-import")
                Spacer()
                Text(String(preferences.customThemes.count)).monospacedDigit().foregroundStyle(
                    colors.secondaryText)
            }
            if preferences.customThemes.isEmpty {
                Text(L10n.text("还没有保存的自定义主题")).foregroundStyle(colors.secondaryText)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(preferences.customThemes) { entry in
                        HStack(spacing: 14) {
                            HStack(spacing: 3) {
                                ForEach([ThemeColorRole.canvas, .surface, .accent, .positive, .keyword]) {
                                    role in
                                    RoundedRectangle(cornerRadius: 3).fill(
                                        AppColors(custom: entry.theme, dark: entry.theme.controls == .dark)
                                            .color(role)
                                    )
                                    .frame(width: 14, height: 30)
                                }
                            }.accessibilityHidden(true)
                            Text(entry.theme.name).font(.headline).lineLimit(2).frame(
                                maxWidth: .infinity, alignment: .leading)
                            if preferences.activeCustomThemeID == entry.id
                                && preferences.appearance == "custom"
                            {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(colors.positive)
                                    .accessibilityLabel(L10n.text("当前主题"))
                            } else {
                                Button(L10n.text("使用主题")) {
                                    attempt { try preferences.activateCustomTheme(entry.id) }
                                }
                                .accessibilityIdentifier("theme-activate:" + entry.id.uuidString)
                            }
                            Button(L10n.text("编辑…")) {
                                editor = ThemeLibraryEditorRequest(themeID: entry.id, createNew: false)
                            }
                            .accessibilityIdentifier("theme-edit:" + entry.id.uuidString)
                            Menu {
                                Button(L10n.text("复制主题")) {
                                    attempt { _ = try preferences.duplicateCustomTheme(entry.id) }
                                }
                                Button(L10n.text("导出 JSON…")) { export(entry) }
                                Divider()
                                Button(L10n.text("删除主题…"), role: .destructive) { pendingDelete = entry }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .accessibilityLabel(L10n.text("主题操作"))
                        }.padding(12).background(colors.surface, in: .rect(cornerRadius: 8))
                            .accessibilityElement(children: .contain).accessibilityIdentifier(
                                "theme-entry:" + entry.id.uuidString)
                    }
                }
            }
            if let deleted {
                HStack {
                    Text(L10n.text("已删除 \(deleted.theme.name)"))
                    Button(L10n.text("撤销")) {
                        attempt {
                            try preferences.restoreDeletedCustomTheme(deleted)
                            self.deleted = nil
                        }
                    }
                }.foregroundStyle(colors.secondaryText)
            }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 700, height: 520).workbenchControlFamily()
            .alert(L10n.text("从旧主题恢复主题库？"), isPresented: $rebuilding) {
                Button(L10n.text("恢复")) { attempt { try preferences.rebuildThemeLibraryFromLegacy() } }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: {
                Text(L10n.text("原损坏数据会单独备份，当前外观将跟随系统。"))
            }
            .sheet(item: $editor) { request in
                ThemeEditor(preferences: preferences, themeID: request.themeID, createNew: request.createNew)
                    .id(request.id).workbenchSheet(preferences)
            }
            .confirmationDialog(
                L10n.text("删除这个主题？"),
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(L10n.text("删除主题"), role: .destructive) {
                    guard let entry = pendingDelete else { return }
                    attempt {
                        try preferences.deleteCustomTheme(entry.id)
                        deleted = entry
                        pendingDelete = nil
                    }
                }
                Button(L10n.text("取消"), role: .cancel) { pendingDelete = nil }
            } message: {
                if let entry = pendingDelete, preferences.activeCustomThemeID == entry.id {
                    Text(L10n.text("当前主题删除后将跟随系统外观。"))
                }
            }
    }
    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let theme = try CustomTheme.decode(
                handle.read(upToCount: CustomTheme.maximumFileSize + 1) ?? Data())
            _ = try preferences.importCustomTheme(theme)
        }
    }
    private func export(_ entry: CustomThemeEntry) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "WeGit-theme.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt { try entry.theme.encoded().write(to: url, options: .atomic) }
    }
}

struct ThemeImportSheet: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let preferences: AppPreferences
    let payload: ThemeImportPayload
    @State private var importedID: UUID?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("导入主题"), symbol: "paintpalette")
            ThemePreview(theme: payload.theme)
            if let importedID {
                Text(
                    preferences.activeCustomThemeID == importedID && preferences.appearance == "custom"
                        ? L10n.text("主题已启用") : L10n.text("主题已保存到主题库")
                )
                .accessibilityIdentifier("theme-uri-result")
            }
            if let error { Text(error).foregroundStyle(colors.negative) }
            HStack {
                Spacer()
                Button(importedID == nil ? L10n.text("取消") : L10n.text("关闭")) { dismiss() }.keyboardShortcut(
                    .cancelAction)
                if let importedID {
                    Button(L10n.text("启用主题")) {
                        do {
                            try preferences.activateCustomTheme(importedID)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.workbenchPrimaryAction().accessibilityIdentifier("theme-uri-activate")
                } else {
                    Button(L10n.text("保存到主题库")) {
                        do { importedID = try preferences.importCustomTheme(payload.theme) } catch {
                            self.error = error.localizedDescription
                        }
                    }.workbenchPrimaryAction().keyboardShortcut(.defaultAction).accessibilityIdentifier(
                        "theme-uri-save")
                }
            }
        }.padding(24).frame(width: 480).workbenchControlFamily()
    }
}
