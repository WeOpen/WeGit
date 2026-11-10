import Foundation
import Testing

@testable import WeGitCore

private actor DisableWorktreeConfigDuringEdit: ProcessRunning {
    let engine: GitEngine
    let root: URL
    init(engine: GitEngine, root: URL) {
        self.engine = engine
        self.root = root
    }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await ProcessRunner().run(request)
        if request.arguments.contains("--file"), request.arguments.contains("--replace-all"),
            result.exitCode == 0
        {
            _ = try await engine.run(["config", "--local", "extensions.worktreeConfig", "false"], in: root)
        }
        return result
    }
}

struct GitConfigurationTests {
    @Test func signingOverridesInLinkedWorktreeDoNotChangeSharedConfiguration() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "original\n")
        let head = try await f.commit("Base")
        _ = try await f.engine.run(["config", "--local", "extensions.worktreeConfig", "true"], in: f.root)
        let primary = try service(f)
        _ = try await primary.set("true", scope: .local, expected: primary.read(.commitSigning))
        let linked = f.root.appending(path: "linked")
        _ = try await f.engine.run(["worktree", "add", "--detach", linked.path, head], in: f.root)
        let location = try await RepositoryService.discover(linked, engine: f.engine)
        let settings = GitConfigurationService(
            engine: TestGit.engine(
                environment: f.engine.environment, globalConfiguration: try TestGitConfiguration()),
            location: location)
        let shared = try Data(contentsOf: f.service.location.commonDirectory.appending(path: "config"))
        let index = try Data(contentsOf: location.gitDirectory.appending(path: "index"))
        let before = try await settings.read(.commitSigning)
        #expect(before.worktreeConfigEnabled && before.effective?.scope == "local")
        let updated = try await settings.set("false", scope: .worktree, expected: before)
        #expect(updated.worktreeValues == ["false"] && updated.effective?.scope == "worktree")
        #expect(try await primary.read(.commitSigning).effective?.value == "true")
        #expect(try Data(contentsOf: f.service.location.commonDirectory.appending(path: "config")) == shared)
        #expect(try Data(contentsOf: location.gitDirectory.appending(path: "index")) == index)
        let inherited = try await settings.set(nil, scope: .worktree, expected: updated)
        #expect(inherited.worktreeValues.isEmpty && inherited.effective?.value == "true")
        #expect(
            !FileManager.default.fileExists(
                atPath: location.gitDirectory.appending(path: "config.worktree.lock").path))
    }

    @Test func disablingWorktreeConfigurationInvalidatesAnOlderConfirmation() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let settings = try service(f)
        _ = try await f.engine.run(["config", "--local", "extensions.worktreeConfig", "true"], in: f.root)
        let snapshot = try await settings.read(.commitSigning)
        _ = try await f.engine.run(["config", "--local", "extensions.worktreeConfig", "false"], in: f.root)
        let original = try Data(contentsOf: f.service.location.commonDirectory.appending(path: "config"))
        await #expect(throws: ModelFailure.self) {
            _ = try await settings.set("true", scope: .worktree, expected: snapshot)
        }
        #expect(
            try Data(contentsOf: f.service.location.commonDirectory.appending(path: "config")) == original)
        #expect(
            !FileManager.default.fileExists(
                atPath: f.service.location.gitDirectory.appending(path: "config.worktree").path))
    }

    @Test func worktreeToggleDuringPrivateEditCannotRedirectTheWriteToSharedConfig() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        _ = try await f.engine.run(["config", "--local", "extensions.worktreeConfig", "true"], in: f.root)
        _ = try await f.engine.run(["config", "--local", "commit.gpgsign", "true"], in: f.root)
        let runner = DisableWorktreeConfigDuringEdit(engine: f.engine, root: f.root)
        let settings = GitConfigurationService(
            engine: TestGit.engine(
                runner: runner, environment: f.engine.environment,
                globalConfiguration: try TestGitConfiguration()),
            location: f.service.location)
        let snapshot = try await settings.read(.commitSigning)
        await #expect(throws: ConfigurationWriteOutcomeUnknown.self) {
            _ = try await settings.set("false", scope: .worktree, expected: snapshot)
        }
        #expect(
            try await f.engine.run(["config", "--local", "--get", "commit.gpgsign"], in: f.root).text
                == "true\n")
        let file = f.service.location.gitDirectory.appending(path: "config.worktree")
        #expect(
            try await f.engine.run(["config", "--file", file.path, "--get", "commit.gpgsign"], in: f.root)
                .text == "false\n")
        #expect(try await settings.worktreeConfigurationEnabled() == false)
    }

    private func service(_ fixture: Fixture) throws -> GitConfigurationService {
        return GitConfigurationService(
            engine: TestGit.engine(
                environment: fixture.engine.environment, globalConfiguration: try TestGitConfiguration()),
            location: fixture.service.location,
            queue: fixture.service.queue)
    }

    @Test func configurationEditorDistinguishesScopeInheritanceAndOrigins() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let settings = try service(f)
        var snapshot = try await settings.read(.userName)
        #expect(snapshot.effective?.scope == "local" && snapshot.globalValues.isEmpty)
        snapshot = try await settings.set("Global Fixture", scope: .global, expected: snapshot)
        #expect(snapshot.globalValues == ["Global Fixture"] && snapshot.effective?.value == "WeGit Tests")
        snapshot = try await settings.set(nil, scope: .local, expected: snapshot)
        #expect(snapshot.localValues.isEmpty && snapshot.effective?.value == "Global Fixture")
        #expect(snapshot.effective?.origin.contains("global-fixture-config") == true)
        snapshot = try await settings.set("Local Fixture", scope: .local, expected: snapshot)
        #expect(snapshot.effective?.value == "Local Fixture" && snapshot.globalValues == ["Global Fixture"])
        #expect(try await f.service.configValues("user.name") == ["Local Fixture"])
    }

    @Test func staleConfigurationIsNotOverwritten() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let settings = try service(f)
        let snapshot = try await settings.read(.userName)
        _ = try await f.engine.run(["config", "user.name", "External change"], in: f.root)
        await #expect(throws: ModelFailure.self) {
            _ = try await settings.set("Stale UI", scope: .local, expected: snapshot)
        }
        #expect(try await settings.read(.userName).effective?.value == "External change")
    }

    @Test func strategyAndBranchValidationDoesNotWriteInvalidValues() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let settings = try service(f)
        let strategy = try await settings.read(.pullRebase)
        await #expect(throws: ModelFailure.self) {
            _ = try await settings.set("interactive", scope: .global, expected: strategy)
        }
        let branch = try await settings.read(.defaultBranch)
        await #expect(throws: ModelFailure.self) {
            _ = try await settings.set("--force", scope: .global, expected: branch)
        }
        let valid = try await settings.set("trunk", scope: .global, expected: branch)
        #expect(valid.globalValues == ["trunk"])
        #expect(try await settings.read(.pullRebase).globalValues.isEmpty)
    }
}
