import Darwin
import Foundation
import Testing

@testable import WeGitCore

private final class AuthenticationBundleAnchor: NSObject {}

private actor PromptTrace {
    var requests: [AuthenticationRequest] = []
    func record(_ request: AuthenticationRequest) { requests.append(request) }
}

private struct CredentialEchoRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        guard let helper = request.environment["GIT_ASKPASS"] else { throw AuthenticationFailure.unavailable }
        let response = try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: helper),
                arguments: ["Password:"], environment: request.environment))
        return ProcessResult(stdout: Data(), stderr: response.stdout, exitCode: 1, duration: 0)
    }
}

struct AuthenticationTests {
    @Test func longEchoedSecretsAreRemovedBeforeDiagnosticTruncation() async throws {
        let secret = "fixture-" + String(repeating: "sensitive", count: 1500)
        let bridge = AskPassBridge(helper: try helper()) { _ in secret }
        let engine = TestGit.engine(
            runner: CredentialEchoRunner(), authentication: bridge,
            environment: environment(ProcessInfo.processInfo.environment))
        do {
            _ = try await engine.run(["fetch", "origin"])
            Issue.record("The synthetic operation should fail")
        } catch let error as GitFailure {
            #expect(error.details == "[redacted]\n")
            #expect(!error.details.contains("sensitive"))
        }
    }

    private func helper() throws -> URL {
        let url = Bundle(for: AuthenticationBundleAnchor.self).bundleURL.deletingLastPathComponent()
            .appending(path: "WeGitAskPass")
        try #require(
            FileManager.default.isExecutableFile(atPath: url.path),
            "The package must build its bundled AskPass helper")
        return url
    }

    private func environment(_ source: [String: String]) -> [String: String] {
        var result = source
        for key in [
            "GIT_ASKPASS", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "WEGIT_ASKPASS_SOCKET",
            "WEGIT_ASKPASS_TOKEN",
        ] {
            result.removeValue(forKey: key)
        }
        return result
    }

    @Test func gitCredentialsTravelThroughTheHelperAndNeverEnterActivityOrArguments() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let spaced = f.root.appending(path: "helper with 'quotes' and spaces")
        try FileManager.default.copyItem(at: helper(), to: spaced)
        let trace = PromptTrace()
        let bridge = AskPassBridge(helper: spaced) { request in
            await trace.record(request)
            return request.kind == .username ? "fixture-user" : "fixture-secret-token"
        }
        let engine = TestGit.engine(authentication: bridge, environment: environment(f.engine.environment))
        let result = try await engine.run(
            ["credential", "fill"], in: f.root,
            input: Data("protocol=https\nhost=example.invalid\n\n".utf8),
            configuration: [("credential.helper", "")])
        #expect(
            result.text.contains("username=fixture-user")
                && result.text.contains("password=fixture-secret-token"))
        #expect(await trace.requests.map(\.kind) == [.username, .secret])
        #expect(await trace.requests.allSatisfy { $0.command == "credential" && $0.repository == f.root })
        let activity = await engine.activity.all()
        #expect(
            activity.allSatisfy {
                !$0.command.contains("fixture-secret-token") && !$0.details.contains("fixture-secret-token")
            })
        #expect(!engine.environment.values.contains("fixture-secret-token"))
    }

    @Test func invalidCapabilitiesCannotPromptAndRepliesAreRedactedUntilTheSessionCloses() async throws {
        let helper = try helper()
        let trace = PromptTrace()
        let session = try AskPassSession(helper: helper, command: "push", repository: nil) { request in
            await trace.record(request)
            return "sample-secret-with-spaces"
        }
        defer { session.close() }
        let valid = session.environment(over: environment(ProcessInfo.processInfo.environment))
        var invalid = valid
        invalid["WEGIT_ASKPASS_TOKEN"] = String(repeating: "0", count: 64)
        let refused = try await ProcessRunner().run(
            ProcessRequest(
                executable: helper, arguments: ["Password for https://example.invalid:"], environment: invalid
            ))
        #expect(refused.exitCode != 0 && refused.stdout.isEmpty && refused.stderr.isEmpty)
        #expect(await trace.requests.isEmpty)
        let accepted = try await ProcessRunner().run(
            ProcessRequest(
                executable: helper, arguments: ["Password for https://example.invalid:"], environment: valid))
        #expect(accepted.text == "sample-secret-with-spaces\n")
        #expect(session.redact("server echoed sample-secret-with-spaces") == "server echoed [redacted]")
        let socket = session.socketPath
        var info = stat()
        #expect(lstat(socket, &info) == 0 && info.st_mode & 0o777 == 0o600)
        let directory = URL(fileURLWithPath: socket).deletingLastPathComponent().path
        #expect(lstat(directory, &info) == 0 && info.st_mode & 0o777 == 0o700)
        session.close()
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    @Test(.timeLimit(.minutes(1))) func closingTheCommandCancelsItsPendingAuthentication() async throws {
        let helper = try helper()
        let trace = PromptTrace()
        let session = try AskPassSession(helper: helper, command: "clone", repository: nil) { request in
            await trace.record(request)
            try await Task.sleep(for: .seconds(30))
            return "never returned"
        }
        defer { session.close() }
        let env = session.environment(over: environment(ProcessInfo.processInfo.environment))
        let operation = Task {
            try await ProcessRunner().run(
                ProcessRequest(executable: helper, arguments: ["Password:"], environment: env))
        }
        while await trace.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        session.close()
        let result = try await operation.value
        #expect(result.exitCode != 0 && result.stdout.isEmpty && result.stderr.isEmpty)
    }

    @Test func unansweredAuthenticationHasABoundedLifetime() async throws {
        let helper = try helper()
        let session = try AskPassSession(
            helper: helper, command: "fetch", repository: nil,
            promptTimeout: .milliseconds(50)
        ) { _ in
            try await Task.sleep(for: .seconds(30))
            return "never returned"
        }
        defer { session.close() }
        let start = ContinuousClock.now
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: helper, arguments: ["Password:"],
                environment: session.environment(over: environment(ProcessInfo.processInfo.environment))))
        #expect(result.exitCode != 0 && result.stdout.isEmpty)
        #expect(start.duration(to: .now) < .seconds(3))
    }

    @Test func hostConfirmationIsExplicitAndExistingAskPassProgramsArePreserved() async throws {
        let helper = try helper()
        let trace = PromptTrace()
        let session = try AskPassSession(helper: helper, command: "fetch", repository: nil) { request in
            await trace.record(request)
            return nil
        }
        defer { session.close() }
        var env = session.environment(over: environment(ProcessInfo.processInfo.environment))
        env["SSH_ASKPASS_PROMPT"] = "confirm"
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: helper,
                arguments: [
                    "The authenticity of host example.invalid cannot be established. SHA256:fixture-fingerprint"
                ], environment: env))
        #expect(result.exitCode != 0 && result.stdout.isEmpty)
        #expect(await trace.requests.first?.kind == .hostConfirmation)
        #expect(await trace.requests.first?.prompt.contains("SHA256:fixture-fingerprint") == true)
        let preserved = session.environment(over: [
            "GIT_ASKPASS": "/custom/git-askpass", "SSH_ASKPASS": "/custom/ssh-askpass",
        ])
        #expect(preserved["GIT_ASKPASS"] == "/custom/git-askpass")
        #expect(preserved["SSH_ASKPASS"] == "/custom/ssh-askpass" && preserved["SSH_ASKPASS_REQUIRE"] == nil)
    }

    @Test func encryptedSSHSigningCanAskForAPassphraseWithoutATerminal() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let key = f.root.appending(path: "fixture-key")
        let payload = f.root.appending(path: "payload")
        try Data("signed fixture\n".utf8).write(to: payload)
        let runner = ProcessRunner()
        let created = try await runner.run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                arguments: ["-q", "-t", "ed25519", "-N", "fixture-only-passphrase", "-f", key.path],
                environment: environment(f.engine.environment)))
        #expect(created.exitCode == 0)
        let trace = PromptTrace()
        let session = try AskPassSession(helper: helper(), command: "commit", repository: f.root) { request in
            await trace.record(request)
            return "fixture-only-passphrase"
        }
        defer { session.close() }
        let signed = try await runner.run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                arguments: ["-Y", "sign", "-f", key.path, "-n", "git", payload.path],
                environment: session.environment(over: environment(f.engine.environment))))
        #expect(signed.exitCode == 0)
        #expect(await trace.requests.contains { $0.kind == .secret })
        #expect(FileManager.default.fileExists(atPath: payload.appendingPathExtension("sig").path))
    }
}
