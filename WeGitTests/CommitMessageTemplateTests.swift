import Foundation
import Testing

@testable import WeGitCore

struct CommitMessageTemplateTests {
    @Test func templateReadsOriginsAndExactCRLFBytesWithoutChangingRepositoryLayers() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "original\n")
        let head = try await f.commit("Base")
        let index = try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index"))
        let path = f.service.location.gitDirectory.appending(path: "message-template")
        let bytes = Data("主题 🧭\r\n\r\n原始末行".utf8)
        try bytes.write(to: path)
        _ = try await f.engine.run(["config", "--local", "commit.template", path.path], in: f.root)
        let value = try #require(
            await GitConfigurationService(
                engine: TestGit.engine(
                    environment: f.engine.environment, globalConfiguration: try TestGitConfiguration()),
                location: f.service.location
            )
            .readCommitMessageTemplate())
        #expect(value.bytes == bytes && value.text == String(data: bytes, encoding: .utf8))
        #expect(value.source.scope == "local" && value.sha256 == RecoveryFileIO.hash(bytes))
        #expect(try await f.service.head() == head)
        #expect(try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index")) == index)
        #expect(try Data(contentsOf: path) == bytes)
    }

    @Test func undecodableAndOversizedTemplatesNeverBecomeReplacementMessages() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let path = f.service.location.gitDirectory.appending(path: "message-template")
        let bytes = Data([0xff, 0xfe, 0x00, 0x61])
        try bytes.write(to: path)
        _ = try await f.engine.run(["config", "--local", "commit.template", path.path], in: f.root)
        let service = GitConfigurationService(
            engine: TestGit.engine(
                environment: f.engine.environment, globalConfiguration: try TestGitConfiguration()),
            location: f.service.location)
        let value = try #require(await service.readCommitMessageTemplate())
        #expect(value.bytes == bytes && value.text == nil)
        let oversized = Data(repeating: 65, count: 64 * 1024 + 1)
        try oversized.write(to: path)
        await #expect(throws: ModelFailure.self) { _ = try await service.readCommitMessageTemplate() }
        #expect(try Data(contentsOf: path) == oversized)
        #expect(
            !FileManager.default.fileExists(
                atPath: f.service.location.gitDirectory.appending(path: "index").path))
    }
}
