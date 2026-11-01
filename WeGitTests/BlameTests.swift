import Foundation
import Testing

@testable import WeGitCore

private struct NormalizingBlameRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let result = try await ProcessRunner().run(request)
        guard request.arguments.contains("blame") else { return result }
        var bytes = result.stdout
        if let range = bytes.range(of: Data([9, 0x65, 0xCC, 0x81, 10])) {
            bytes.replaceSubrange(range, with: Data([9, 0xC3, 0xA9, 10]))
        }
        return ProcessResult(
            stdout: bytes, stderr: result.stderr, exitCode: result.exitCode, duration: result.duration)
    }
}

private actor BlameQueryGate {
    var entered = false
    func enter() { entered = true }
}

private struct WaitingBlameRunner: ProcessRunning {
    let gate: BlameQueryGate
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("blame") {
            await gate.enter()
            try await Task.sleep(for: .seconds(30))
        }
        return try await ProcessRunner().run(request)
    }
}

struct BlameTests {
    @Test func fixedRenamedFileKeepsOriginalAuthorsPathsAndBytes() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let original = "中文\n[quoted]\\\".txt"
        let renamed = "renamed\nfile.txt"
        try f.write(original, "first\r\nsecond\r\nlast")
        let first = try await f.commit("Root")
        _ = try await f.engine.run(["config", "user.name", "Second Author"], in: f.root)
        try f.write(original, "first\r\nchanged\r\nlast")
        let second = try await f.commit("Second line")
        _ = try await f.engine.run(["mv", original, renamed], in: f.root)
        let tip = try await f.service.commit(message: "Rename", amend: false, expectedHead: second)
        try f.write(renamed, "uncommitted bytes\n")
        try f.write(".mailmap", "Mapped <mapped@example.invalid> WeGit Tests <tests@example.invalid>\n")
        try f.write(".git/ignored-revisions", second + "\n")
        _ = try await f.engine.run(
            ["config", "blame.ignoreRevsFile", f.root.appending(path: ".git/ignored-revisions").path],
            in: f.root)
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let document = try await f.service.blameDocument(path: renamed, revision: tip)
        #expect(document.lineCount == 3 && !document.hasFinalNewline)
        let page = try await f.service.blamePage(document, count: 2)
        #expect(page.lines.map(\.number) == [1, 2])
        #expect(page.lines.map { $0.commit.id } == [first, second])
        #expect(page.lines.map { $0.commit.author } == ["WeGit Tests", "Second Author"])
        #expect(page.lines.allSatisfy { $0.originalPath.utf8.elementsEqual(original.utf8) })
        #expect(page.lines.map(\.content) == ["first\r", "changed\r"])
        let last = try await f.service.blamePage(document, firstLine: 3, count: 2)
        #expect(last.lines.map(\.content) == ["last"] && last.lines[0].commit.id == first)
        #expect(last.nextLine == nil && last.previousLine == 1)
        #expect(try await f.service.head() == tip)
        #expect(try Data(contentsOf: f.root.appending(path: ".git/index")) == index)
        #expect(try Data(contentsOf: f.root.appending(path: renamed)) == Data("uncommitted bytes\n".utf8))
    }

    @Test func canonicallyEquivalentTransportChangesCannotMatchRawBlobBytes() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try Data([0x65, 0xCC, 0x81, 10]).write(to: f.root.appending(path: "file"))
        let tip = try await f.commit("Decomposed UTF-8")
        let document = try await f.service.blameDocument(path: "file", revision: tip)
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: NormalizingBlameRunner(), environment: f.engine.environment))
        await #expect(throws: ModelFailure.self) { _ = try await service.blamePage(document) }
    }

    @Test func deletionAndWorkingEditsCannotChangeAnExistingDocument() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "original\n")
        let tip = try await f.commit("Original")
        let document = try await f.service.blameDocument(path: "file", revision: tip)
        _ = try await f.engine.run(["rm", "file"], in: f.root)
        let deleted = try await f.service.commit(message: "Delete", amend: false, expectedHead: tip)
        #expect(try await f.service.blamePage(document).lines.map(\.content) == ["original"])
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.blameDocument(path: "file", revision: deleted)
        }
        #expect(try await f.service.head() == deleted)
    }

    @Test func contentAndPageBoundsAreCheckedBeforeDisplayingAttribution() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        for (name, data) in [
            ("empty", Data()), ("binary", Data([0, 1])), ("invalid", Data([255])),
            ("long", Data(repeating: 97, count: BlameReadBudget.lineBytes + 1)),
        ] {
            try data.write(to: f.root.appending(path: name))
        }
        let tip = try await f.commit("Read limits")
        let empty = try await f.service.blameDocument(path: "empty", revision: tip)
        #expect(try await f.service.blamePage(empty).lines.isEmpty)
        for name in ["binary", "invalid", "long"] {
            await #expect(throws: ModelFailure.self) {
                _ = try await f.service.blameDocument(path: name, revision: tip)
            }
        }
        await #expect(throws: ModelFailure.self) { _ = try await f.service.blamePage(empty, firstLine: 2) }
        await #expect(throws: ModelFailure.self) { _ = try await f.service.blamePage(empty, count: 201) }
        await #expect(throws: ModelFailure.self) {
            _ = try await f.service.blameDocument(path: "../file", revision: tip)
        }
    }

    @Test func aPartialCloneCannotLazilyFetchTheFile() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "committed content\n")
        let tip = try await f.commit("Source")
        let full = try await f.service.blameDocument(path: "file", revision: tip)
        let folder = f.root.appending(path: ".git/read-boundaries")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bare = folder.appending(path: "origin.git")
        let partial = folder.appending(path: "partial")
        _ = try await f.engine.run(["clone", "--bare", "--no-local", f.root.path, bare.path], in: f.root)
        _ = try await f.engine.run(["config", "uploadpack.allowFilter", "true"], in: bare)
        _ = try await f.engine.run(
            ["clone", "--filter=blob:none", "--no-checkout", bare.absoluteString, partial.path], in: f.root)
        var offline = f.engine
        offline.environment["GIT_NO_LAZY_FETCH"] = "1"
        #expect(
            try await offline.run(["cat-file", "-e", full.blob], in: partial, accepted: [0, 1, 128]).exitCode
                != 0)
        let service = try await RepositoryService(
            location: RepositoryService.discover(partial, engine: f.engine), engine: f.engine)
        await #expect(throws: ModelFailure.self) {
            _ = try await service.blameDocument(path: "file", revision: tip)
        }
        #expect(
            try await offline.run(["cat-file", "-e", full.blob], in: partial, accepted: [0, 1, 128]).exitCode
                != 0)
    }

    @Test func cancellingAReadDoesNotReturnAPageOrChangeTheRepository() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "original\n")
        let tip = try await f.commit("Original")
        let document = try await f.service.blameDocument(path: "file", revision: tip)
        let gate = BlameQueryGate()
        let service = RepositoryService(
            location: f.service.location,
            engine: TestGit.engine(runner: WaitingBlameRunner(gate: gate), environment: f.engine.environment))
        let task = Task { try await service.blamePage(document) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.entered), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.entered)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await f.service.head() == tip)
        #expect(try await f.service.status().files.isEmpty)
    }
}
