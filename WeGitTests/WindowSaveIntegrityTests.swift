import Foundation
import Testing

@testable import WeGitCore

struct WindowSaveIntegrityTests {
    @Test @MainActor func oversizedDecodedDraftCannotBeReplacedAfterFailedLoad() throws {
        let domain = "WeGit.WindowIntegrityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = try WindowSessionPersistence(defaults: defaults, domainName: domain)
        let oversized = try JSONEncoder().encode(
            SharedDraftSnapshot(revision: 0, text: String(repeating: "x", count: 1024 * 1024 + 1)))
        defaults.set(oversized, forKey: "v2.shared-draft:private")
        #expect(throws: WindowSessionPersistence.Failure.self) {
            _ = try store.readDraft(workspaceID: "private", legacyKey: "draft-v2:private")
        }
        #expect(throws: WindowSessionPersistence.Failure.self) {
            try store.saveDraft(
                SharedDraftSnapshot(revision: 1, text: "small replacement"), workspaceID: "private")
        }
        #expect(defaults.data(forKey: "v2.shared-draft:private") == oversized)
    }

    @Test @MainActor func invalidNewRouteLeavesLastSavedWindowAndBytesUnchanged() throws {
        let domain = "WeGit.WindowIntegrityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = try WindowSessionPersistence(defaults: defaults, domainName: domain)
        let original = WindowReadingSnapshot(
            id: store.primaryID, repository: "/private/first", view: Data("good".utf8),
            selectedCommit: String(repeating: "a", count: 40))
        try store.save(original)
        let originalBytes = defaults.data(forKey: "v2.window-sessions")
        var invalid = original
        invalid.view = Data(repeating: 120, count: 64 * 1024 + 1)
        invalid.open = false
        #expect(throws: WindowSessionPersistence.Failure.self) { try store.save(invalid) }
        #expect(store.snapshot(store.primaryID) == original)
        #expect(defaults.data(forKey: "v2.window-sessions") == originalBytes)
    }

    @Test @MainActor func changedWindowBytesBlockSaveCloseAndFlushWithoutOverwrite() throws {
        let domain = "WeGit.WindowIntegrityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = try WindowSessionPersistence(defaults: defaults, domainName: domain)
        try store.save(WindowReadingSnapshot(id: store.primaryID, repository: "/private/first"))
        let changed = Data("changed outside".utf8)
        defaults.set(changed, forKey: "v2.window-sessions")
        #expect(throws: WindowSessionPersistence.Failure.self) { try store.setClosed(store.primaryID) }
        #expect(throws: WindowSessionPersistence.Failure.self) { try store.flush() }
        #expect(store.snapshot(store.primaryID)?.open == true)
        #expect(defaults.data(forKey: "v2.window-sessions") == changed)
    }

    @Test @MainActor func nonDataDraftCannotFallBackToLegacyOrBeOverwritten() throws {
        let domain = "WeGit.WindowIntegrityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = try WindowSessionPersistence(defaults: defaults, domainName: domain)
        defaults.set("legacy", forKey: "draft-v2:private")
        defaults.set("invalid stored kind", forKey: "v2.shared-draft:private")
        #expect(throws: WindowSessionPersistence.Failure.self) {
            _ = try store.readDraft(workspaceID: "private", legacyKey: "draft-v2:private")
        }
        #expect(throws: WindowSessionPersistence.Failure.self) {
            try store.saveDraft(SharedDraftSnapshot(revision: 1, text: "new"), workspaceID: "private")
        }
        #expect(defaults.string(forKey: "v2.shared-draft:private") == "invalid stored kind")
        #expect(defaults.string(forKey: "draft-v2:private") == "legacy")
    }
}
