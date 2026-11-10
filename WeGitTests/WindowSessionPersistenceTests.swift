import Foundation
import Testing

@testable import WeGitCore

struct WindowSessionPersistenceTests {
    @Test @MainActor func migrationKeepsOriginalPreferencesAndLegacyDraftBytes() throws {
        let domain = "WeGit.WindowSessionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let original: [String: Any] = [
            "appearance": "custom", "draft-v2:private": "中文\r\nlast",
            "customTheme": Data([0, 1, 2, 255]), "lastRepository": "/private/fixture",
        ]
        defaults.setPersistentDomain(original, forName: domain)
        let store = try WindowSessionPersistence(defaults: defaults, domainName: domain)
        let draft = try #require(try store.readDraft(workspaceID: "private", legacyKey: "draft-v2:private"))
        #expect(draft.text == "中文\r\nlast")
        try store.saveDraft(SharedDraftSnapshot(revision: 1, text: "new draft"), workspaceID: "private")
        #expect(defaults.string(forKey: "draft-v2:private") == "中文\r\nlast")
        let backup = try #require(
            PropertyListSerialization.propertyList(from: store.originalPreferences(), format: nil)
                as? [String: Any])
        let saved = try #require(backup["values"] as? [String: Any])
        #expect(saved["customTheme"] as? Data == Data([0, 1, 2, 255]))
        #expect(saved["appearance"] as? String == "custom")
    }

    @Test @MainActor func closingOneWindowKeepsTheOtherRouteAndOriginalPrimaryIdentity() throws {
        let domain = "WeGit.WindowSessionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = try WindowSessionPersistence(defaults: defaults, domainName: domain)
        let first = store.primaryID
        let second = UUID()
        try store.save(
            WindowReadingSnapshot(id: first, repository: "/private/first", view: Data("first".utf8)))
        try store.save(
            WindowReadingSnapshot(id: second, repository: "/private/second", view: Data("second".utf8)),
            active: true)
        try store.setClosed(first)
        try store.flush()
        let reopened = try WindowSessionPersistence(defaults: defaults, domainName: domain)
        #expect(reopened.primaryID == first)
        #expect(reopened.snapshot(first)?.open == false)
        #expect(reopened.snapshot(second)?.open == true)
        #expect(reopened.snapshot(second)?.view == Data("second".utf8))
        #expect(reopened.lastActiveID == second)
    }

    @Test @MainActor func staleDraftRevisionCannotReplaceNewerTextOrRemoveIt() throws {
        let domain = "WeGit.WindowSessionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = try WindowSessionPersistence(defaults: defaults, domainName: domain)
        let newer = SharedDraftSnapshot(revision: 2, text: "newer", amend: true)
        try store.saveDraft(newer, workspaceID: "private")
        #expect(throws: WindowSessionPersistence.Failure.self) {
            try store.saveDraft(SharedDraftSnapshot(revision: 1, text: "stale"), workspaceID: "private")
        }
        try store.removeDraft(
            workspaceID: "private", matching: SharedDraftSnapshot(revision: 1, text: "stale"))
        #expect(try store.readDraft(workspaceID: "private", legacyKey: "draft-v2:private") == newer)
    }

    @Test @MainActor func malformedWindowDataAndChangedBackupRemainUntouched() throws {
        let domain = "WeGit.WindowSessionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let invalid = Data("{\"format\":99}".utf8)
        defaults.set(invalid, forKey: "v2.window-sessions")
        #expect(throws: WindowSessionPersistence.Failure.self) {
            _ = try WindowSessionPersistence(defaults: defaults, domainName: domain)
        }
        #expect(defaults.data(forKey: "v2.window-sessions") == invalid)
        defaults.removeObject(forKey: "v2.window-sessions")
        let store = try WindowSessionPersistence(defaults: defaults, domainName: domain)
        defaults.set(Data("changed".utf8), forKey: "v2.original-preferences")
        #expect(throws: WindowSessionPersistence.Failure.self) { _ = try store.originalPreferences() }
        #expect(defaults.data(forKey: "v2.original-preferences") == Data("changed".utf8))
    }
}
