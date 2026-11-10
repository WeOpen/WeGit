import CryptoKit
import Foundation
import WeGitCore

/// Independent, non-XCTest controls. All packages, keys and preference bytes are
/// temporary; no installed application, real domain or system protection is changed.
@main struct UpdateChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw failure("Expected an output JSON path") }
        var passed: [String] = []
        func check(_ name: String, _ valid: Bool) throws {
            guard valid else { throw failure(name) }
            passed.append(name)
            FileHandle.standardError.write(Data(("Control passed: " + name + "\n").utf8))
        }
        let sandbox = try UpdateInstallationSandbox()
        try app(at: sandbox.currentApp, version: "2.0.0", build: 1)
        try app(at: sandbox.replacementApp, version: "2.0.1", build: 2)
        let original: [String: Any] = [
            "customTheme": Data([0, 1, 255]), "favorites": ["one", "two"],
            "draft-v2:private-worktree": "中文\r\nDraft", "workspace:private": Data([9, 8, 7]),
        ]
        let originalBytes = try PropertyListSerialization.data(
            fromPropertyList: ["format": 1, "values": original], format: .binary, options: 0)
        let currentBytes = try PropertyListSerialization.data(
            fromPropertyList: [
                "format": 1,
                "values": [
                    "v2.shared-draft:private-worktree": Data("New 中文 draft".utf8),
                    "v2.window-sessions": Data([1, 2]),
                ],
            ], format: .binary, options: 0)
        let backup = try UpdateDataBackup(
            originalPreferences: originalBytes, currentPreferences: currentBytes)
        try check(
            "Original preferences retain all values and exact legacy bytes",
            NSDictionary(dictionary: try backup.originalValues()).isEqual(to: original))
        let package = try packageManifest(sandbox.replacementApp)
        let fixture = try signedFixture(package: package, installedBytes: bundleBytes(sandbox.replacementApp))
        let installed = try InstalledUpdateVersion(version: "2.0.0", build: 1, variant: .universal)
        let validate = { (bytes: Data, ring: UpdateKeyRing, version: InstalledUpdateVersion) in
            try UpdateManifestValidator.validate(
                bytes, ring: ring, channel: .stable, installed: version,
                operatingSystem: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        }
        guard case .available(let update) = try validate(fixture.bytes, fixture.ring, installed) else {
            throw failure("Expected update")
        }
        try check(
            "Temporary Ed25519 key authenticates exact canonical payload", update.manifest.version == "2.0.1")
        let current = try InstalledUpdateVersion(version: "2.0.1", build: 2, variant: .universal)
        guard case .current = try validate(fixture.bytes, fixture.ring, current) else {
            throw failure("Duplicate update")
        }
        passed.append("Same version and build do not download again")
        do {
            _ = try validate(fixture.bytes, UpdateKeyRing(keys: []), installed)
            throw failure("Missing ring accepted")
        } catch is UpdateFailure {
            passed.append("Missing production key ring fails closed before networking")
        }
        let signature = try JSONDecoder().decode(SignedUpdateManifest.self, from: fixture.bytes)
        let tampered = try UpdateManifestValidator.canonicalJSON(
            SignedUpdateManifest(payload: signature.payload, signature: Data(repeating: 0, count: 64)))
        do {
            _ = try validate(tampered, fixture.ring, installed)
            throw failure("Tampered signature accepted")
        } catch is UpdateFailure { passed.append("Invalid source signature refuses update") }
        let downgrade = try InstalledUpdateVersion(version: "2.0.2", build: 3, variant: .universal)
        do {
            _ = try validate(fixture.bytes, fixture.ring, downgrade)
            throw failure("Downgrade accepted")
        } catch is UpdateFailure { passed.append("Downgrade requires explicit backup rollback") }
        let window = UUID()
        let activity = UpdateInstallationActivity(
            busyTasks: 0, windowIDs: [window], persistedWindowIDs: [window], persistenceFlushed: true,
            generation: 1)
        let busy = UpdateInstallationActivity(
            busyTasks: 1, windowIDs: [window], persistedWindowIDs: [window], persistenceFlushed: true,
            generation: 1)
        do {
            _ = try await UpdateInstaller.preflight(
                currentApp: sandbox.currentApp, replacementApp: sandbox.replacementApp,
                update: update, packageManifest: package, dataBackup: backup, activity: busy)
            throw failure("Busy installation accepted")
        } catch is UpdateFailure { passed.append("Busy window/task snapshot blocks installation") }
        FileHandle.standardError.write(Data("Preparing installation\n".utf8))
        let plan = try await UpdateInstaller.preflight(
            currentApp: sandbox.currentApp, replacementApp: sandbox.replacementApp,
            update: update, packageManifest: package, dataBackup: backup, activity: activity)
        try check(
            "Preflight retains space for two packages and both data snapshots",
            plan.requiredBytes >= backup.byteCount + bundleBytes(sandbox.currentApp)
                + bundleBytes(sandbox.replacementApp))
        let changedActivity = UpdateInstallationActivity(
            busyTasks: 0, windowIDs: [window], persistedWindowIDs: [window], persistenceFlushed: true,
            generation: 2)
        do {
            _ = try await UpdateInstaller.install(plan, in: sandbox, activity: changedActivity)
            throw failure("Changed window generation accepted")
        } catch is UpdateFailure { passed.append("Changed window generation invalidates old preflight") }
        FileHandle.standardError.write(
            Data(
                ("Installing replacement: " + plan.currentApp.absoluteString + " vs "
                    + sandbox.currentApp.absoluteString + "\n").utf8))
        let receipt = try await UpdateInstaller.install(plan, in: sandbox, activity: activity)
        try check(
            "Replacement installed with previous package retained",
            try version(receipt.installedApp) == "2.0.1" && version(receipt.previousApp) == "2.0.0")
        try check(
            "Both preference snapshots are byte identical",
            try Data(contentsOf: receipt.originalPreferences) == originalBytes
                && Data(contentsOf: receipt.currentPreferences) == currentBytes)
        do {
            try await UpdateInstaller.confirmLaunch(receipt, observedVersion: "2.0.0", observedBuild: 1)
            throw failure("Wrong launch version accepted")
        } catch is UpdateFailure { passed.append("Observed launch version/build must match replacement") }
        FileHandle.standardError.write(Data("Rolling back replacement\n".utf8))
        try await UpdateInstaller.rollback(receipt)
        try check(
            "Explicit launch-failure rollback restores old app and preserves rejected app",
            try version(sandbox.currentApp) == "2.0.0"
                && version(sandbox.root.appending(path: "FailedReplacement.app")) == "2.0.1")
        let journal =
            try JSONSerialization.jsonObject(with: Data(contentsOf: receipt.journal)) as! [String: Any]
        try check(
            "Rollback journal retains signed source and data checksums",
            journal["phase"] as? String == "rolled-back"
                && journal["manifestSHA256"] as? String == update.payloadSHA256)
        var samples: [Double] = []
        for _ in 0..<30 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = try validate(fixture.bytes, fixture.ring, installed)
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let report: [String: Any] = [
            "passed": passed, "total": passed.count, "failed": 0,
            "scope":
                "Private non-XCTest controls; synthetic package metadata, real ad-hoc signatures and isolated atomic install/rollback",
            "productionKeyConfigured": false, "published": false, "xctestExecuted": false,
            "manifestValidationMilliseconds": samples, "manifestBytes": fixture.bytes.count,
            "manifestValidationP95Milliseconds": samples.sorted()[28],
        ]
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output, options: .atomic)
        try sandbox.removeAfterInspection()
        print("\(passed.count) isolated update controls passed; report: \(output.path)")
    }

    private static func app(at url: URL, version: String, build: Int) throws {
        let manager = FileManager.default
        for name in ["Contents/MacOS", "Contents/Helpers", "Contents/Resources"] {
            try manager.createDirectory(at: url.appending(path: name), withIntermediateDirectories: true)
        }
        try manager.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: url.appending(path: "Contents/MacOS/WeGit"))
        try manager.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: url.appending(path: "Contents/Helpers/WeGitAskPass"))
        let info = [
            "CFBundleIdentifier": "com.willxue.wegit", "CFBundleExecutable": "WeGit",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "CFBundleVersion": String(build),
            "LSMinimumSystemVersion": "26.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
            to: url.appending(path: "Contents/Info.plist"))
        try JSONSerialization.data(withJSONObject: ["architectures": ["arm64", "x86_64"]]).write(
            to: url.appending(path: "Contents/Resources/build-source.json"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", "--timestamp=none", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("Private fixture signing failed") }
    }

    private static func bundleBytes(_ url: URL) throws -> Int64 {
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])!
        var count: Int64 = 0
        for case let file as URL in enumerator {
            let value = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if value.isRegularFile == true { count += Int64(value.fileSize ?? 0) }
        }
        return count
    }

    private static func version(_ url: URL) throws -> String {
        let info =
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url.appending(path: "Contents/Info.plist")), format: nil)
            as! [String: Any]
        return info["CFBundleShortVersionString"] as! String
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func packageManifest(_ app: URL) throws -> Data {
        var binaries: [String: Any] = [:]
        for path in ["Contents/MacOS/WeGit", "Contents/Helpers/WeGitAskPass"] {
            binaries[path] = [
                "sha256": digest(try Data(contentsOf: app.appending(path: path))),
                "architectures": ["arm64", "x86_64"],
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "gitCommit": String(repeating: "a", count: 40), "releaseTag": "v2.0.1",
                "version": "2.0.1", "buildVersion": "2", "bundleIdentifier": "com.willxue.wegit",
                "workspaceDirty": false,
                "mode": "adhoc", "signing": "ad-hoc", "notarized": false,
                "minimumSystemVersion": "26.0",
                "buildReceiptSHA256": digest(
                    try Data(contentsOf: app.appending(path: "Contents/Resources/build-source.json"))),
                "architectures": ["arm64", "x86_64"], "archiveSHA256": String(repeating: "b", count: 64),
                "imageBytes": 1024, "bundleBytes": bundleBytes(app), "binaries": binaries,
            ], options: [.sortedKeys])
    }

    private static func signedFixture(package: Data, installedBytes: Int64) throws -> (
        bytes: Data, ring: UpdateKeyRing
    ) {
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let artifacts = UpdateVariant.allCases.map { variant in
            let name = "WeGit-2.0.1-macos-\(variant.rawValue)-adhoc"
            let base = "https://github.com/WeOpen/WeGit/releases/download/v2.0.1/"
            return UpdateArtifact(
                variant: variant, url: base + name + ".dmg", sha256: String(repeating: "b", count: 64),
                downloadBytes: 1024, installedBytes: installedBytes,
                manifestURL: base + name + ".manifest.json", manifestSHA256: digest(package))
        }
        let manifest = UpdateManifest(
            version: "2.0.1", channel: .stable, build: 2, sourceCommit: String(repeating: "a", count: 40),
            publishedAt: formatter.string(from: now.addingTimeInterval(-60)),
            expiresAt: formatter.string(from: now.addingTimeInterval(3600)),
            keyID: "temporary-control-key", releaseNotes: "Isolated fixture", artifacts: artifacts)
        let payload = try UpdateManifestValidator.canonicalJSON(manifest)
        let bytes = try UpdateManifestValidator.canonicalJSON(
            SignedUpdateManifest(payload: payload, signature: key.signature(for: payload)))
        let ring = UpdateKeyRing(keys: [
            UpdatePublicKey(
                id: manifest.keyID, publicKey: key.publicKey.rawRepresentation,
                notBefore: now.addingTimeInterval(-3600), notAfter: now.addingTimeInterval(7200),
                minimumVersion: "2.0.0", channels: [.stable])
        ])
        return (bytes, ring)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "WeGit.UpdateControls", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
