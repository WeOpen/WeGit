import Foundation
import Testing

@testable import WeGitCore

private struct RefuseAbortRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("merge") && request.arguments.contains("--abort") {
            return ProcessResult(
                stdout: Data(), stderr: Data("fixture abort failed\n".utf8), exitCode: 1, duration: 0)
        }
        return try await ProcessRunner().run(request)
    }
}

struct SequencerAndGraphTests {
    @Test func realOctopusMergePreservesEveryParentAcrossPages() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("base", "base\n")
        let base = try await f.commit()
        for name in ["left", "middle", "right"] {
            _ = try await f.engine.run(["switch", "-c", name, base], in: f.root)
            try f.write(name, name + "\n")
            _ = try await f.commit(name)
        }
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        _ = try await f.engine.run(["merge", "--no-ff", "--no-edit", "left", "middle", "right"], in: f.root)
        let head = try #require(try await f.service.head())
        let merge = try await f.service.readCommit(head)
        #expect(merge.parents.count >= 3)
        let anchor = try await f.service.historyAnchor()
        let first = try await f.service.historyPage(anchor, count: 2)
        var graph = CommitGraphLayoutEngine()
        let firstRows = graph.append(first.commits)
        #expect(firstRows[0].connections.count == merge.parents.count)
        var all = first.commits
        var cursor = first.next
        while let next = cursor {
            let page = try await f.service.historyPage(anchor, after: next, count: 2)
            _ = graph.append(page.commits)
            all += page.commits
            cursor = page.next
        }
        #expect(graph.lanes.isEmpty)
        for commit in all {
            for parent in commit.parents {
                #expect(
                    try #require(all.firstIndex { $0.id == commit.id }) < #require(
                        all.firstIndex { $0.id == parent }))
            }
        }
        for parent in merge.parents {
            let comparison = try await f.service.commitComparison(id: head, parent: parent)
            #expect(comparison.parent == parent)
        }
    }

    @Test(arguments: [false, true]) func binaryAndModifyDeleteConflictsCanContinueOrAbort(abort: Bool)
        async throws
    {
        let f = try await Fixture.create()
        defer { f.remove() }
        try Data([0, 1, 2]).write(to: f.root.appending(path: "binary"))
        try f.write("deleted", "base\n")
        let base = try await f.commit()
        try await f.service.createBranch("feature", expectedHead: base)
        try Data([0, 3, 4]).write(to: f.root.appending(path: "binary"))
        try FileManager.default.removeItem(at: f.root.appending(path: "deleted"))
        _ = try await f.commit("Feature")
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        try Data([0, 5, 6]).write(to: f.root.appending(path: "binary"))
        try f.write("deleted", "local change\n")
        let local = try await f.commit("Local")
        let feature = try #require(try await f.service.branches().first { $0.name == "feature" })
        await #expect(throws: GitFailure.self) { try await f.service.merge(feature, expectedHead: local) }
        let state = try await f.service.status()
        #expect(state.sequencer == .merge && Set(state.conflicts.map(\.path)) == ["binary", "deleted"])
        if abort {
            try await f.service.sequencer(continueOperation: false, expected: .merge)
            #expect(try await f.service.head() == local)
            #expect(
                try String(contentsOf: f.root.appending(path: "deleted"), encoding: .utf8) == "local change\n"
            )
        } else {
            try Data([0, 5, 6]).write(to: f.root.appending(path: "binary"))
            try FileManager.default.removeItem(at: f.root.appending(path: "deleted"))
            try await f.service.markResolved(path: "binary", expectedHead: local)
            try await f.service.markResolved(path: "deleted", expectedHead: local)
            try await f.service.sequencer(continueOperation: true, expected: .merge)
            #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "deleted").path))
        }
        #expect(try Data(contentsOf: f.root.appending(path: "binary")) == Data([0, 5, 6]))
        #expect(try await f.service.status().sequencer == .none)
    }

    @Test func failedAbortKeepsTheUsersResolutionAndSequencerState() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let base = try await f.commit()
        try await f.service.createBranch("feature", expectedHead: base)
        try f.write("file", "feature\n")
        _ = try await f.commit()
        _ = try await f.engine.run(["switch", "main"], in: f.root)
        try f.write("file", "main\n")
        let local = try await f.commit()
        _ = try await f.engine.run(["merge", "--no-edit", "feature"], in: f.root, accepted: [1])
        try f.write("file", "user resolution in progress\n")
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: RefuseAbortRunner(), environment: f.engine.environment))
        await #expect(throws: GitFailure.self) {
            try await service.sequencer(continueOperation: false, expected: .merge)
        }
        #expect(try await f.service.status().sequencer == .merge)
        #expect(try await f.service.head() == local)
        #expect(
            try String(contentsOf: f.root.appending(path: "file"), encoding: .utf8)
                == "user resolution in progress\n")
    }

    @Test func failedGitAmIsNotMisidentifiedAsAnAppSupportedRebase() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "base\n")
        let base = try await f.commit()
        try f.write("file", "patch change\n")
        _ = try await f.commit("Patch")
        let patch = try await f.engine.run(["format-patch", "-1", "--stdout"], in: f.root).stdout
        _ = try await f.engine.run(["reset", "--hard", base], in: f.root)
        try f.write("file", "conflicting local\n")
        _ = try await f.commit("Local")
        _ = try await f.engine.run(["am"], in: f.root, input: patch, accepted: [128])
        #expect(try await f.service.status().sequencer == .unknown)
        await #expect(throws: ModelFailure.self) {
            try await f.service.sequencer(continueOperation: true, expected: .rebase)
        }
        _ = try await f.engine.run(["am", "--abort"], in: f.root)
        #expect(try await f.service.status().sequencer == .none)
    }
}
