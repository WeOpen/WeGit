import Foundation
import Testing

@testable import WeGitCore

private actor IsolationProbeRunner: ProcessRunning {
    let ignoresIsolation: Bool
    private(set) var calls = 0
    init(ignoresIsolation: Bool = false) { self.ignoresIsolation = ignoresIsolation }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        calls += 1
        if ignoresIsolation {
            return ProcessResult(stdout: Data("runtime\n".utf8), stderr: Data(), exitCode: 0, duration: 0)
        }
        return try await ProcessRunner().run(request)
    }
}

private actor IsolationRequestRecorder: ProcessRunning {
    private(set) var requests: [ProcessRequest] = []
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        requests.append(request)
        return ProcessResult(stdout: Data(), stderr: Data(), exitCode: 0, duration: 0)
    }
}

struct TestGitIsolationTests {
    @Test func unsupportedGitIsRejectedBeforeAnyFixtureCommand() async throws {
        let probe = IsolationProbeRunner(ignoresIsolation: true)
        let destination = IsolationRequestRecorder()
        let runner = IsolatedTestGitRunner(
            runner: destination, gate: TestGitIsolationGate(probeRunner: probe))
        for _ in 0..<2 {
            await #expect(throws: ModelFailure.self) {
                _ = try await runner.run(ProcessRequest(executable: TestGit.executable, arguments: ["init"]))
            }
        }
        #expect(await probe.calls == 1)
        #expect(await destination.requests.isEmpty)
    }

    @Test func concurrentFixtureCommandsShareTheReadOnlyIsolationProbe() async throws {
        let probe = IsolationProbeRunner()
        let gate = TestGitIsolationGate(probeRunner: probe)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 { group.addTask { try await gate.verify(TestGit.executable) } }
            try await group.waitForAll()
        }
        #expect(await probe.calls == 1)
    }

    @Test func globalWritesRequireAnExplicitPrivateFileAndCannotUseInheritedPaths() async throws {
        let recorder = IsolationRequestRecorder()
        let engine = TestGit.engine(
            runner: recorder,
            environment: ["GIT_CONFIG_GLOBAL": "/untrusted/config", "GIT_CONFIG_SYSTEM": "/untrusted/system"])
        #expect(engine.environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #expect(engine.environment["GIT_CONFIG_SYSTEM"] == "/dev/null")
        await #expect(throws: ModelFailure.self) {
            _ = try await engine.run(["config", "--global", "user.name", "Must not write"])
        }
        await #expect(throws: ModelFailure.self) {
            _ = try await engine.run(["config", "--system", "user.name", "Must not write"])
        }
        #expect(await recorder.requests.isEmpty)
    }

    @Test func globalScopeIsRewrittenToThePrivateFileBeforeTheProcessRuns() async throws {
        let file = try TestGitConfiguration()
        let recorder = IsolationRequestRecorder()
        var engine = TestGit.engine(runner: recorder, globalConfiguration: file)
        engine.environment["GIT_CONFIG_GLOBAL"] = "/untrusted/config"
        _ = try await engine.run(["config", "--global", "--replace-all", "--", "user.name", "Fixture"])
        let request = try #require(await recorder.requests.first)
        #expect(!request.arguments.contains("--global"))
        #expect(
            Array(request.arguments.suffix(6)) == [
                "--file", file.file.path, "--replace-all", "--", "user.name", "Fixture",
            ])
        #expect(request.environment["GIT_CONFIG_GLOBAL"] == file.file.path)
        #expect(request.environment["GIT_CONFIG_SYSTEM"] == "/dev/null")
    }

    @Test func replacedPrivateConfigurationNeverReachesGit() async throws {
        let file = try TestGitConfiguration()
        let recorder = IsolationRequestRecorder()
        let engine = TestGit.engine(runner: recorder, globalConfiguration: file)
        try FileManager.default.removeItem(at: file.file)
        try FileManager.default.createSymbolicLink(atPath: file.file.path, withDestinationPath: "/dev/null")
        await #expect(throws: ModelFailure.self) {
            _ = try await engine.run(["config", "--global", "user.name", "Must not write"])
        }
        #expect(await recorder.requests.isEmpty)
    }
}
