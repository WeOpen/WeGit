import Darwin
import Foundation
import WeGitCore

private enum CheckFailure: Error {
    case assertion(String)
    case command(String, Int32)
}

private struct Report: Encodable {
    var result = "failed"
    var phase = "prerequisites"
    var gitKind: String
    var gitVersion = ""
    var gpgVersion = ""
    var checks: [String] = []
    var privateAgentStopped = false
    var fixtureRemoved = false
    var errorType: String?
    let scope = "RepositoryService with an ephemeral unprotected OpenPGP key and private configuration"
    let exclusions = ["Interactive Pinentry", "Hardware keys", "Real service credentials", "Native UI"]
}

@main
struct GPGCompatibilityChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 6 else {
            print("Usage: checks git gpg gpgconf report.json apple-or-homebrew")
            exit(2)
        }
        let arguments = CommandLine.arguments
        let git = URL(fileURLWithPath: arguments[1])
        let gpg = URL(fileURLWithPath: arguments[2])
        let gpgconf = URL(fileURLWithPath: arguments[3])
        let destination = URL(fileURLWithPath: arguments[4])
        var report = Report(gitKind: arguments[5])
        var template = Array("/tmp/WeGitGPG-XXXXXX".utf8CString)
        guard let path = mkdtemp(&template) else { throw POSIXError(.EIO) }
        let root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        let home = root.appending(path: "g", directoryHint: .isDirectory)
        let repository = root.appending(path: "repository", directoryHint: .isDirectory)
        let global = root.appending(path: "global-config")
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("GIT_") {
            environment.removeValue(forKey: key)
        }
        environment.removeValue(forKey: "GPG_AGENT_INFO")
        environment.removeValue(forKey: "GPG_TTY")
        environment["GNUPGHOME"] = home.path
        environment["GIT_CONFIG_GLOBAL"] = global.path
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["LC_ALL"] = "C"
        let runner = ProcessRunner()
        var agentMayExist = false

        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw CheckFailure.assertion(name) }
            report.checks.append(name)
        }
        func tool(_ executable: URL, _ values: [String], name: String) async throws -> ProcessResult {
            let result = try await runner.run(
                ProcessRequest(
                    executable: executable, arguments: values, environment: environment, timeout: 30))
            guard result.exitCode == 0 else { throw CheckFailure.command(name, result.exitCode) }
            return result
        }

        do {
            for folder in [home, repository] {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
            try Data().write(to: global, options: .withoutOverwriting)
            try Data("batch\nno-tty\npinentry-mode loopback\nno-auto-key-retrieve\n".utf8)
                .write(to: home.appending(path: "gpg.conf"), options: .withoutOverwriting)
            let installation = try await GitInstallation.detect(preferred: git)
            report.gitVersion = installation.version
            report.gpgVersion =
                try await tool(gpg, ["--version"], name: "GPG version")
                .text.split(separator: "\n").first.map(String.init) ?? ""
            try require(!report.gpgVersion.isEmpty, "Supported Git and real GPG detected")
            report.phase = "ephemeral-key-generation"
            agentMayExist = true
            _ = try await tool(
                gpg,
                [
                    "--batch", "--pinentry-mode", "loopback", "--passphrase", "",
                    "--quick-generate-key", "WeGit Compatibility <tests@example.invalid>",
                    "ed25519", "sign", "1d",
                ], name: "Ephemeral key generation")
            let listing = try await tool(
                gpg, ["--batch", "--with-colons", "--list-secret-keys"], name: "Private key listing")
            let fingerprint = listing.text.split(separator: "\n").first { $0.hasPrefix("fpr:") }?
                .split(separator: ":", omittingEmptySubsequences: false).dropFirst(9).first.map(String.init)
            guard let fingerprint,
                fingerprint.range(of: "^(?:[0-9A-F]{40}|[0-9A-F]{64})$", options: .regularExpression) != nil
            else { throw CheckFailure.assertion("One usable test fingerprint") }
            let engine = GitEngine(executable: installation.executable, environment: environment)
            _ = try await engine.run(["init", "-b", "main"], in: repository)
            for (key, value) in [
                ("user.name", "WeGit Compatibility"), ("user.email", "tests@example.invalid"),
                ("gpg.program", gpg.path), ("gpg.format", "openpgp"),
                ("user.signingkey", fingerprint), ("commit.gpgsign", "true"),
            ] {
                _ = try await engine.run(["config", "--file", global.path, key, value], in: repository)
            }
            let globalBytes = try Data(contentsOf: global)
            let origin = try await engine.run(
                ["config", "--show-origin", "--get", "commit.gpgsign"], in: repository
            ).text
            try require(
                origin.contains(global.path) && origin.hasSuffix("\ttrue\n"),
                "Private global signing configuration inherited")
            let location = try await RepositoryService.discover(repository, engine: engine)
            let service = RepositoryService(location: location, engine: engine)
            let file = repository.appending(path: "sample.txt")

            func stage(_ text: String) async throws -> RepositoryStatus {
                try Data(text.utf8).write(to: file)
                let status = try await service.status()
                try await service.stage(paths: ["sample.txt"], expectedHead: status.head)
                return try await service.status()
            }
            func verifySignature(_ oid: String) async throws -> Bool {
                let result = try await engine.run(["verify-commit", "--raw", oid], in: repository)
                let status = String(decoding: result.stderr, as: UTF8.self)
                return status.contains("[GNUPG:] VALIDSIG " + fingerprint + " ")
            }

            report.phase = "signed-commit"
            let initial = try await stage("Signed content\t你好\r\n")
            let signed = try await service.commit(
                message: "Signed through WeGit", amend: false, expectedHead: initial.head)
            try require(
                try await verifySignature(signed),
                "RepositoryService creates a verifiable signature with the configured key")
            report.phase = "invalid-signing-key"
            _ = try await engine.run(
                ["config", "user.signingkey", String(repeating: "0", count: 40)], in: repository)
            let pending = try await stage("Content retained after a signing failure\n")
            var rejected = false
            do {
                _ = try await service.commit(
                    message: "Must not commit", amend: false, expectedHead: pending.head)
            } catch { rejected = true }
            let afterFailure = try await service.status()
            try require(
                rejected && afterFailure.head == signed
                    && afterFailure.files.contains { $0.path == "sample.txt" && $0.staged },
                "An invalid signing key leaves HEAD and staged content intact")
            report.phase = "repository-override"
            _ = try await engine.run(["config", "commit.gpgsign", "false"], in: repository)
            let unsigned = try await service.commit(
                message: "Repository override", amend: false, expectedHead: afterFailure.head)
            let unsignedObject = try await engine.run(["cat-file", "-p", unsigned], in: repository).text
            try require(
                !unsignedObject.contains("\ngpgsig "), "Repository configuration can override global signing")
            report.phase = "restore-inheritance"
            for key in ["commit.gpgsign", "user.signingkey"] {
                _ = try await engine.run(["config", "--unset", key], in: repository)
            }
            let restored = try await stage("Inherited signing restored\n")
            let resigned = try await service.commit(
                message: "Global signing restored", amend: false, expectedHead: restored.head)
            try require(try await verifySignature(resigned), "Removing local values restores signed commits")
            try require(
                try Data(contentsOf: global) == globalBytes, "Global configuration bytes remain unchanged")
            report.result = "passed"
        } catch {
            report.errorType = String(reflecting: type(of: error))
        }
        if agentMayExist {
            let stopped = try? await tool(
                gpgconf, ["--homedir", home.path, "--kill", "gpg-agent"], name: "Stop private agent")
            report.privateAgentStopped = stopped?.exitCode == 0
        } else {
            report.privateAgentStopped = true
        }
        do {
            try FileManager.default.removeItem(at: root)
            report.fixtureRemoved = !FileManager.default.fileExists(atPath: root.path)
        } catch { report.fixtureRemoved = false }
        if !report.privateAgentStopped || !report.fixtureRemoved { report.result = "failed" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: destination)
        print(
            "\(report.gitKind): \(report.result), \(report.checks.count) behavior checks, phase \(report.phase)"
        )
        if report.result != "passed" { exit(1) }
    }
}
