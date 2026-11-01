import Foundation
import Testing

@testable import WeGitCore

private struct FailRemotePrivateWrite: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("--file")
            && request.arguments.contains(where: { $0.hasSuffix(".pushurl") })
        {
            throw ProcessFailure.timedOut
        }
        return try await ProcessRunner().run(request)
    }
}

private actor ReplaceConfigParent: ProcessRunning {
    let git: URL
    let parked: URL
    let outside: URL
    private var moved = false
    init(root: URL, outside: URL) {
        git = root.appending(path: ".git")
        parked = root.appending(path: "parked-git")
        self.outside = outside
    }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await ProcessRunner().run(request)
        if !moved && request.arguments.contains("--file") {
            try FileManager.default.moveItem(at: git, to: parked)
            try FileManager.default.createSymbolicLink(at: git, withDestinationURL: outside)
            moved = true
        }
        return result
    }
    func restore() throws {
        guard moved else { return }
        try FileManager.default.removeItem(at: git)
        try FileManager.default.moveItem(at: parked, to: git)
    }
}

struct RemoteManagementTests {
    @Test func opaqueURLQueriesAndFragmentsAreNeverShownOrLogged() {
        for url in [
            "https://example.invalid/a?sig=fixture-signature", "ssh://git@example.invalid/a#fixture-fragment",
            "ssh://user:fixture-password@example.invalid/a",
        ] {
            let display = Redaction.text(url)
            #expect(!display.contains("fixture-signature"))
            #expect(!display.contains("fixture-fragment"))
            #expect(!display.contains("fixture-password"))
        }
        #expect(Redaction.text("ssh://git@example.invalid/a") == "ssh://git@example.invalid/a")
    }
    @Test func addressEditsPreserveOtherConfigAndDistinctSubsections() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let service = fixture.service
        try await service.changeRemote(
            .add(
                name: "origin", fetchURL: "https://example.invalid/a.git",
                pushURL: "git@example.invalid:a.git"), in: service.remoteManagement(), expectedHead: nil)
        _ = try await fixture.engine.run(["config", "remote.origin.tagopt", "--no-tags"], in: fixture.root)
        let snapshot = try await service.remoteManagement()
        try await service.changeRemote(
            .add(name: "origin.child", fetchURL: "https://example.invalid/child.git", pushURL: nil),
            in: snapshot, expectedHead: nil)
        let before = try await service.remoteManagement()
        #expect(
            before.remotes.first { $0.name == "origin" }?.values.contains {
                $0.key.hasPrefix("remote.origin.child.")
            } == false)
        try await service.changeRemote(
            .update(name: "origin", fetchURL: "https://example.invalid/b.git", pushURL: nil), in: before,
            expectedHead: nil)
        let details = try await service.remoteDetails(name: "origin")
        #expect(details.fetchURL == "https://example.invalid/b.git")
        #expect(details.pushURLs == [details.fetchURL])
        #expect(
            try await fixture.engine.run(["config", "--get", "remote.origin.tagopt"], in: fixture.root).stdout
                == Data("--no-tags\n".utf8))
        #expect(try await service.remoteManagement().remotes.contains { $0.name == "origin.child" })
    }

    @Test func staleConfigurationAndMultipleAddressesCannotBeOverwritten() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let service = fixture.service
        let empty = try await service.remoteManagement()
        _ = try await fixture.engine.run(
            ["remote", "add", "outside", "https://example.invalid/outside.git"], in: fixture.root)
        do {
            try await service.changeRemote(
                .add(name: "origin", fetchURL: "https://example.invalid/a.git", pushURL: nil), in: empty,
                expectedHead: nil)
            Issue.record("A changed config must reject an old editor snapshot")
        } catch ModelFailure.changed {}
        _ = try await fixture.engine.run(
            ["config", "--add", "remote.outside.url", "https://example.invalid/second.git"], in: fixture.root)
        let multi = try await service.remoteManagement()
        #expect(multi.remotes.first?.fetchURLs.count == 2)
        #expect(multi.remotes.first?.canEdit == false)
        let bytes = try Data(contentsOf: fixture.root.appending(path: ".git/config"))
        do {
            try await service.changeRemote(.remove(name: "outside"), in: multi, expectedHead: nil)
            Issue.record("A multi-address remote must not be reduced by the simple editor")
        } catch ModelFailure.changed {}
        #expect(try Data(contentsOf: fixture.root.appending(path: ".git/config")) == bytes)
    }

    @Test func failingSecondPrivateEditLeavesOriginalBytesAndNoOwnedLock() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let service = fixture.service
        try await service.changeRemote(
            .add(name: "origin", fetchURL: "https://example.invalid/a.git", pushURL: nil),
            in: service.remoteManagement(), expectedHead: nil)
        let snapshot = try await service.remoteManagement()
        let config = fixture.root.appending(path: ".git/config")
        let bytes = try Data(contentsOf: config)
        let failing = RepositoryService(
            location: service.location, engine: TestGit.engine(runner: FailRemotePrivateWrite()))
        do {
            try await failing.changeRemote(
                .update(
                    name: "origin", fetchURL: "https://example.invalid/b.git",
                    pushURL: "git@example.invalid:b.git"), in: snapshot, expectedHead: nil)
            Issue.record("Injected timeout must escape")
        } catch ProcessFailure.timedOut {}
        #expect(try Data(contentsOf: config) == bytes)
        #expect(!FileManager.default.fileExists(atPath: config.path + ".lock"))
    }

    @Test func inheritedConfigAndCredentialsStayReadOnlyAndRedacted() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let global = try TestGitConfiguration()
        let bytes = Data("[remote \"inherited\"]\n url = https://example.invalid/shared.git\n".utf8)
        try bytes.write(to: global.file)
        let service = RepositoryService(
            location: fixture.service.location, engine: TestGit.engine(globalConfiguration: global))
        let inherited = try await service.remoteManagement()
        #expect(inherited.remotes.first?.canEdit == false)
        #expect(inherited.remotes.first?.values.first?.scope == "global")
        try await service.changeRemote(
            .add(
                name: "local", fetchURL: "https://fixture:fixture-password@example.invalid/private.git",
                pushURL: nil), in: inherited, expectedHead: nil)
        let remote = try await service.remoteManagement().remotes.first { $0.name == "local" }
        #expect(remote?.canEdit == false)
        #expect(remote?.displayFetchURLs.first?.contains("fixture-password") == false)
        #expect(try Data(contentsOf: global.file) == bytes)
    }
    @Test func directoryReplacementCannotRedirectConfigWritesOrLockCleanup() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let outside = fixture.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let protected = Data("[protected]\n value = keep\n".utf8)
        try protected.write(to: outside.appending(path: "config"))
        let snapshot = try await fixture.service.remoteManagement()
        let config = fixture.root.appending(path: ".git/config")
        let before = try Data(contentsOf: config)
        let runner = ReplaceConfigParent(root: fixture.root, outside: outside)
        let service = RepositoryService(
            location: fixture.service.location, engine: TestGit.engine(runner: runner))
        var rejected = false
        do {
            try await service.changeRemote(
                .add(name: "origin", fetchURL: "https://example.invalid/a.git", pushURL: nil), in: snapshot,
                expectedHead: nil)
        } catch { rejected = true }
        try await runner.restore()
        #expect(rejected)
        #expect(try Data(contentsOf: config) == before)
        #expect(try Data(contentsOf: outside.appending(path: "config")) == protected)
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "config.lock").path))
        #expect(!FileManager.default.fileExists(atPath: config.path + ".lock"))
    }

}
