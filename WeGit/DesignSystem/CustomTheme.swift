import CryptoKit
import Foundation
import WeGitCore

enum ThemeColorRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case accent, canvas, chrome, sidebar, surface, border
    case text, secondaryText
    case positive, negative, modified, diffAdded, diffRemoved
    case keyword, string, number, comment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accent: L10n.text("强调色")
        case .canvas: L10n.text("内容背景")
        case .chrome: L10n.text("工具栏与面板标题")
        case .sidebar: L10n.text("侧栏背景")
        case .surface: L10n.text("卡片与输入区域")
        case .border: L10n.text("边界与分隔线")
        case .text: L10n.text("主要文字")
        case .secondaryText: L10n.text("次要文字")
        case .positive: L10n.text("新增与成功")
        case .negative: L10n.text("删除与错误")
        case .modified: L10n.text("修改与提醒")
        case .diffAdded: L10n.text("新增行背景")
        case .diffRemoved: L10n.text("删除行背景")
        case .keyword: L10n.text("关键字")
        case .string: L10n.text("字符串")
        case .number: L10n.text("数字与链接")
        case .comment: L10n.text("注释")
        }
    }
}

enum ThemeControlAppearance: String, CaseIterable, Codable, Sendable {
    case light, dark
}

struct ThemeRGB: Equatable, Sendable {
    let value: UInt32

    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.utf8.count == 6,
            text.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }),
            let value = UInt32(text, radix: 16)
        else { return nil }
        self.value = value
    }

    var hex: String { String(format: "#%06X", value) }
    var red: Double { Double((value >> 16) & 255) / 255 }
    var green: Double { Double((value >> 8) & 255) / 255 }
    var blue: Double { Double(value & 255) / 255 }

    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(with other: ThemeRGB) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
}

struct CustomTheme: Codable, Equatable, Sendable {
    var version: Int
    var name: String
    var controls: ThemeControlAppearance
    var colors: [String: String]

    static let maximumFileSize = 65_536
    static let starter = CustomTheme(
        version: 1, name: "Ink & Ivory", controls: .dark,
        colors: [
            "accent": "#D66E5D", "canvas": "#1F1F1F", "chrome": "#1F1F1F",
            "sidebar": "#191817", "surface": "#2B2825", "border": "#62574B",
            "text": "#F7F3ED", "secondaryText": "#C3B8AA", "positive": "#79C8A0",
            "negative": "#F0A098", "modified": "#E6BA76", "diffAdded": "#25392E",
            "diffRemoved": "#412826", "keyword": "#CAB5E7", "string": "#8BC6B9",
            "number": "#8EBBE8", "comment": "#BAAEA1",
        ])

    subscript(_ role: ThemeColorRole) -> String {
        get { colors[role.rawValue] ?? "" }
        set { colors[role.rawValue] = newValue }
    }

    func validated() throws -> CustomTheme {
        guard version == 1 else { throw ValidationError.version }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 60, cleanName.utf8.count <= 4_096 else {
            throw ValidationError.name
        }
        guard Set(colors.keys) == Set(ThemeColorRole.allCases.map(\.rawValue)) else {
            throw ValidationError.roles
        }
        var result = self
        result.name = cleanName
        for role in ThemeColorRole.allCases {
            guard let rgb = ThemeRGB(hex: self[role]) else { throw ValidationError.color(role) }
            result[role] = rgb.hex
        }
        return result
    }

    static func decode(_ data: Data) throws -> CustomTheme {
        guard data.count <= maximumFileSize else { throw ValidationError.size }
        do {
            return try JSONDecoder().decode(CustomTheme.self, from: data).validated()
        } catch let error as ValidationError {
            throw error
        } catch { throw ValidationError.format }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(validated())
    }

    func normalizedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(validated())
    }

    var contentDigest: String {
        guard let data = try? normalizedData() else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum ValidationError: LocalizedError {
        case version, name, roles, size, format
        case color(ThemeColorRole)

        var errorDescription: String? {
            switch self {
            case .version: L10n.text("不支持此主题文件的版本。")
            case .name: L10n.text("主题名称需要 1～60 个字符。")
            case .roles: L10n.text("主题文件必须包含全部配色项目，且不能包含未知项目。")
            case .size: L10n.text("主题文件不能超过 64 KB。")
            case .format: L10n.text("无法读取主题，请选择有效的 WeGit 主题 JSON 文件。")
            case .color(let role): L10n.text("\(role.title) 需要使用 #RRGGBB 格式。")
            }
        }
    }
}

struct CustomThemeEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var theme: CustomTheme
    let createdAt: Date
    init(id: UUID = UUID(), theme: CustomTheme, createdAt: Date = Date()) {
        self.id = id
        self.theme = theme
        self.createdAt = createdAt
    }
}

struct CustomThemeLibrary: Codable, Equatable, Sendable {
    static let key = "customThemes.v1"
    static let maximumEntries = 100
    static let maximumBytes = 1024 * 1024
    var version = 1
    var activeThemeID: UUID?
    var entries: [CustomThemeEntry] = []
    // Selection and palette ID are committed in one preference value.
    var selectedAppearance: String?
    var activeTheme: CustomTheme? { entries.first { $0.id == activeThemeID }?.theme }

    func validated() throws -> Self {
        guard version == 1, entries.count <= Self.maximumEntries,
            Set(entries.map(\.id)).count == entries.count,
            activeThemeID == nil || entries.contains(where: { $0.id == activeThemeID }),
            selectedAppearance == nil || ["system", "light", "dark", "custom"].contains(selectedAppearance!)
        else { throw Failure.invalid }
        var result = self
        for index in result.entries.indices {
            result.entries[index].theme = try result.entries[index].theme.validated()
        }
        return result
    }
    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(validated())
        guard data.count <= Self.maximumBytes else { throw Failure.full }
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw Failure.invalid }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
    enum Failure: Error, LocalizedError {
        case invalid, full, changed, previewInUse
        var errorDescription: String? {
            switch self {
            case .invalid: L10n.text("主题库无法读取，原数据已保留，请先恢复主题库备份。")
            case .full: L10n.text("主题库已达到 100 项或空间上限，请先导出或删除主题。")
            case .changed: L10n.text("此主题已在其他窗口修改或删除，请重新打开。")
            case .previewInUse: L10n.text("另一个窗口正在预览主题，请先结束该预览。")
            }
        }
    }
}

struct ThemeImportPayload: Identifiable, Sendable {
    let id: String
    let theme: CustomTheme
    static let maximumPayloadBytes = 8 * 1024
    static let maximumURIBytes = 16 * 1024

    static func parse(_ url: URL) throws -> Self {
        guard url.absoluteString.utf8.count <= maximumURIBytes,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "wegit", components.host == "theme", components.path == "/import",
            components.user == nil, components.password == nil, components.port == nil,
            components.fragment == nil, let items = components.queryItems, items.count == 3,
            Set(items.map(\.name)) == ["v", "data", "sha256"]
        else { throw Failure.invalid }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard query["v"] == "1", let encoded = query["data"], let checksum = query["sha256"],
            !encoded.isEmpty, encoded.utf8.count <= 10924,
            encoded.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
            checksum.count == 64,
            checksum.allSatisfy({ $0.isASCII && ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        else { throw Failure.invalid }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count <= maximumPayloadBytes,
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
                of: "/", with: "_"
            ).replacingOccurrences(of: "=", with: "") == encoded,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == checksum
        else { throw Failure.checksum }
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any],
            Set(object.keys) == ["version", "name", "controls", "colors"]
        else { throw Failure.invalid }
        let theme = try CustomTheme.decode(data)
        return ThemeImportPayload(id: theme.contentDigest, theme: theme)
    }

    enum Failure: Error, LocalizedError {
        case invalid, checksum
        var errorDescription: String? {
            switch self {
            case .invalid: L10n.text("主题链接格式或大小无效，请改用 JSON 文件导入。")
            case .checksum: L10n.text("主题链接的内容摘要不匹配，请重新发送或下载 JSON。")
            }
        }
    }
}

struct ThemeContrastIssue: Identifiable {
    let foreground: ThemeColorRole
    let background: ThemeColorRole
    let ratio: Double
    var id: String { foreground.rawValue + ":" + background.rawValue }
}

extension CustomTheme {
    var contrastIssues: [ThemeContrastIssue] {
        let backgrounds: [ThemeColorRole] = [.canvas, .chrome, .sidebar, .surface, .diffAdded, .diffRemoved]
        var pairs = backgrounds.flatMap { background in
            [ThemeColorRole.text, .secondaryText].map { ($0, background) }
        }
        for background in [ThemeColorRole.canvas, .surface, .diffAdded, .diffRemoved] {
            pairs += [ThemeColorRole.keyword, .string, .number, .comment].map { ($0, background) }
        }
        for background in [ThemeColorRole.canvas, .chrome, .surface] {
            pairs += [ThemeColorRole.positive, .negative, .modified].map { ($0, background) }
        }
        return pairs.compactMap { foreground, background in
            guard let ink = ThemeRGB(hex: self[foreground]), let fill = ThemeRGB(hex: self[background]) else {
                return nil
            }
            let ratio = ink.contrast(with: fill)
            return ratio < 4.5
                ? ThemeContrastIssue(foreground: foreground, background: background, ratio: ratio) : nil
        }
    }
}
