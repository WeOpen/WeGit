import Foundation
import Testing

@testable import WeGitCore

struct GitSignatureTests {
    @Test func sshCommitAndTagVerificationDistinguishTrustMissingPolicyAndTampering() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        let directory = f.service.location.gitDirectory.appending(path: "signature-fixture")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let key = directory.appending(path: "signing")
        var environment = f.engine.environment
        environment["SSH_AUTH_SOCK"] = ""
        let created = try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
                arguments: ["-q", "-t", "ed25519", "-N", "", "-f", key.path], environment: environment))
        #expect(created.exitCode == 0)
        let publicKey = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = directory.appending(path: "allowed-signers")
        try Data(("fixture@example.invalid " + publicKey + "\n").utf8).write(to: allowed)
        for (name, value) in [
            ("gpg.format", "ssh"), ("gpg.ssh.program", "/usr/bin/ssh-keygen"),
            ("gpg.ssh.allowedSignersFile", allowed.path), ("user.signingkey", key.path),
            ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "true"),
        ] { _ = try await f.engine.run(["config", "--local", name, value], in: f.root) }
        try f.write("file", "signed original\n")
        let head = try await f.commit("Signed fixture")
        let index = try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index"))
        let result = try await f.service.verifySignature(head)
        #expect(result.state == .verified && result.cryptographicallyValid && result.identityTrusted)
        #expect(
            result.signer == "fixture@example.invalid" && result.fingerprint?.hasPrefix("SHA256:") == true)
        _ = try await f.engine.run(["tag", "-s", "fixture", "-m", "Signed tag", head], in: f.root)
        let tag = try await f.engine.run(["rev-parse", "refs/tags/fixture"], in: f.root).text
            .removingLastNewline
        #expect(try await f.service.verifySignature(tag, object: .tag).state == .verified)
        let raw = try await f.engine.run(["cat-file", "commit", head], in: f.root).stdout
        let tampered = try await f.engine.run(
            ["hash-object", "-w", "-t", "commit", "--stdin"], in: f.root,
            input: raw + Data("changed signed message\n".utf8)
        ).text.removingLastNewline
        let invalid = try await f.service.verifySignature(tampered)
        #expect(invalid.state == .invalid && !invalid.cryptographicallyValid)
        _ = try await f.engine.run(
            ["config", "--local", "--unset-all", "gpg.ssh.allowedSignersFile"], in: f.root)
        let unknown = try await f.service.verifySignature(head)
        #expect(unknown.state == .unverifiable && !unknown.identityTrusted)
        #expect(try await f.service.head() == head)
        #expect(try Data(contentsOf: f.service.location.gitDirectory.appending(path: "index")) == index)
        #expect(try Data(contentsOf: f.root.appending(path: "file")) == Data("signed original\n".utf8))
    }

    @Test func unsignedCommitAndLightweightTagDoNotNeedASigningProgram() async throws {
        let f = try await Fixture.create()
        defer { f.remove() }
        try f.write("file", "unsigned\n")
        let head = try await f.commit("Unsigned fixture")
        _ = try await f.engine.run(["config", "--local", "gpg.program", "/missing/fixture-gpg"], in: f.root)
        let commit = try await f.service.verifySignature(head)
        #expect(commit.state == .unsigned && !commit.cryptographicallyValid)
        let tag = try await f.service.verifySignature(head, object: .tag)
        #expect(tag.state == .unsigned && !tag.identityTrusted)
    }

    @Test func cryptographicValidityNeverBecomesTrustAndAnyBadSignatureBlocksSuccess() {
        let fingerprint = String(repeating: "A", count: 40)
        let good =
            "[GNUPG:] GOODSIG 12345678 Fixture\n[GNUPG:] VALIDSIG \(fingerprint) 2026-11-05 1793870000 0 4 0 22 8 00 \(fingerprint)\n"
        let raw = ProcessResult(
            stdout: Data(), stderr: Data((good + "[GNUPG:] TRUST_UNDEFINED 0 pgp\n").utf8), exitCode: 0,
            duration: 0.1)
        let untrusted = RepositoryService.signatureReport(
            objectID: String(repeating: "b", count: 40), object: .commit, format: "OpenPGP", result: raw)
        #expect(
            untrusted.state == .untrusted && untrusted.cryptographicallyValid && !untrusted.identityTrusted)
        let mixed = ProcessResult(
            stdout: Data(),
            stderr: Data((good + "[GNUPG:] TRUST_ULTIMATE 0 pgp\n[GNUPG:] BADSIG 87654321 Other\n").utf8),
            exitCode: 1, duration: 0.1)
        let invalid = RepositoryService.signatureReport(
            objectID: String(repeating: "b", count: 40), object: .commit, format: "OpenPGP", result: mixed)
        #expect(invalid.state == .invalid && !invalid.cryptographicallyValid && !invalid.identityTrusted)
    }
}
