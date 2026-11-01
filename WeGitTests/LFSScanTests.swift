import CryptoKit
import Foundation
import Testing

@testable import WeGitCore

private actor LFSScanCounter: ProcessRunning {
    private(set) var blobProcesses = 0
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("cat-file") { blobProcesses += 1 }
        return try await ProcessRunner().run(request)
    }
}

struct LFSScanTests {
    private func pointer(_ data: Data) -> String {
        let oid = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize \(data.count)\n"
    }

    @Test(.timeLimit(.minutes(1))) func batchedReadPreservesLiteralPathsAndRawIndex() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        for index in 0..<400 { try fixture.write("ordinary-\(index)", "ordinary \(index)\n") }
        let path = "空间,[*]\nfile.bin"
        try fixture.write(path, pointer(Data("payload\n".utf8)))
        _ = try await fixture.commit()
        let before = try Data(contentsOf: fixture.service.location.gitDirectory.appending(path: "index"))
        let head = try await fixture.service.head()
        let counter = LFSScanCounter()
        let engine = GitEngine(
            executable: fixture.engine.executable, runner: counter, environment: fixture.engine.environment)
        let service = RepositoryService(location: fixture.service.location, engine: engine)
        let objects = try await service.lfsObjects()
        #expect(objects.count == 1)
        #expect(objects[0].path == path && objects[0].workingTreeHydrated == false)
        #expect(await counter.blobProcesses == 2)
        #expect(
            try Data(contentsOf: fixture.service.location.gitDirectory.appending(path: "index")) == before)
        #expect(try await service.head() == head)
    }

    @Test(.timeLimit(.minutes(1))) func malformedAndOversizedLookalikesAreNotValidPointers() async throws {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        try fixture.write("valid.bin", pointer(Data("payload\n".utf8)))
        try fixture.write(
            "malformed.bin", "version https://git-lfs.github.com/spec/v1\noid sha256:bad\nsize 1\n")
        try fixture.write("oversized.bin", pointer(Data()) + String(repeating: "x", count: 1024))
        _ = try await fixture.commit()
        let objects = try await fixture.service.lfsObjects()
        #expect(objects.count == 2)
        #expect(objects.first(where: { $0.path == "valid.bin" })?.isPointer == true)
        #expect(objects.first(where: { $0.path == "malformed.bin" })?.isPointer == false)
        #expect(!objects.contains(where: { $0.path == "oversized.bin" }))
    }

    @Test(.timeLimit(.minutes(1))) func workingSymlinkIsNeverFollowedAndUnbornReadCreatesNoIndex()
        async throws
    {
        let fixture = try await Fixture.create()
        defer { fixture.remove() }
        let index = fixture.service.location.gitDirectory.appending(path: "index")
        #expect(try await fixture.service.lfsObjects().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: index.path))
        try fixture.write("pointer.bin", pointer(Data("payload\n".utf8)))
        _ = try await fixture.commit()
        try fixture.write("target.bin", "preserve target\n")
        try FileManager.default.removeItem(at: fixture.root.appending(path: "pointer.bin"))
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appending(path: "pointer.bin"),
            withDestinationURL: fixture.root.appending(path: "target.bin"))
        let objects = try await fixture.service.lfsObjects()
        #expect(objects.count == 1 && objects[0].workingTreeHydrated == nil)
        #expect(objects[0].detail != nil)
        #expect(
            try String(contentsOf: fixture.root.appending(path: "target.bin"), encoding: .utf8)
                == "preserve target\n")
    }
}
