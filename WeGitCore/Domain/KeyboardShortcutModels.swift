import Foundation

public struct KeyboardShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let control = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let shift = Self(rawValue: 8)
    public static let all: Self = [.command, .control, .option, .shift]
}

public struct KeyboardShortcutBinding: Codable, Hashable, Sendable {
    public let key: String
    public let modifiers: KeyboardShortcutModifiers

    public init(key: String, modifiers: KeyboardShortcutModifiers = .command) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    public var displayValue: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        switch key {
        case "\r": value += "↩"
        case "\t": value += "⇥"
        case " ": value += "Space"
        case "\u{f700}": value += "↑"
        case "\u{f701}": value += "↓"
        case "\u{f702}": value += "←"
        case "\u{f703}": value += "→"
        default:
            if let scalar = key.unicodeScalars.first, (0xf704...0xf726).contains(scalar.value) {
                value += "F\(scalar.value - 0xf704 + 1)"
            } else {
                value += key.uppercased()
            }
        }
        return value
    }

    public var isValid: Bool {
        guard key.unicodeScalars.count == 1, key == key.lowercased(),
            modifiers.rawValue & ~KeyboardShortcutModifiers.all.rawValue == 0,
            !modifiers.intersection([.command, .control]).isEmpty,
            let scalar = key.unicodeScalars.first
        else { return false }
        return key == "\r" || key == "\t" || (0x20...0x7e).contains(scalar.value)
            || (0xf700...0xf726).contains(scalar.value)
    }
}

public struct KeyboardShortcutCommand: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let defaultBinding: KeyboardShortcutBinding?
    public init(id: String, title: String, defaultBinding: KeyboardShortcutBinding? = nil) {
        self.id = id
        self.title = title
        self.defaultBinding = defaultBinding
    }
}

/// A missing override uses the default; an explicit nil disables that shortcut.
public struct KeyboardShortcutOverride: Codable, Equatable, Sendable {
    public let binding: KeyboardShortcutBinding?
    public init(binding: KeyboardShortcutBinding?) { self.binding = binding }
}

public enum KeyboardShortcutConflict: Error, LocalizedError, Equatable, Sendable {
    case invalid, unknownCommand, reserved
    case command(String)
    public var errorDescription: String? {
        switch self {
        case .invalid: L10n.text("请选择包含 Command 或 Control 的有效快捷键。")
        case .unknownCommand: L10n.text("此命令无法修改快捷键。")
        case .reserved: L10n.text("此快捷键由 macOS 或系统编辑操作使用。")
        case .command(let title): L10n.text("此快捷键已用于“\(L10n.key(title))”。")
        }
    }
}

public enum KeyboardShortcutValidation {
    public static func check(
        _ binding: KeyboardShortcutBinding?, for commandID: String,
        catalog: [KeyboardShortcutCommand], overrides: [String: KeyboardShortcutOverride]
    ) throws {
        guard catalog.contains(where: { $0.id == commandID }) else {
            throw KeyboardShortcutConflict.unknownCommand
        }
        guard let binding else { return }
        guard binding.isValid else { throw KeyboardShortcutConflict.invalid }
        guard !isReserved(binding) else { throw KeyboardShortcutConflict.reserved }
        for command in catalog where command.id != commandID {
            let effective = overrides[command.id].map(\.binding) ?? command.defaultBinding
            if effective == binding { throw KeyboardShortcutConflict.command(command.title) }
        }
    }

    public static func isReserved(_ binding: KeyboardShortcutBinding) -> Bool {
        let modifiers = binding.modifiers
        // Keep responder editing, window management and macOS activation intact.
        let fixed: Set<KeyboardShortcutBinding> = [
            .init(key: "z"), .init(key: "z", modifiers: [.command, .shift]),
            .init(key: "x"), .init(key: "c"), .init(key: "v"), .init(key: "a"), .init(key: "f"),
            .init(key: "v", modifiers: [.command, .option, .shift]), .init(key: ","),
            .init(key: "w"), .init(key: "w", modifiers: [.command, .option]), .init(key: "q"),
            .init(key: "h"), .init(key: "h", modifiers: [.command, .option]), .init(key: "m"),
            .init(key: "m", modifiers: [.command, .option]),
            .init(key: "f", modifiers: [.command, .control]),
            .init(key: " ", modifiers: [.command, .control]),
        ]
        if fixed.contains(binding) { return true }
        if modifiers.contains(.command) && ["\t", " ", "`"].contains(binding.key) { return true }
        if !modifiers.intersection([.command, .control]).isEmpty,
            ["\u{f700}", "\u{f701}", "\u{f702}", "\u{f703}"].contains(binding.key)
        {
            return true
        }
        if modifiers.contains(.command) && modifiers.contains(.shift)
            && ["3", "4", "5"].contains(binding.key)
        {
            return true
        }
        if modifiers.contains(.control) && modifiers.contains(.option) { return true }
        if modifiers == .control {
            return "abdefhklnoptuvwy".contains(binding.key) || binding.key == " " || binding.key == "\t"
        }
        return false
    }
}
