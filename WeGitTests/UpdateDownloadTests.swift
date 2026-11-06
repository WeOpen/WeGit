import CryptoKit
import Foundation
import Testing

@testable import WeGitCore

@Suite(.serialized) struct UpdateDownloadTests {
    private func update() throws -> TrustedUpdate {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let digest = SHA256.hash(data: UpdateTestProtocol.body).map { String(format: "%02x", $0) }.joined()
        let artifacts = UpdateVariant.allCases.map { variant in
            let basename = "WeGit-2.0.1-macos-\(variant.rawValue)-adhoc"
            return UpdateArtifact(
                variant: variant,
                url: UpdateManifestValidator.assetURL(tag: "v2.0.1", name: basename + ".dmg").absoluteString,
                sha256: digest, downloadBytes: Int64(UpdateTestProtocol.body.count), installedBytes: 1024,
                manifestURL: UpdateManifestValidator.assetURL(
                    tag: "v2.0.1", name: basename + ".manifest.json"
                ).absoluteString,
                manifestSHA256: digest)
        }
        let manifest = UpdateManifest(
            version: "2.0.1", channel: .stable, build: 2,
            sourceCommit: String(repeating: "a", count: 40),
            publishedAt: formatter.string(from: now.addingTimeInterval(-60)),
            expiresAt: formatter.string(from: now.addingTimeInterval(3600)), keyID: "temporary-test-key",
            releaseNotes: "Private network fixture", artifacts: artifacts)
        let payload = try UpdateManifestValidator.canonicalJSON(manifest)
        let signed = try UpdateManifestValidator.canonicalJSON(
            SignedUpdateManifest(payload: payload, signature: key.signature(for: payload)))
        let ring = UpdateKeyRing(keys: [
            UpdatePublicKey(
                id: manifest.keyID, publicKey: key.publicKey.rawRepresentation,
                notBefore: now.addingTimeInterval(-3600), notAfter: now.addingTimeInterval(7200),
                minimumVersion: "2.0.0", channels: [.stable])
        ])
        guard
            case .available(let update) = try UpdateManifestValidator.validate(
                signed, ring: ring, channel: .stable,
                installed: InstalledUpdateVersion(version: "2.0.0", build: 1, variant: .universal),
                operatingSystem: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        else {
            throw UpdateFailure.invalidManifest
        }
        return update
    }

    @Test func verifiedDownloadHasExactBytesAndRejectsLaterChanges() async throws {
        UpdateTestProtocol.set(.success)
        let result = try await UpdateHTTPClient(testingProtocol: UpdateTestProtocol.self).download(update())
        #expect(result.byteCount == UpdateTestProtocol.body.count)
        try await result.validate()
        try Data("changed".utf8).write(to: result.url)
        await #expect(throws: UpdateFailure.self) { try await result.validate() }
    }

    @Test func truncatedOversizedCompressedOfflineAndRedirectedResponsesFail() async throws {
        let update = try update()
        let client = UpdateHTTPClient(testingProtocol: UpdateTestProtocol.self)
        for mode in [UpdateTestProtocol.Mode.truncated, .oversized, .compressed] {
            UpdateTestProtocol.set(mode)
            await #expect(throws: UpdateFailure.self) { try await client.download(update) }
        }
        UpdateTestProtocol.set(.offline)
        await #expect(throws: URLError.self) { try await client.download(update) }
        UpdateTestProtocol.set(.redirect)
        await #expect(throws: UpdateFailure.self) { try await client.download(update) }
    }

    @Test func cancellationStopsOnlyItsOwnTransfer() async throws {
        UpdateTestProtocol.set(.hang)
        let update = try update()
        let task = Task {
            try await UpdateHTTPClient(testingProtocol: UpdateTestProtocol.self).download(update)
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        UpdateTestProtocol.set(.success)
        let next = try await UpdateHTTPClient(testingProtocol: UpdateTestProtocol.self).download(update)
        try await next.validate()
    }
}

private final class UpdateTestProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable { case success, truncated, oversized, compressed, offline, hang, redirect }
    static let body = Data(repeating: 97, count: 1024)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: Mode = .success
    static func set(_ value: Mode) { lock.withLock { mode = value } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let mode = Self.lock.withLock { Self.mode }
        guard let url = request.url else { return }
        if mode == .hang { return }
        if mode == .offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if mode == .redirect {
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": "https://evil.example/update.dmg"])!
            client?.urlProtocol(
                self, wasRedirectedTo: URLRequest(url: URL(string: "https://evil.example/update.dmg")!),
                redirectResponse: response)
            return
        }
        var headers = [
            "Content-Length": mode == .oversized ? String(31 * 1024 * 1024) : String(Self.body.count)
        ]
        if mode == .compressed { headers["Content-Encoding"] = "gzip" }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: mode == .truncated ? Data(Self.body.prefix(128)) : Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
