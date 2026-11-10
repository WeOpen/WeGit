import Foundation

/// This store only owns its v2 key. Invalid or externally changed bytes are never replaced.
@MainActor public final class KeyboardShortcutPersistence {
    public enum Failure: Error, LocalizedError {
        case invalid, changed
        public var errorDescription: String? {
            switch self {
            case .invalid: L10n.text("快捷键设置无法读取，原始数据已保留。")
            case .changed: L10n.text("快捷键设置已被其他窗口修改，请重新载入。")
            }
        }
    }
    public static let storageKey = "v2.keyboard-shortcuts"
    private struct State: Codable {
        var format = 1
        var overrides: [String: KeyboardShortcutOverride] = [:]
    }
    public let catalog: [KeyboardShortcutCommand]
    public private(set) var overrides: [String: KeyboardShortcutOverride]
    private let defaults: UserDefaults
    private var original: Data?

    public init(defaults: UserDefaults, catalog: [KeyboardShortcutCommand]) throws {
        self.defaults = defaults
        self.catalog = catalog
        guard catalog.count <= 256, Set(catalog.map(\.id)).count == catalog.count,
            catalog.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 })
        else { throw Failure.invalid }
        if defaults.object(forKey: Self.storageKey) != nil && defaults.data(forKey: Self.storageKey) == nil {
            throw Failure.invalid
        }
        original = defaults.data(forKey: Self.storageKey)
        if let original {
            guard original.count <= 64 * 1024,
                let state = try? JSONDecoder().decode(State.self, from: original), state.format == 1,
                state.overrides.count <= catalog.count
            else { throw Failure.invalid }
            overrides = state.overrides
        } else {
            overrides = [:]
        }
        try validate(overrides)
    }

    public func binding(for commandID: String) -> KeyboardShortcutBinding? {
        if let override = overrides[commandID] { return override.binding }
        return catalog.first(where: { $0.id == commandID })?.defaultBinding
    }

    public func set(_ binding: KeyboardShortcutBinding?, for commandID: String) throws {
        try KeyboardShortcutValidation.check(binding, for: commandID, catalog: catalog, overrides: overrides)
        var next = overrides
        if binding == catalog.first(where: { $0.id == commandID })?.defaultBinding {
            next.removeValue(forKey: commandID)
        } else {
            next[commandID] = KeyboardShortcutOverride(binding: binding)
        }
        try write(next)
    }

    public func restore(_ commandID: String) throws {
        guard let command = catalog.first(where: { $0.id == commandID }) else {
            throw KeyboardShortcutConflict.unknownCommand
        }
        try set(command.defaultBinding, for: commandID)
    }

    public func restoreAll() throws { try write([:]) }

    private func validate(_ values: [String: KeyboardShortcutOverride]) throws {
        for command in catalog {
            let binding = values[command.id].map(\.binding) ?? command.defaultBinding
            try KeyboardShortcutValidation.check(
                binding, for: command.id, catalog: catalog, overrides: values)
        }
        guard values.keys.allSatisfy({ id in catalog.contains(where: { $0.id == id }) }) else {
            throw Failure.invalid
        }
    }

    private func write(_ values: [String: KeyboardShortcutOverride]) throws {
        try validate(values)
        guard defaults.data(forKey: Self.storageKey) == original,
            original != nil || defaults.object(forKey: Self.storageKey) == nil
        else { throw Failure.changed }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(State(overrides: values))
        guard data.count <= 64 * 1024 else { throw Failure.invalid }
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.data(forKey: Self.storageKey) == data else { throw Failure.changed }
        original = data
        overrides = values
    }
}
