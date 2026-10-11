import Foundation
import Testing

@testable import WeGitCore

struct BranchManagementTests {
    @Test func trackingBranchReportsDivergenceAndMissingUpstream() async throws {
        let remote = try await Fixture.create()
        let local = try await Fixture.create()
        defer {
            remote.remove()
            local.remove()
        }
        try remote.write("base", "base\n")
        _ = try await remote.commit()
        _ = try await local.engine.run(["remote", "add", "origin", remote.root.path], in: local.root)
        try await local.service.fetch(remote: "origin")
        let source = try #require(
            try await local.service.branches().first { $0.id == "refs/remotes/origin/main" })
        try await local.service.createTrackingBranch(from: source, name: "local", expectedHead: nil)
        var branch = try #require(try await local.service.branches().first { $0.current })
        #expect(branch.upstreamRef == "refs/remotes/origin/main" && branch.ahead == 0 && branch.behind == 0)
        try local.write("local", "local\n")
        _ = try await local.commit()
        try remote.write("remote", "remote\n")
        _ = try await remote.commit()
        try await local.service.fetch(remote: "origin")
        branch = try #require(try await local.service.branches().first { $0.current })
        #expect(branch.ahead == 1 && branch.behind == 1)
        _ = try await local.engine.run(["update-ref", "-d", "refs/remotes/origin/main"], in: local.root)
        branch = try #require(try await local.service.branches().first { $0.current })
        #expect(branch.upstreamRef != nil && branch.ahead == nil && branch.behind == nil)
        try await local.service.setUpstream(of: branch, to: nil, expectedHead: try await local.service.head())
        #expect(try await local.service.branches().first { $0.current }?.upstreamRef == nil)
    }

    @Test func renameAndSafeDeleteKeepTheCurrentBranchAndWorktree() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let head = try await f.commit()
        try await f.service.createBranch("old-name", switchTo: false, expectedHead: head)
        let old = try #require(try await f.service.branches().first { $0.name == "old-name" })
        try await f.service.renameBranch(old, to: "new-name", expectedHead: head)
        let renamed = try #require(try await f.service.branches().first { $0.name == "new-name" })
        let plan = try await f.service.prepareBranchDeletion(renamed, expectedHead: head)
        #expect(plan.merged)
        try await f.service.deleteBranch(plan)
        #expect(try await f.service.branches().map(\.name) == ["main"])
        #expect(try await f.service.head() == head)
        #expect(try String(contentsOf: f.root.appending(path: "file"), encoding: .utf8) == "base\n")
        let current = try #require(try await f.service.branches().first)
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.prepareBranchDeletion(current, expectedHead: head)
        }
    }

    @Test func unmergedDeletionRequiresConfirmationAndRejectsMovedTips() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let base = try await f.commit()
        try await f.service.createBranch("feature", expectedHead: base)
        try f.write("file", "feature\n")
        let tip = try await f.commit()
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        let branch = try #require(try await f.service.branches().first { $0.name == "feature" })
        let plan = try await f.service.prepareBranchDeletion(branch, expectedHead: base)
        #expect(!plan.merged)
        await #expect(throws: ModelFailure.self) { try await f.service.deleteBranch(plan) }
        _ = try await f.engine.run(["update-ref", "refs/heads/feature", base, tip], in: f.root)
        await #expect(throws: ModelFailure.self) {
            try await f.service.deleteBranch(plan, allowUnmerged: true)
        }
        _ = try await f.engine.run(["update-ref", "refs/heads/feature", tip, base], in: f.root)
        let fresh = try await f.service.prepareBranchDeletion(branch, expectedHead: base)
        try await f.service.deleteBranch(fresh, allowUnmerged: true)
        #expect(try await f.service.branches().allSatisfy { $0.name != "feature" })
        #expect(try await f.service.head() == base)
    }

    @Test func worktreePathsWithNewlinesArePreservedAndProtected() async throws {
        let f = try await Fixture.create()
        let worktree = f.root.appendingPathExtension("linked\nworktree")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: worktree)
        }
        try f.write("file", "base\n")
        let head = try await f.commit()
        _ = try await f.engine.run(["worktree", "add", "-b", "occupied", worktree.path], in: f.root)
        let occupied = try #require(try await f.service.branches().first { $0.name == "occupied" })
        #expect(occupied.worktreePath?.contains("\n") == true)
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.prepareBranchDeletion(occupied, expectedHead: head)
        }
        await #expect(throws: ModelFailure.self) {
            try await f.service.renameBranch(occupied, to: "renamed", expectedHead: head)
        }
        await #expect(throws: ModelFailure.self) {
            try await f.service.switchBranch(occupied, expectedHead: head)
        }
    }

    @Test func aTagWithTheSameNameDoesNotChangeTheBranchCommandName() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let head = try await f.commit()
        _ = try await f.engine.run(["tag", "main"], in: f.root)
        let main = try #require(try await f.service.branches().first { $0.id == "refs/heads/main" })
        #expect(main.name == "main")
        try await f.service.createBranch("other", expectedHead: head)
        try await f.service.switchBranch(main, expectedHead: head)
        #expect(try await f.service.status().branch == "main")
    }

    @Test func truncatedBranchOutputIsRejected() {
        #expect(throws: ModelFailure.self) { _ = try BranchParser.parse(Data("refs/heads/main\0abc\0".utf8)) }
    }
}
