import Foundation
import Testing

@testable import WeGitCore

struct KeyboardShortcutTests {
    private var catalog: [KeyboardShortcutCommand] {
        [
            .init(
                id: "search", title: "Search", defaultBinding: .init(key: "f", modifiers: [.command, .shift])),
            .init(id: "refresh", title: "Refresh", defaultBinding: .init(key: "r")),
            .init(id: "stage", title: "Stage"),
        ]
    }

    @Test func normalizesKeysAndRejectsSystemEditingAndUnmodifiedTyping() throws {
        #expect(KeyboardShortcutBinding(key: "R").key == "r")
        #expect(KeyboardShortcutBinding(key: "R").displayValue == "⌘R")
        for binding in [
            KeyboardShortcutBinding(key: "c"), .init(key: "z", modifiers: [.command, .shift]),
            .init(key: "f"), .init(key: " "), .init(key: "a", modifiers: .control),
            .init(key: "k", modifiers: [.control, .option]),
            .init(key: "\u{f702}", modifiers: [.command, .shift]), .init(key: "`"),
        ] {
            #expect(throws: KeyboardShortcutConflict.reserved) {
                try KeyboardShortcutValidation.check(binding, for: "stage", catalog: catalog, overrides: [:])
            }
        }
        #expect(throws: KeyboardShortcutConflict.invalid) {
            try KeyboardShortcutValidation.check(
                .init(key: "r", modifiers: .shift), for: "stage", catalog: catalog, overrides: [:])
        }
    }

    @Test @MainActor func persistsClearedShortcutWithoutFallingBackToDefault() throws {
        let domain = "WeGit.ShortcutTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("original", forKey: "draft-v2:private")
        let store = try KeyboardShortcutPersistence(defaults: defaults, catalog: catalog)
        try store.set(nil, for: "search")
        #expect(store.binding(for: "search") == nil)
        let read = try KeyboardShortcutPersistence(defaults: defaults, catalog: catalog)
        #expect(read.binding(for: "search") == nil)
        #expect(read.overrides["search"] != nil)
        #expect(defaults.string(forKey: "draft-v2:private") == "original")
        try read.restoreAll()
        #expect(read.binding(for: "search") == catalog[0].defaultBinding)
    }

    @Test @MainActor func conflictsCoverDefaultsOverridesAndIndividualRestore() throws {
        let domain = "WeGit.ShortcutTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = try KeyboardShortcutPersistence(defaults: defaults, catalog: catalog)
        #expect(throws: KeyboardShortcutConflict.command("Refresh")) {
            try store.set(.init(key: "r"), for: "stage")
        }
        try store.set(nil, for: "refresh")
        try store.set(.init(key: "r"), for: "stage")
        #expect(throws: KeyboardShortcutConflict.command("Stage")) { try store.restore("refresh") }
        #expect(store.binding(for: "refresh") == nil)
        #expect(store.binding(for: "stage") == .init(key: "r"))
    }

    @Test @MainActor func malformedAndExternallyChangedBytesRemainUntouched() throws {
        let domain = "WeGit.ShortcutTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let bad = Data("{\"format\":99,\"overrides\":{}}".utf8)
        defaults.set(bad, forKey: KeyboardShortcutPersistence.storageKey)
        #expect(throws: KeyboardShortcutPersistence.Failure.self) {
            _ = try KeyboardShortcutPersistence(defaults: defaults, catalog: catalog)
        }
        #expect(defaults.data(forKey: KeyboardShortcutPersistence.storageKey) == bad)
        defaults.removeObject(forKey: KeyboardShortcutPersistence.storageKey)
        let first = try KeyboardShortcutPersistence(defaults: defaults, catalog: catalog)
        let second = try KeyboardShortcutPersistence(defaults: defaults, catalog: catalog)
        try second.set(.init(key: "j"), for: "stage")
        let saved = defaults.data(forKey: KeyboardShortcutPersistence.storageKey)
        #expect(throws: KeyboardShortcutPersistence.Failure.self) {
            try first.set(.init(key: "b"), for: "stage")
        }
        #expect(defaults.data(forKey: KeyboardShortcutPersistence.storageKey) == saved)
    }
}
