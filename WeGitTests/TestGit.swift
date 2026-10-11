import Darwin
import Foundation
import Testing

@testable import WeGitCore

/// An explicit test-only executable selection; production never reads this variable.
enum TestGit {
    static var executable: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["WEGIT_TEST_GIT"] ?? "/usr/bin/git")
    }

    static func engine(
        runner: any ProcessRunning = ProcessRunner(), activity: ActivityStore = ActivityStore(),
        authentication: AskPassBridge? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        globalConfiguration: TestGitConfiguration? = nil
    ) -> GitEngine {
        var isolated = environment
        isolated["GIT_CONFIG_GLOBAL"] = globalConfiguration?.file.path ?? "/dev/null"
        isolated["GIT_CONFIG_SYSTEM"] = "/dev/null"
        return GitEngine(
            executable: executable,
            runner: IsolatedTestGitRunner(runner: runner, globalConfiguration: globalConfiguration),
            activity: activity, authentication: authentication, environment: isolated)
    }
}

/// Only a freshly created, private file can be passed to a test's global editor.
/// Keeping this object in the runner also keeps the file alive for the whole command.
final class TestGitConfiguration: Sendable {
    private let directory: SnapshotDirectory
    private let identity: RepositoryNodeIdentity
    let file: URL

    init() throws {
        let directory = try SnapshotDirectory()
        self.directory = directory
        identity = try RepositoryNodeIdentity.read(directory.url, directory: true)
        file = directory.url.appending(path: "global-fixture-config")
        guard
            FileManager.default.createFile(
                atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        else { throw ProcessFailure.outputWrite(errno) }
    }

    func validate() throws {
        var info = stat()
        guard try RepositoryNodeIdentity.read(directory.url, directory: true) == identity,
            lstat(file.path, &info) == 0, info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            info.st_uid == getuid(), info.st_nlink == 1
        else { throw ModelFailure.unsupported("测试配置文件已被替换，拒绝执行 Git。") }
    }
}

actor TestGitIsolationGate {
    static let shared = TestGitIsolationGate()
    private let probeRunner: any ProcessRunning
    private var checks: [URL: Task<Void, any Error>] = [:]

    init(probeRunner: any ProcessRunning = ProcessRunner()) { self.probeRunner = probeRunner }

    func verify(_ executable: URL) async throws {
        let check: Task<Void, any Error>
        if let existing = checks[executable] {
            check = existing
        } else {
            let runner = probeRunner
            check = Task {
                try await GitInstallation.verifyConfigurationIsolation(executable: executable, runner: runner)
            }
            checks[executable] = check
        }
        try await check.value
        try Task.checkCancellation()
    }
}

struct IsolatedTestGitRunner: ProcessRunning {
    let runner: any ProcessRunning
    var globalConfiguration: TestGitConfiguration? = nil
    var gate: TestGitIsolationGate = .shared

    func run(_ original: ProcessRequest) async throws -> ProcessResult {
        var request = original
        request.environment["GIT_CONFIG_GLOBAL"] = globalConfiguration?.file.path ?? "/dev/null"
        request.environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        try globalConfiguration?.validate()
        if let command = request.arguments.firstIndex(of: "config"),
            request.arguments[..<command].allSatisfy({
                ["--no-pager", "--literal-pathspecs", "--no-optional-locks"].contains($0)
            })
        {
            let options = request.arguments[(command + 1)...].prefix(while: { $0 != "--" })
            guard !options.contains("--system") else {
                throw ModelFailure.unsupported("测试不允许访问系统配置作用域。")
            }
            if let global = options.firstIndex(of: "--global") {
                guard let globalConfiguration else {
                    throw ModelFailure.unsupported("测试的全局配置操作必须显式提供私有配置文件。")
                }
                // Do not rely on environment support when a test writes global config.
                request.arguments.replaceSubrange(
                    global...global, with: ["--file", globalConfiguration.file.path])
            }
        }
        try await gate.verify(request.executable)
        return try await runner.run(request)
    }
}

struct GitCompatibilityTests {
    @Test func selectedGitPassesTheRequiredRuntimeConfigurationProbe() async throws {
        let installation = try await GitInstallation.detect(preferred: TestGit.executable)
        #expect(installation.executable == TestGit.executable)
        #expect(installation.version.contains("git version"))
    }
}
