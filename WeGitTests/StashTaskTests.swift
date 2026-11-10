import Foundation
import Testing

@testable import WeGitCore

private actor FailSavedTaskSwitch: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("switch") {
            return ProcessResult(
                stdout: Data(), stderr: Data("fixture switch failed\n".utf8), exitCode: 1, duration: 0.01)
        }
        return try await ProcessRunner().run(request)
    }
}

struct StashTaskTests {
    @Test func saveSwitchAndStashBranchRestoreWorkIndexAndUntrackedLayers() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\r\nlast")
        let base = try await f.commit("Base")
        _ = try await f.engine.run(["branch", "target", base], in: f.root)
        try f.write("file", "staged\r\nlast")
        _ = try await f.engine.run(["add", "--", "file"], in: f.root)
        try f.write("file", "working\r\nlast")
        try f.write("untracked", "private\r\nlast")
        let target = try #require(await f.service.branches().first { $0.name == "target" })
        let plan = try await f.service.prepareTaskSwitch(
            to: target, message: "Current task", includeUntracked: true)
        #expect(try await f.service.head() == base)
        let outcome = try await f.service.executeTaskSwitch(plan)
        guard case .switched(let stash) = outcome else {
            Issue.record("Task switch did not finish")
            return
        }
        #expect(try await f.service.status().branch == "target")
        #expect(try await f.service.status().files.isEmpty)
        let list = try await f.service.stashes()
        let restore = try await f.service.prepareStashBranch(
            stash, in: list, name: "restored-task", dropAfterApply: false)
        let restored = try await f.service.executeStashBranch(restore)
        guard case .restored(let name, .applied) = restored else {
            Issue.record("Stash branch restore failed")
            return
        }
        let branch = try await f.service.status().branch
        #expect(name == "restored-task" && branch == name)
        #expect(try await f.service.head() == base)
        #expect(try await f.engine.run(["show", ":file"], in: f.root).stdout == Data("staged\r\nlast".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("working\r\nlast".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: "untracked")) == Data("private\r\nlast".utf8))
        #expect(try await f.service.stashes().entries.contains { $0.objectID == stash.objectID })
    }

    @Test func aSwitchFailureAfterSavingRetainsOneStashAndDoesNotRepeatTheSave() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let head = try await f.commit("Base")
        _ = try await f.engine.run(["branch", "target", head], in: f.root)
        try f.write("file", "private task\n")
        let target = try #require(await f.service.branches().first { $0.name == "target" })
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: FailSavedTaskSwitch(), environment: f.engine.environment))
        let plan = try await service.prepareTaskSwitch(to: target, message: "Saved once")
        let result = try await service.executeTaskSwitch(plan)
        guard case .savedNeedsReview(let entry, _) = result else {
            Issue.record("Partial success was not retained")
            return
        }
        #expect(try await service.status().branch == "main")
        let saved = try await service.stashes()
        #expect(saved.entries.count == 1 && saved.entries[0].objectID == entry.objectID)
        #expect(try await service.recoveryRecords().contains { $0.state == .needsVerification })
        await #expect(throws: ModelFailure.self) { _ = try await service.executeTaskSwitch(plan) }
        #expect(try await service.stashes().entries.count == 1)
    }
}
