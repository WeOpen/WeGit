import SwiftUI
import WeGitCore

struct ChangesFileList<Context: View>: View {
    @Environment(\.themeColors) private var colors
    let files: [FileChange]
    let filter: ChangeFilter
    let byFolder: Bool
    let showFileIcons: Bool
    let compact: Bool
    let canWrite: Bool
    let writeReason: String
    @Binding var selection: String?
    @Binding var collapsedGroups: Set<String>
    @Binding var collapsedFolders: Set<String>
    let stage: ([FileChange], DiffLayer) -> Void
    @ViewBuilder let context: (FileChange, DiffLayer) -> Context

    var body: some View {
        List(selection: $selection) {
            group(L10n.text("冲突"), layer: .conflict)
            group(L10n.text("已暂存"), layer: .staged)
            group(L10n.text("未暂存"), layer: .unstaged)
            group(L10n.text("未跟踪"), layer: .untracked)
        }
        .listStyle(.inset).scrollContentBackground(.hidden)
        .background(colors.surface).accessibilityIdentifier("changes-list")
    }

    @ViewBuilder private func group(_ title: String, layer: DiffLayer) -> some View {
        let visible = files.filter { filter.matches($0, layer: layer) }
        if !visible.isEmpty {
            header(title, layer: layer, files: visible, key: layer.rawValue, folder: false)
            if !collapsedGroups.contains(layer.rawValue) {
                if byFolder {
                    let prefix = layer.rawValue + "|"
                    let collapsed = Set(
                        collapsedFolders.filter { $0.hasPrefix(prefix) }.map {
                            String($0.dropFirst(prefix.count))
                        })
                    ForEach(
                        ChangeFileTree.rows(visible, collapsedFolders: collapsed).map {
                            LayerRow(id: prefix + $0.id, value: $0)
                        }
                    ) { item in
                        let row = item.value
                        if let file = row.file {
                            fileRow(file, layer: layer, tree: true)
                                .padding(.leading, CGFloat(min(row.depth, 10)) * 14)
                        } else {
                            header(
                                row.name, layer: layer, files: row.files, key: prefix + row.path, folder: true
                            )
                            .padding(.leading, CGFloat(min(row.depth, 10)) * 14)
                        }
                    }
                } else {
                    ForEach(visible.map { LayerRow(id: layer.rawValue + "|" + $0.id, value: $0) }) { item in
                        fileRow(item.value, layer: layer, tree: false)
                    }
                }
            }
        }
    }

    private func header(_ title: String, layer: DiffLayer, files: [FileChange], key: String, folder: Bool)
        -> some View
    {
        let collapsed = folder ? collapsedFolders.contains(key) : collapsedGroups.contains(key)
        return HStack(spacing: 6) {
            if layer != .conflict {
                checkbox(
                    files, layer: layer, identifier: (folder ? "stage-folder:" : "stage-group:") + key,
                    label: (layer == .staged ? L10n.text("取消暂存所显示的文件") : L10n.text("暂存所显示的文件")) + " " + title)
            } else {
                Color.clear.frame(width: 18, height: 18).accessibilityHidden(true)
            }
            Button {
                if folder {
                    if collapsed { collapsedFolders.remove(key) } else { collapsedFolders.insert(key) }
                } else {
                    if collapsed { collapsedGroups.remove(key) } else { collapsedGroups.insert(key) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    if folder { Image(systemName: "folder").foregroundStyle(colors.secondaryText) }
                    Text(L10n.text("\(title)（\(files.count)）")).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(folder ? .system(size: 12, weight: .medium) : .caption.weight(.semibold))
                .foregroundStyle(colors.secondaryText).frame(minHeight: 26).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("\(title)（\(files.count)）"))
            .accessibilityValue(collapsed ? L10n.text("已折叠") : L10n.text("已展开"))
            .accessibilityIdentifier("changes-collapse:" + key)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier((folder ? "changes-folder:" : "changes-group:") + key)
        .listRowBackground(colors.surface).listRowSeparator(.hidden)
    }

    private func checkbox(_ files: [FileChange], layer: DiffLayer, identifier: String, label: String)
        -> some View
    {
        Toggle(
            label,
            isOn: Binding(
                get: { layer == .staged },
                set: { checked in
                    guard checked != (layer == .staged), canWrite else { return }
                    stage(files, layer)
                })
        )
        .toggleStyle(.checkbox).labelsHidden().controlSize(.small)
        .frame(width: 18).disabled(!canWrite)
        .help(canWrite ? label : writeReason)
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
    }

    private func fileRow(_ file: FileChange, layer: DiffLayer, tree: Bool) -> some View {
        HStack(spacing: 8) {
            if layer == .conflict {
                Button {
                    stage([file], layer)
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless).frame(width: 18).disabled(!canWrite)
                .help(canWrite ? L10n.text("标记已解决") : writeReason)
                .accessibilityLabel(L10n.text("标记已解决") + " " + file.filename)
                .accessibilityIdentifier("stage:\(layer.rawValue):\(file.path)")
            } else {
                checkbox(
                    [file], layer: layer, identifier: "stage:\(layer.rawValue):\(file.path)",
                    label: (layer == .staged ? L10n.text("取消暂存") : L10n.text("暂存")) + " " + file.path)
            }
            if showFileIcons { FileTypeIcon(path: file.path) }
            VStack(alignment: .leading, spacing: 3) {
                Text(file.filename).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !tree, file.path != file.filename {
                    Text((file.path as NSString).deletingLastPathComponent).font(.caption2)
                        .foregroundStyle(colors.secondaryText).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            StatusBadge(symbol: file.symbol(for: layer))
        }
        .padding(.vertical, compact ? 1 : 4)
        .accessibilityElement(children: .contain)
        .tag(layer.rawValue + "|" + file.path)
        .accessibilityIdentifier("changes-file:\(layer.rawValue):\(file.path)")
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
        .contextMenu { context(file, layer) }
    }
}

/// List rows must remain distinct when one file appears in multiple index layers.
private struct LayerRow<Value>: Identifiable {
    let id: String
    let value: Value
}
