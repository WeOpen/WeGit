import Foundation
import Testing

@testable import WeGitCore

struct SelectionScopeTests {
    @Test func directoryReplacementCannotExpandASelectedFileOperation() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("replaced", "tracked\n")
        try fixture.write("other", "tracked\n")
        let head = try await fixture.commit()
        try FileManager.default.removeItem(at: fixture.root.appending(path: "replaced"))
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "replaced"), withIntermediateDirectories: true)
        try fixture.write("replaced/hidden", "untracked\n")
        try fixture.write("other", "modified\n")
        let before = try await fixture.engine.run(["diff", "--cached", "--raw", "-z"], in: fixture.root)
            .stdout
        do {
            try await fixture.service.stage(paths: ["replaced", "other"], expectedHead: head)
            Issue.record("A file path must not recursively stage an unselected child")
        } catch ModelFailure.unsupported {}
        #expect(
            try await fixture.engine.run(["diff", "--cached", "--raw", "-z"], in: fixture.root).stdout
                == before)
        try await fixture.service.stage(paths: ["replaced", "replaced/hidden", "other"], expectedHead: head)
        let staged = try await fixture.engine.run(["diff", "--cached", "--raw", "-z"], in: fixture.root)
            .stdout
        do {
            try await fixture.service.unstage(paths: ["replaced", "other"], expectedHead: head)
            Issue.record("A filtered file path must not recursively unstage an unselected child")
        } catch ModelFailure.unsupported {}
        #expect(
            try await fixture.engine.run(["diff", "--cached", "--raw", "-z"], in: fixture.root).stdout
                == staged)
        try await fixture.service.unstage(
            paths: ["replaced", "replaced/hidden", "other"], expectedHead: head)
        #expect(
            try await fixture.engine.run(["diff", "--cached", "--raw", "-z"], in: fixture.root).stdout.isEmpty
        )
        _ = try await fixture.engine.run(["add", "-u", "--", "replaced"], in: fixture.root)
        try await fixture.service.unstage(paths: ["replaced"], expectedHead: head)
        #expect(
            try await fixture.engine.run(["diff", "--cached", "--raw", "-z"], in: fixture.root).stdout.isEmpty
        )
        #expect(
            try Data(contentsOf: fixture.root.appending(path: "replaced/hidden")) == Data("untracked\n".utf8))
        #expect(try await fixture.service.head() == head)
    }
}
