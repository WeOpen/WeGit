import CryptoKit
import Foundation

public struct WindowReadingSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public var repository: String?
    public var workspaceID: String?
    public var view: Data?
    public var history: Data?
    public var selectedCommit: String?
    public var open: Bool
    public var updated: Date

    public init(
        id: UUID, repository: String? = nil, workspaceID: String? = nil, view: Data? = nil,
        history: Data? = nil, selectedCommit: String? = nil, open: Bool = true, updated: Date = Date()
    ) {
        self.id = id
        self.repository = repository
        self.workspaceID = workspaceID
        self.view = view
        self.history = history
        self.selectedCommit = selectedCommit
        self.open = open
        self.updated = updated
    }
}

public struct SharedDraftSnapshot: Codable, Equatable, Sendable {
    public let format: Int
    public let revision: UInt64
    public let text: String
    public let amend: Bool?
    public init(revision: UInt64, text: String, amend: Bool = false) {
        format = 2
        self.revision = revision
        self.text = text
        self.amend = amend
    }
}

/// Window routes and shared drafts use a new namespace. The original preference
/// domain is backed up before the first v2 write, and legacy draft bytes stay intact.
@MainActor public final class WindowSessionPersistence {
    public enum Failure: LocalizedError {
        case invalid, exceeded, changed
        public var errorDescription: String? {
            switch self {
            case .invalid: L10n.text("窗口或草稿数据无法读取，原始设置已保留。")
            case .exceeded: L10n.text("窗口或草稿数据超过保存上限，原始设置已保留。")
            case .changed: L10n.text("设置数据在保存期间变化，请核对后重试。")
            }
        }
    }

    private struct State: Codable {
        var format = 2
        var primary = UUID()
        var lastActive: UUID?
        var windows: [WindowReadingSnapshot] = []
    }

    private static let stateKey = "v2.window-sessions"
    private static let backupKey = "v2.original-preferences"
    private static let backupHashKey = "v2.original-preferences.sha256"
    private static let draftPrefix = "v2.shared-draft:"
    private let defaults: UserDefaults
    private var state: State
    private var stateBytes: Data?
    public var primaryID: UUID { state.primary }
    public var lastActiveID: UUID? { state.lastActive }
    public var windows: [WindowReadingSnapshot] { state.windows }

    public init(defaults: UserDefaults, domainName: String? = nil) throws {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.stateKey) {
            guard data.count <= 4 * 1024 * 1024,
                let decoded = try? JSONDecoder().decode(State.self, from: data)
            else { throw Failure.invalid }
            try Self.validate(decoded)
            state = decoded
            stateBytes = data
        } else {
            state = State()
            try backupOriginalDomain(domainName)
            try write(state)
            try flush()
        }
    }

    public func snapshot(_ id: UUID) -> WindowReadingSnapshot? {
        state.windows.first { $0.id == id }
    }

    public func save(_ snapshot: WindowReadingSnapshot, active: Bool = false) throws {
        var next = state
        next.windows.removeAll { $0.id == snapshot.id }
        next.windows.append(snapshot)
        if active { next.lastActive = snapshot.id }
        next.windows.sort { $0.updated > $1.updated }
        while next.windows.count > 32 {
            guard let index = next.windows.lastIndex(where: { !$0.open && $0.id != next.primary }) else {
                throw Failure.exceeded
            }
            next.windows.remove(at: index)
        }
        try write(next)
        state = next
    }

    public func setClosed(_ id: UUID) throws {
        guard var snapshot = snapshot(id) else { return }
        snapshot.open = false
        snapshot.updated = Date()
        try save(snapshot)
    }

    public func readDraft(workspaceID: String, legacyKey: String) throws -> SharedDraftSnapshot? {
        try Self.validateWorkspaceID(workspaceID)
        let key = Self.draftPrefix + workspaceID
        guard defaults.object(forKey: key) == nil || defaults.data(forKey: key) != nil else {
            throw Failure.invalid
        }
        if let data = defaults.data(forKey: key) {
            guard data.count <= 2 * 1024 * 1024,
                let draft = try? JSONDecoder().decode(SharedDraftSnapshot.self, from: data),
                draft.format == 2, draft.text.utf8.count <= 1024 * 1024,
                draft.revision < UInt64.max
            else { throw Failure.invalid }
            return draft
        }
        guard let legacy = defaults.string(forKey: legacyKey) else { return nil }
        guard legacy.utf8.count <= 1024 * 1024 else { throw Failure.exceeded }
        return SharedDraftSnapshot(revision: 0, text: legacy)
    }

    public func saveDraft(_ draft: SharedDraftSnapshot, workspaceID: String) throws {
        try Self.validateWorkspaceID(workspaceID)
        let key = Self.draftPrefix + workspaceID
        guard defaults.object(forKey: key) == nil || defaults.data(forKey: key) != nil else {
            throw Failure.invalid
        }
        guard draft.format == 2, draft.revision < UInt64.max,
            draft.text.utf8.count <= 1024 * 1024
        else { throw Failure.exceeded }
        if let bytes = defaults.data(forKey: key) {
            guard bytes.count <= 2 * 1024 * 1024,
                let current = try? JSONDecoder().decode(SharedDraftSnapshot.self, from: bytes),
                current.format == 2, current.revision < UInt64.max,
                current.text.utf8.count <= 1024 * 1024,
                current == draft || current.revision < draft.revision
            else { throw Failure.changed }
        }
        let data = try JSONEncoder().encode(draft)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else { throw Failure.changed }
    }

    public func removeDraft(workspaceID: String, matching draft: SharedDraftSnapshot) throws {
        try Self.validateWorkspaceID(workspaceID)
        let key = Self.draftPrefix + workspaceID
        guard let data = defaults.data(forKey: key),
            let current = try? JSONDecoder().decode(SharedDraftSnapshot.self, from: data), current == draft
        else { return }
        defaults.removeObject(forKey: key)
    }

    public func flush() throws {
        try validateCurrentState()
        guard defaults.synchronize() else { throw Failure.changed }
        try validateCurrentState()
    }

    /// Returns the original property-list bytes for an explicit rollback. It does
    /// not replace a running application's preference domain.
    public func originalPreferences() throws -> Data {
        guard let bytes = defaults.data(forKey: Self.backupKey),
            let expected = defaults.string(forKey: Self.backupHashKey), Self.digest(bytes) == expected,
            let dictionary = try PropertyListSerialization.propertyList(from: bytes, format: nil)
                as? [String: Any], dictionary["format"] as? Int == 1,
            dictionary["values"] as? [String: Any] != nil
        else { throw Failure.invalid }
        return bytes
    }

    private func backupOriginalDomain(_ domainName: String?) throws {
        if defaults.object(forKey: Self.backupKey) != nil {
            _ = try originalPreferences()
            return
        }
        let original: [String: Any]
        if let domainName {
            original = defaults.persistentDomain(forName: domainName) ?? [:]
        } else {
            // Injected test stores may not expose their domain name. Only the
            // legacy keys owned by this component are eligible for that fallback.
            original = defaults.dictionaryRepresentation().filter {
                $0.key == "lastRepository" || $0.key.hasPrefix("workspace:")
                    || $0.key.hasPrefix("draft:") || $0.key.hasPrefix("draft-v2:")
            }
        }
        let backup = try PropertyListSerialization.data(
            fromPropertyList: ["format": 1, "created": Date(), "values": original],
            format: .binary, options: 0)
        guard backup.count <= 8 * 1024 * 1024 else { throw Failure.exceeded }
        defaults.set(backup, forKey: Self.backupKey)
        defaults.set(Self.digest(backup), forKey: Self.backupHashKey)
        try flush()
        guard defaults.data(forKey: Self.backupKey) == backup else { throw Failure.changed }
    }

    private func write(_ next: State) throws {
        try Self.validate(next)
        try validateCurrentState()
        let data = try JSONEncoder().encode(next)
        guard data.count <= 4 * 1024 * 1024 else { throw Failure.exceeded }
        defaults.set(data, forKey: Self.stateKey)
        guard defaults.data(forKey: Self.stateKey) == data else { throw Failure.changed }
        stateBytes = data
    }

    private func validateCurrentState() throws {
        guard defaults.data(forKey: Self.stateKey) == stateBytes,
            stateBytes != nil || defaults.object(forKey: Self.stateKey) == nil
        else { throw Failure.changed }
    }

    private static func validateWorkspaceID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 512, !id.contains("\0") else { throw Failure.invalid }
    }

    private static func validate(_ state: State) throws {
        guard state.format == 2, state.windows.count <= 32,
            Set(state.windows.map(\.id)).count == state.windows.count,
            state.lastActive == nil || state.lastActive == state.primary
                || state.windows.contains(where: { $0.id == state.lastActive })
        else { throw Failure.invalid }
        for window in state.windows {
            if let repository = window.repository {
                guard repository.hasPrefix("/"), repository.utf8.count <= 4096,
                    !repository.contains("\0")
                else { throw Failure.invalid }
            }
            if let id = window.workspaceID { try validateWorkspaceID(id) }
            guard window.view?.count ?? 0 <= 64 * 1024, window.history?.count ?? 0 <= 64 * 1024,
                window.selectedCommit == nil || GitObjectID.valid(window.selectedCommit!)
            else { throw Failure.exceeded }
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
