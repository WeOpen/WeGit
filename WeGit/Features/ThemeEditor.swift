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

    init(preferences: AppPreferences) {
        self.preferences = preferences
        _draft = State(initialValue: preferences.customTheme)
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
                            Text(L10n.text("控件外观决定系统控件与运行中图标的明暗，具体配色在下方设置。"))
                                .font(.caption).foregroundStyle(colors.secondaryText)
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
                        Text(L10n.text("自定义配色独立保存，内置浅色与深色保持不变。"))
                            .font(.caption).foregroundStyle(colors.secondaryText)
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
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("theme-cancel")
                Button(L10n.text("应用主题")) {
                    do {
                        try preferences.applyCustomTheme(draft)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.workbenchPrimaryAction().tint(colors.primaryAction)
                    .disabled(validationError != nil).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("theme-apply")
            }.padding(16).background(colors.chrome)
        }.frame(width: 860, height: 680)
            .onChange(of: draft) { _, value in if livePreview { preferences.previewCustomTheme(value) } }
            .onChange(of: livePreview) { _, value in preferences.previewCustomTheme(value ? draft : nil) }
            .onDisappear { preferences.previewCustomTheme(nil) }
            .alert(
                L10n.text("主题操作未完成"),
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button(L10n.text("好"), role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
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
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if (attributes[.size] as? NSNumber)?.intValue ?? 0 > CustomTheme.maximumFileSize {
                throw CustomTheme.ValidationError.size
            }
            draft = try CustomTheme.decode(Data(contentsOf: url))
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

private struct ThemePreview: View {
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
