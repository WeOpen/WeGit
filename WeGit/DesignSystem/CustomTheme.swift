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
        version: 1, name: "Graphite", controls: .dark,
        colors: [
            "accent": "#5B8DEF", "canvas": "#171B24", "chrome": "#171B24",
            "sidebar": "#202633", "surface": "#252D3B", "border": "#3C4659",
            "text": "#E9EDF5", "secondaryText": "#A5B0C2", "positive": "#79C8A0",
            "negative": "#ED8A96", "modified": "#D7B174", "diffAdded": "#20392F",
            "diffRemoved": "#3B262C", "keyword": "#C1A7EE", "string": "#D8B68A",
            "number": "#88B9E8", "comment": "#9BA8B9",
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
