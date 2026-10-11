import Foundation
import Testing

@testable import WeGitCore

struct GitConfigurationTests {
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
