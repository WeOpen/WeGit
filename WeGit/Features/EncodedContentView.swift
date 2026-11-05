import AppKit
import SwiftUI
import WeGitCore

private enum ContentEncoding: String, CaseIterable, Identifiable {
    case utf8 = "UTF-8"
    case utf16LE = "UTF-16 LE"
    case utf16BE = "UTF-16 BE"
    case shiftJIS = "Shift-JIS"
    case windows1252 = "Windows-1252"
    case latin1 = "ISO-8859-1"
    var id: String { rawValue }
    var encoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LE: .utf16LittleEndian
        case .utf16BE: .utf16BigEndian
        case .shiftJIS: .shiftJIS
        case .windows1252: .windowsCP1252
        case .latin1: .isoLatin1
        }
    }
}

struct EncodedContentView: View {
    let app: AppState
    let session: RepositorySession
    let source: RasterComparisonSource
    @Environment(\.themeColors) private var colors
    @State private var encoding = ContentEncoding.utf8
    @State private var inputs: RasterComparisonInput?
    @State private var prefixes: [Data?] = [nil, nil]
    @State private var errors: [String?] = [nil, nil]
    @State private var loading = true
    @State private var cancelled = false
    @State private var reload = UUID()
    @State private var exporting = false
    @State private var taskID = UUID()
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(L10n.text("阅读编码"), selection: $encoding) {
                    ForEach(ContentEncoding.allCases) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 240).accessibilityIdentifier("content-encoding")
                Spacer()
                Menu(L10n.text("导出原始文件…")) {
                    ForEach(0..<2) { index in
                        if input(index)?.kind == .image {
                            Button(title(index)) { export(index) }
                        }
                    }
                }.disabled(inputs == nil || exporting)
                if loading || exporting {
                    Button(L10n.text("取消读取")) {
                        taskID = UUID()
                        exportTask?.cancel()
                        loading = false
                        cancelled = true
                    }
                } else if cancelled {
                    Button(L10n.text("重新读取")) {
                        cancelled = false
                        reload = UUID()
                    }
                }
            }.font(.caption).padding(10).background(colors.chrome)
            HStack(spacing: 1) {
                pane(0)
                pane(1)
            }
        }.background(colors.canvas)
            .task(id: source.key + ":" + reload.uuidString) { await prepare() }
            .onDisappear {
                taskID = UUID()
                exportTask?.cancel()
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("encoded-content-reader")
    }
    private func input(_ index: Int) -> RasterInput? { index == 0 ? inputs?.before : inputs?.after }
    private func title(_ index: Int) -> String { index == 0 ? L10n.text("起点") : L10n.text("目标") }
    @ViewBuilder private func pane(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title(index)).font(.caption)
                Spacer()
                if let input = input(index) {
                    Text(ByteCountFormatter.string(fromByteCount: input.byteCount, countStyle: .file)).font(
                        .caption
                    )
                    .foregroundStyle(colors.secondaryText)
                }
            }.padding(10)
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cancelled {
                Text(L10n.text("已取消读取")).foregroundStyle(colors.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = errors[index] {
                Text(message).foregroundStyle(colors.negative).padding(12)
            } else if input(index)?.kind == .absent {
                Text(L10n.text("此版本没有文件")).foregroundStyle(colors.secondaryText).padding(12)
            } else if let data = prefixes[index],
                let decoded = decode(data, truncated: input(index)!.byteCount > data.count)
            {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(
                            Array(decoded.text.components(separatedBy: "\n").prefix(4096).enumerated()),
                            id: \.offset
                        ) { row in
                            Text(row.element.replacingOccurrences(of: "\0", with: "␀"))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(10)
                if input(index)!.byteCount > decoded.bytes
                    || decoded.text.components(separatedBy: "\n").count > 4096
                {
                    Text(L10n.text("仅显示有界预览；完整原始字节可导出。")).font(.caption)
                        .foregroundStyle(colors.secondaryText).padding(10)
                }
            } else {
                Text(L10n.text("此编码无法可靠解码；请选择其他编码或导出原始字节。"))
                    .foregroundStyle(colors.secondaryText).padding(12)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func decode(_ data: Data, truncated: Bool) -> (text: String, bytes: Int)? {
        for trim in 0...(truncated ? min(8, data.count) : 0) {
            let candidate = Data(data.prefix(data.count - trim))
            if let text = String(data: candidate, encoding: encoding.encoding) {
                return (text, candidate.count)
            }
        }
        return nil
    }
    private func prepare() async {
        let token = UUID()
        taskID = token
        loading = true
        prefixes = [nil, nil]
        errors = [nil, nil]
        do {
            let inputs = try await source.prepare(session.service)
            guard !Task.isCancelled, taskID == token else { return }
            self.inputs = inputs
            for (index, input) in [inputs.before, inputs.after].enumerated() {
                do {
                    if input.kind == .image {
                        let data = try await input.readPrefix()
                        guard !Task.isCancelled, taskID == token else { return }
                        prefixes[index] = data
                    } else if input.kind == .oversized {
                        errors[index] = L10n.text("内容超过 32 MiB 读取上限，可使用文件级操作。")
                    } else if input.kind == .symbolicLink {
                        errors[index] = L10n.text("符号链接")
                    }
                } catch { errors[index] = error.localizedDescription }
            }
        } catch { errors = [error.localizedDescription, error.localizedDescription] }
        guard !Task.isCancelled, taskID == token else { return }
        loading = false
    }
    private func export(_ index: Int) {
        guard let input = input(index), !exporting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (input.path as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        exportTask = Task {
            defer {
                exporting = false
                exportTask = nil
            }
            do {
                let data = try await input.readBytes()
                guard !Task.isCancelled else { return }
                try data.write(to: url, options: .atomic)
            } catch { if !Task.isCancelled { errors[index] = error.localizedDescription } }
        }
    }
}
