import Foundation
import Testing

@testable import WeGitCore

struct RepositoryInitializationTests {
    @Test func initializationPreservesExistingBytesAndUsesTheExplicitInitialBranch() async throws {
        try await TestGitIsolationGate.shared.verify(TestGit.executable)
        let root = FileManager.default.temporaryDirectory.appending(path: "WeGitInit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0, 13, 10, 255, 7])
        try bytes.write(to: root.appending(path: "中文\nfile"))
        let engine = TestGit.engine()
        let coordinator = RepositoryInitializationCoordinator(engine: engine)
        let plan = try await coordinator.prepare(
            RepositoryInitializationRequest(directory: root, branch: "first/branch"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".git").path))
        let location = try await coordinator.initialize(plan)
        let state = try await RepositoryService(location: location, engine: engine).status()
        #expect(state.head == nil && state.branch == "first/branch")
        #expect(state.files.contains { $0.path == "中文\nfile" && $0.untracked })
        #expect(try Data(contentsOf: root.appending(path: "中文\nfile")) == bytes)
    }

    @Test func initializationNeverTakesOverAnExistingOrParentRepository() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let coordinator = RepositoryInitializationCoordinator(engine: f.engine)
        let child = f.root.appending(path: "ordinary-child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        await #expect(throws: ModelFailure.self) {
            _ = try await coordinator.prepare(RepositoryInitializationRequest(directory: f.root))
        }
        await #expect(throws: ModelFailure.self) {
            _ = try await coordinator.prepare(RepositoryInitializationRequest(directory: child))
        }
        #expect(!FileManager.default.fileExists(atPath: child.appending(path: ".git").path))
    }

    @Test func movedDirectoryAndLateGitMetadataInvalidateTheOriginalPlan() async throws {
        try await TestGitIsolationGate.shared.verify(TestGit.executable)
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "WeGitInitFence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appending(path: "selected")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let engine = TestGit.engine()
        let coordinator = RepositoryInitializationCoordinator(engine: engine)
        let original = try await coordinator.prepare(RepositoryInitializationRequest(directory: root))
        try FileManager.default.moveItem(at: root, to: parent.appending(path: "moved"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("foreign bytes".utf8).write(to: root.appending(path: "file"))
        await #expect(throws: ModelFailure.self) { _ = try await coordinator.initialize(original) }
        #expect(try Data(contentsOf: root.appending(path: "file")) == Data("foreign bytes".utf8))
        let fresh = try await coordinator.prepare(RepositoryInitializationRequest(directory: root))
        _ = try await engine.run(["init", "-b", "external"], in: root)
        await #expect(throws: ModelFailure.self) { _ = try await coordinator.initialize(fresh) }
        #expect(
            try await RepositoryService(
                location: RepositoryService.discover(root, engine: engine), engine: engine
            ).status().branch == "external")
    }
}
