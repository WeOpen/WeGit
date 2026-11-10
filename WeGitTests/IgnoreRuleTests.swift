import Darwin
import Foundation
import Testing

@testable import WeGitCore

struct IgnoreRuleTests {
    @Test func pathspecMagicInAFileNameIsKeptLiteralInTheIgnorePreview() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let path = ":(glob)*.txt"
        try f.write(path, "literal file\n")
        try f.write("other.txt", "keep\n")
        let plan = try await f.service.prepareIgnoreRule(path: path)
        #expect(plan.pattern == "/:(glob)\\*.txt")
        #expect(plan.matchedPaths == [path])
        let outcome = try await f.service.executeIgnoreRule(plan)
        #expect(try Data(contentsOf: f.root.appending(path: path)) == Data("literal file\n".utf8))
        #expect(try await f.service.status().files.contains { $0.path == "other.txt" })
        #expect(try await !f.service.status().files.contains { $0.path == path })
        try await f.service.undoIgnoreRule(outcome)
        #expect(try await f.service.status().files.contains { $0.path == path })
    }

    @Test(arguments: IgnoreRuleScope.allCases)
    func unbornRepositoryWithoutInfoCanPreviewSaveAndUndoAnIgnoreRule(scope: IgnoreRuleScope) async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let info = f.root.appending(path: ".git/info")
        try FileManager.default.removeItem(at: info)
        let original = Data("保留内容\r\n末行".utf8)
        try original.write(to: f.root.appending(path: "保留.txt"))
        let index = try SelectedIndexSnapshot.read(location: f.service.location)
        #expect(try await f.service.head() == nil)
        let plan = try await f.service.prepareIgnoreRule(path: "保留.txt", scope: scope)
        #expect(plan.matchedPaths == ["保留.txt"])
        #expect(!FileManager.default.fileExists(atPath: info.path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: ".gitignore").path))
        let outcome = try await f.service.executeIgnoreRule(plan)
        #expect(try await !f.service.status().files.contains { $0.path == "保留.txt" })
        #expect(try Data(contentsOf: f.root.appending(path: "保留.txt")) == original)
        #expect(try SelectedIndexSnapshot.read(location: f.service.location) == index)
        #expect(try await f.service.head() == nil)
        try await f.service.undoIgnoreRule(outcome)
        #expect(try await f.service.status().files.contains { $0.path == "保留.txt" })
        #expect(try Data(contentsOf: f.root.appending(path: "保留.txt")) == original)
        #expect(try SelectedIndexSnapshot.read(location: f.service.location) == index)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: ".gitignore").path))
        #expect(!FileManager.default.fileExists(atPath: info.appending(path: "exclude").path))
    }

    @Test func exactRuleEscapesGlobCharactersPreservesCommentsAndCRLFAndUndoRestoresRawBytes() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let original = Data("# 原注释\r\nexisting-rule".utf8)
        try original.write(to: f.root.appending(path: ".gitignore"))
        let head = try await f.commit()
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let path = "a [x]!.txt"
        try f.write(path, "selected\n")
        try f.write("a x!.txt", "keep\n")
        let plan = try await f.service.prepareIgnoreRule(path: path)
        #expect(plan.pattern == "/a\\ \\[x\\]\\!.txt")
        #expect(plan.matchedPaths == [path])
        let outcome = try await f.service.executeIgnoreRule(plan)
        #expect(
            try Data(contentsOf: f.root.appending(path: ".gitignore")) == original
                + Data("\r\n/a\\ \\[x\\]\\!.txt\r\n".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(try await f.service.head() == head)
        #expect(try await f.service.status().files.contains { $0.path == "a x!.txt" })
        #expect(try await !f.service.status().files.contains { $0.path == path })
        try await f.service.undoIgnoreRule(outcome)
        #expect(try Data(contentsOf: f.root.appending(path: ".gitignore")) == original)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
    }

    @Test func nestedNegationIsHonoredByTheCandidateRulePreview() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try FileManager.default.createDirectory(
            at: f.root.appending(path: "nested"), withIntermediateDirectories: false)
        try f.write(".gitignore", "# root\n")
        try f.write("nested/.gitignore", "!keep.tmp\n")
        _ = try await f.commit()
        try f.write("nested/keep.tmp", "keep\n")
        try f.write("nested/drop.tmp", "drop\n")
        let plan = try await f.service.prepareIgnoreRule(path: "nested/drop.tmp", kind: .fileExtension)
        #expect(plan.pattern == "*.tmp")
        #expect(plan.matchedPaths == ["nested/drop.tmp"])
        _ = try await f.service.executeIgnoreRule(plan)
        #expect(try await f.service.status().files.contains { $0.path == "nested/keep.tmp" })
        #expect(try await !f.service.status().files.contains { $0.path == "nested/drop.tmp" })
    }

    @Test func localRulePreservesOriginalPermissionsAndNewFileUndoRemovesOnlyTheCreatedExclude() async throws
    {
        let f = try await Fixture.create()
        defer { f.remove() }
        let exclude = f.root.appending(path: ".git/info/exclude")
        let original = Data("# local\nold-rule".utf8)
        try original.write(to: exclude)
        #expect(chmod(exclude.path, 0o600) == 0)
        try f.write("first.log", "one\n")
        try f.write("second.log", "two\n")
        let plan = try await f.service.prepareIgnoreRule(
            path: "first.log", kind: .fileExtension, scope: .local)
        #expect(Set(plan.matchedPaths) == ["first.log", "second.log"])
        let outcome = try await f.service.executeIgnoreRule(plan)
        var mode = stat()
        #expect(lstat(exclude.path, &mode) == 0 && mode.st_mode & 0o777 == 0o600)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: ".gitignore").path))
        try await f.service.undoIgnoreRule(outcome)
        #expect(try Data(contentsOf: exclude) == original)
        try FileManager.default.removeItem(at: exclude)
        let fresh = try await f.service.executeIgnoreRule(
            f.service.prepareIgnoreRule(path: "first.log", scope: .local))
        try await f.service.undoIgnoreRule(fresh)
        #expect(!FileManager.default.fileExists(atPath: exclude.path))
        #expect(try Data(contentsOf: f.root.appending(path: "first.log")) == Data("one\n".utf8))
    }

    @Test func externalIgnoreEditRejectsTheSavedPreviewWithoutOverwritingIt() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write(".gitignore", "# before\n")
        try f.write("file.tmp", "keep bytes\n")
        let plan = try await f.service.prepareIgnoreRule(path: "file.tmp")
        try f.write(".gitignore", "# external update\n")
        await #expect(throws: ModelFailure.self) { try await f.service.executeIgnoreRule(plan) }
        #expect(
            try Data(contentsOf: f.root.appending(path: ".gitignore")) == Data("# external update\n".utf8))
        #expect(try Data(contentsOf: f.root.appending(path: "file.tmp")) == Data("keep bytes\n".utf8))
    }

    @Test func redirectedInfoDirectoryAndMultilinePathsNeverEnterTheMetadataWriter() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file.tmp", "keep\n")
        let outside = f.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("outside sentinel\n".utf8).write(to: outside.appending(path: "exclude"))
        try FileManager.default.moveItem(
            at: f.root.appending(path: ".git/info"), to: f.root.appending(path: ".git/old-info"))
        try FileManager.default.createSymbolicLink(
            atPath: f.root.appending(path: ".git/info").path, withDestinationPath: outside.path)
        await #expect(throws: ModelFailure.self) {
            try await f.service.prepareIgnoreRule(path: "file.tmp", scope: .local)
        }
        #expect(try Data(contentsOf: outside.appending(path: "exclude")) == Data("outside sentinel\n".utf8))
        try f.write("line\nname", "keep\n")
        await #expect(throws: ModelFailure.self) { try await f.service.prepareIgnoreRule(path: "line\nname") }
    }
}
