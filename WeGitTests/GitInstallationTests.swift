import Foundation
import Testing

@testable import WeGitCore

private struct IncompatibleGitRunner: ProcessRunning {
    enum Failure: CaseIterable, Sendable { case oldVersion, ignoredIsolation, ignoredURLReset }
    let failure: Failure

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let text: String?
        if request.arguments == ["--version"] {
            text = failure == .oldVersion ? "git version 2.45.0\n" : "git version 2.46.0\n"
        } else if failure == .ignoredIsolation,
            request.arguments.last?.hasPrefix("wegitisolation.probe") == true
        {
            text = "runtime\n"
        } else if failure == .ignoredURLReset, request.arguments.contains("get-url") {
            text = "original-fetch\nconfirmed-fetch\n"
        } else {
            text = nil
        }
        if let text {
            return ProcessResult(stdout: Data(text.utf8), stderr: Data(), exitCode: 0, duration: 0)
        }
        return try await ProcessRunner().run(request)
    }
}

struct GitInstallationTests {
    @Test(arguments: IncompatibleGitRunner.Failure.allCases)
    fileprivate func advertisedVersionsCannotBypassRequiredCapabilities(
        failure: IncompatibleGitRunner.Failure
    )
        async throws
    {
        await #expect(throws: ModelFailure.self) {
            _ = try await GitInstallation.detect(
                preferred: TestGit.executable, runner: IncompatibleGitRunner(failure: failure))
        }
    }
}
