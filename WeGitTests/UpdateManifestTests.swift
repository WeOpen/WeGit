import CryptoKit
import Foundation
import Testing

@testable import WeGitCore

struct UpdateManifestTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func fixture(
        version: String = "2.0.0", channel: UpdateChannel = .stable,
        build: UInt64 = 2, mutation: ((inout [String: Any]) -> Void)? = nil
    ) throws -> (Data, UpdateKeyRing) {
        let key = Curve25519.Signing.PrivateKey()
        let formatter = ISO8601DateFormatter()
        let artifacts = UpdateVariant.allCases.map { variant in
            let basename = "WeGit-\(version)-macos-\(variant.rawValue)-adhoc"
            return UpdateArtifact(
                variant: variant,
                url: UpdateManifestValidator.assetURL(tag: "v" + version, name: basename + ".dmg")
                    .absoluteString,
                sha256: String(repeating: "a", count: 64), downloadBytes: 1024, installedBytes: 2048,
                manifestURL: UpdateManifestValidator.assetURL(
                    tag: "v" + version, name: basename + ".manifest.json"
                ).absoluteString,
                manifestSHA256: String(repeating: "b", count: 64))
        }
        let manifest = UpdateManifest(
            version: version, channel: channel, build: build,
            sourceCommit: String(repeating: "a", count: 40),
            publishedAt: formatter.string(from: now.addingTimeInterval(-60)),
            expiresAt: formatter.string(from: now.addingTimeInterval(3600)), keyID: "temporary-test-key",
            releaseNotes: "中文更新说明\nPreserve drafts", artifacts: artifacts)
        var payload = try UpdateManifestValidator.canonicalJSON(manifest)
        if let mutation {
            var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            mutation(&object)
            payload = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        let envelope = try UpdateManifestValidator.canonicalJSON(
            SignedUpdateManifest(
                payload: payload,
                signature: key.signature(for: payload)))
        let ring = UpdateKeyRing(keys: [
            UpdatePublicKey(
                id: "temporary-test-key", publicKey: key.publicKey.rawRepresentation,
                notBefore: now.addingTimeInterval(-3600), notAfter: now.addingTimeInterval(7200),
                minimumVersion: "2.0.0-rc.1", maximumVersion: "2.9.9", channels: [.stable, .candidate])
        ])
        return (envelope, ring)
    }

    private func validate(
        _ bytes: Data, _ ring: UpdateKeyRing, channel: UpdateChannel = .stable,
        version: String = "1.2.0", build: UInt64 = 1, variant: UpdateVariant = .universal,
        hardware: UpdateHardware = .init(appleSilicon: true)
    ) throws -> UpdateCheckResult {
        try UpdateManifestValidator.validate(
            bytes, ring: ring, channel: channel,
            installed: InstalledUpdateVersion(version: version, build: build, variant: variant),
            hardware: hardware,
            operatingSystem: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            now: now)
    }

    @Test func versionOrderingAndMalformedNumbers() throws {
        let values = ["1.2.0", "2.0.0-alpha.1", "2.0.0-beta.1", "2.0.0-rc.1", "2.0.0-rc.2", "2.0.0", "2.0.1"]
        let parsed = try values.map(UpdateVersion.init)
        #expect(parsed == parsed.sorted())
        for value in ["v2.0.0", "02.0.0", "2.0", "2.0.0-rc.01", "2.0.0+build", "2.0.0;echo"] {
            #expect(throws: UpdateFailure.self) { try UpdateVersion(value) }
        }
    }

    @Test func independentSignatureIsRequiredAndTamperingFails() throws {
        let (bytes, ring) = try fixture()
        guard case .available(let update) = try validate(bytes, ring) else {
            Issue.record("Expected an update")
            return
        }
        #expect(update.manifest.version == "2.0.0")
        let signed = try JSONDecoder().decode(SignedUpdateManifest.self, from: bytes)
        let tampered = try UpdateManifestValidator.canonicalJSON(
            SignedUpdateManifest(
                payload: signed.payload,
                signature: Data(repeating: 0, count: 64)))
        #expect(throws: UpdateFailure.self) { try validate(tampered, ring) }
        #expect(throws: UpdateFailure.self) { try validate(bytes, UpdateKeyRing(keys: [])) }
        let unknown = UpdateKeyRing(keys: [
            UpdatePublicKey(
                id: "another", publicKey: ring.keys[0].publicKey,
                notBefore: ring.keys[0].notBefore, notAfter: ring.keys[0].notAfter, minimumVersion: "2.0.0",
                channels: [.stable])
        ])
        #expect(throws: UpdateFailure.self) { try validate(bytes, unknown) }
    }

    @Test func currentVersionDoesNotDownloadAndDowngradesFail() throws {
        let (bytes, ring) = try fixture()
        guard case .current = try validate(bytes, ring, version: "2.0.0", build: 2) else {
            Issue.record("Same version/build must not download again")
            return
        }
        #expect(throws: UpdateFailure.self) { try validate(bytes, ring, version: "2.0.1") }
        #expect(throws: UpdateFailure.self) { try validate(bytes, ring, version: "2.0.0", build: 3) }
    }

    @Test func stableRejectsDraftAndCandidateNeedsExplicitChannel() throws {
        let (draft, draftRing) = try fixture(mutation: { $0["draft"] = true })
        #expect(throws: UpdateFailure.self) { try validate(draft, draftRing) }
        let (candidate, ring) = try fixture(version: "2.0.0-rc.2", channel: .candidate)
        #expect(throws: UpdateFailure.self) { try validate(candidate, ring) }
        guard case .available = try validate(candidate, ring, channel: .candidate) else {
            Issue.record("Explicit candidate selection should accept a valid RC")
            return
        }
    }

    @Test func expiryAndKeyRotationScopeFailClosed() throws {
        let formatter = ISO8601DateFormatter()
        let (expired, ring) = try fixture(mutation: {
            $0["expiresAt"] = formatter.string(from: now.addingTimeInterval(-1))
        })
        #expect(throws: UpdateFailure.self) { try validate(expired, ring) }
        let (bytes, versionRing) = try fixture(version: "3.0.0")
        #expect(throws: UpdateFailure.self) { try validate(bytes, versionRing) }
        let (fresh, freshRing) = try fixture()
        let expiredKey = UpdateKeyRing(keys: [
            UpdatePublicKey(
                id: freshRing.keys[0].id,
                publicKey: freshRing.keys[0].publicKey, notBefore: now.addingTimeInterval(-3600),
                notAfter: now.addingTimeInterval(-1), minimumVersion: "2.0.0", channels: [.stable])
        ])
        #expect(throws: UpdateFailure.self) { try validate(fresh, expiredKey) }
    }

    @Test func arbitrarySourcesMixedVariantsAndOversizedAssetsFail() throws {
        for field in ["url", "downloadBytes", "variant"] {
            let (bytes, ring) = try fixture(mutation: { object in
                var artifacts = object["artifacts"] as! [[String: Any]]
                if field == "url" { artifacts[0][field] = "https://evil.example/WeGit.dmg" }
                if field == "downloadBytes" { artifacts[0][field] = 31 * 1024 * 1024 }
                if field == "variant" { artifacts[0][field] = "intel" }
                object["artifacts"] = artifacts
            })
            #expect(throws: UpdateFailure.self) { try validate(bytes, ring) }
        }
    }

    @Test func installedVariantAndHardwareSurviveRosetta() throws {
        let (bytes, ring) = try fixture()
        guard
            case .available(let universal) = try validate(
                bytes, ring, hardware: .init(appleSilicon: true, translated: true))
        else {
            Issue.record("Expected a Universal update")
            return
        }
        #expect(universal.artifact.variant == .universal)
        guard
            case .available(let intel) = try validate(
                bytes, ring, variant: .intel,
                hardware: .init(appleSilicon: true, translated: true))
        else {
            Issue.record("Expected an Intel update")
            return
        }
        #expect(intel.artifact.variant == .intel)
        #expect(throws: UpdateFailure.self) {
            try validate(bytes, ring, variant: .applesilicon, hardware: .init(appleSilicon: false))
        }
    }

    @Test func explicitOriginalFormatBackupKeepsAllValuesAndBlocksBusyInstall() async throws {
        let values: [String: Any] = [
            "customTheme": Data([0, 1, 255]), "favorites": ["a", "b"],
            "draft-v2:worktree": "中文\r\nDraft", "workspace:private": Data([9, 8, 7]),
        ]
        let bytes = try PropertyListSerialization.data(
            fromPropertyList: ["format": 1, "values": values], format: .binary, options: 0)
        let backup = try UpdateDataBackup(originalPreferences: bytes, currentPreferences: bytes)
        #expect(NSDictionary(dictionary: try backup.originalValues()).isEqual(to: values))
        let (manifest, ring) = try fixture()
        guard case .available(let update) = try validate(manifest, ring) else {
            Issue.record("Expected update")
            return
        }
        await #expect(throws: UpdateFailure.self) {
            try await UpdateInstaller.preflight(
                currentApp: URL(fileURLWithPath: "/not-a-real-app"),
                replacementApp: URL(fileURLWithPath: "/not-a-real-replacement"), update: update,
                packageManifest: Data(), dataBackup: backup,
                activity: UpdateInstallationActivity(
                    busyTasks: 1, windowIDs: [], persistedWindowIDs: [], persistenceFlushed: true,
                    generation: 1))
        }
    }
}
