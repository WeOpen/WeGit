import CryptoKit
import Darwin
import Foundation
import SQLite3

@testable import WeGitCore

/// Private non-XCTest controls. The mock helper injects a temporary PUBLIC ring;
/// this entry point is never part of the production WeGitUpdater target.
@main struct ProductionUpdateChecks {
    static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--private-helper" {
            let token =
                String(data: try FileHandle.standardInput.read(upToCount: 64) ?? Data(), encoding: .utf8)
                ?? ""
            let ticket = try ProductionUpdateInstaller.loadTicket(
                at: URL(fileURLWithPath: arguments[2]), token: token)
            let ringURL = URL(fileURLWithPath: ticket.directory).deletingLastPathComponent().appending(
                path: "temporary-public-ring.json")
            let ring = try UpdateKeyRing.load(from: ringURL)
            let verified = try await ProductionUpdateInstaller.readAndValidate(
                ticket: ticket, trustedKeyRing: ring)
            let monitor = try UpdateSourceProcessMonitor(identity: verified.request.originalProcess)
            _ = try await ProductionUpdateInstaller.writeHelperReady(verified: verified, monitor: monitor)
            let permit = try await monitor.waitForNormalExit(timeout: 10)
            _ = try await ProductionUpdateInstaller.apply(verified: verified, permit: permit)
            return
        }
        guard arguments.count == 2 else { throw fail("Expected a private output JSON path") }
        var passed: [String] = []
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else { throw fail(name) }
            passed.append(name)
            FileHandle.standardError.write(Data(("Passed: " + name + "\n").utf8))
        }

        let fixture = try await Fixture()
        let ticket = try await fixture.prepare()
        try check(
            "Ticket/private data ownership is durable before quit",
            FileManager.default.fileExists(atPath: ticket.ticketURL.path))
        let loaded = try ProductionUpdateInstaller.loadTicket(at: ticket.ticketURL, token: ticket.token)
        try check("Private ticket round-trips exact authorization and document SHA", loaded == ticket)
        do {
            _ = try await ProductionUpdateInstaller.recover(
                ticket: ticket, trustedKeyRing: fixture.ring, requiredScope: .production)
            throw fail("Isolated ticket accepted by production recovery")
        } catch is UpdateFailure {
            passed.append("Production required-scope rejects private ticket before recovery mutation")
        }
        do {
            _ = try ProductionUpdateInstaller.loadTicket(
                at: ticket.ticketURL, token: String(repeating: "0", count: 64))
            throw fail("Wrong token accepted")
        } catch is UpdateFailure { passed.append("Wrong inherited-pipe token is rejected") }
        let permissions =
            try FileManager.default.attributesOfItem(atPath: ticket.ticketURL.path)[.posixPermissions]
            as! NSNumber
        try check("Ticket is user-only 0600", permissions.intValue == 0o600)
        do {
            _ = try await ProductionUpdateInstaller.readAndValidate(
                ticket: ticket, trustedKeyRing: UpdateKeyRing(keys: []))
            throw fail("Empty trust root accepted")
        } catch is UpdateFailure { passed.append("Missing production trust fails before install") }
        try FileManager.default.removeItem(at: fixture.sandbox.replacementApp)
        fixture.download = nil
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: ticket.directory).appending(
            path: "Installer/Helpers/WeGitUpdater")
        helper.arguments = ["--private-helper", ticket.ticketURL.path]
        let input = Pipe()
        helper.standardInput = input
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.standardError
        try helper.run()
        try input.fileHandleForWriting.write(contentsOf: Data(ticket.token.utf8))
        try input.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var ready: UpdateHelperReadiness?
        while ProcessInfo.processInfo.systemUptime < deadline && ready == nil {
            ready = try await ProductionUpdateInstaller.readHelperReady(ticket: ticket)
            if ready == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        try check("Durable helper validates copied data after original input cleanup", ready != nil)
        try check(
            "Helper readiness binds its actual independent executable",
            ready?.helper.executable == helper.executableURL?.path)
        try check(
            "Old app remains unchanged while original process runs",
            try fixture.version(fixture.sandbox.currentApp) == "2.0.0")
        try fixture.sourceInput.fileHandleForWriting.close()
        fixture.source.waitUntilExit()
        helper.waitUntilExit()
        try check(
            "Original normal exit permits real helper atomic replacement",
            helper.terminationStatus == 0 && (try fixture.version(fixture.sandbox.currentApp)) == "2.0.1")
        var verified: VerifiedUpdateHandoff? = try await ProductionUpdateInstaller.readAndValidate(
            ticket: ticket, trustedKeyRing: fixture.ring)
        do {
            _ = try await ProductionUpdateInstaller.readAndValidate(
                ticket: ticket, trustedKeyRing: fixture.ring)
            throw fail("Parallel lease accepted")
        } catch is UpdateFailure { passed.append("Concurrent installer lease is rejected") }
        verified = nil
        let decision = try await ProductionUpdateInstaller.recover(
            ticket: ticket, trustedKeyRing: fixture.ring)
        guard case .awaitingLaunch = decision else {
            throw fail("Reopened journal did not recover installed layout")
        }
        passed.append("Fresh installer reconstructs awaiting-launch from persistent layout")
        verified = try await ProductionUpdateInstaller.readAndValidate(
            ticket: ticket, trustedKeyRing: fixture.ring)
        let candidate = Process()
        let candidateInput = Pipe()
        candidate.executableURL = fixture.sandbox.currentApp.appending(path: "Contents/MacOS/WeGit")
        candidate.standardInput = candidateInput
        candidate.standardOutput = FileHandle.nullDevice
        try candidate.run()
        let candidateIdentity = try UpdateProcessIdentity.capture(pid: candidate.processIdentifier)
        let candidateMonitor = try UpdateSourceProcessMonitor(identity: candidateIdentity)
        _ = try await ProductionUpdateInstaller.recordLaunchedProcess(
            verified: verified!, monitor: candidateMonitor)
        let readiness = try await ProductionUpdateInstaller.writeReadiness(
            ticket: ticket, process: candidateIdentity,
            migrationCompleted: true, windowsRestored: true, preferencesFlushed: true, isolated: true)
        let readReady = try await ProductionUpdateInstaller.readReadiness(verified: verified!)
        try check(
            "Ready receipt binds actual new PID/start/version/variant",
            readReady?.process == candidateIdentity)
        let confirmed = try await ProductionUpdateInstaller.confirmLaunch(
            verified: verified!, readiness: readiness)
        try check(
            "Process launch alone becomes success only after migration/window ready",
            confirmed.phase == .launchVerified)
        do {
            _ = try await ProductionUpdateInstaller.rollback(verified: verified!)
            throw fail("Live candidate rollback accepted")
        } catch is UpdateFailure { passed.append("Still-running candidate is never replaced or killed") }
        try fixture.mutateStore()
        try candidateInput.fileHandleForWriting.close()
        candidate.waitUntilExit()
        let candidateExit = try await candidateMonitor.waitForExit(timeout: 2)
        let rolled = try await ProductionUpdateInstaller.rollback(
            verified: verified!, observedExit: candidateExit)
        try check(
            "Explicit failed-launch rollback restores exact old version",
            try fixture.version(rolled.currentApp) == "2.0.0")
        try check(
            "Rollback selects current-v2 preferences rather than original-v1",
            rolled.preferencesRestoration?.bytes == fixture.currentPreferences)
        try check(
            "Rejected new package and source backups stay retained",
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: ticket.directory).appending(path: "FailedReplacement.app").path))
        _ = try await ProductionUpdateInstaller.confirmPreferencesRestored(
            verified: verified!, restoredSHA256: rolled.preferencesRestoration!.sha256)
        let afterPrefs = try await ProductionUpdateInstaller.readReceiptSnapshot(verified: verified!)
        try check(
            "Preferences confirmation cannot clear pending DB restoration",
            afterPrefs.preferencesRestoration == nil && afterPrefs.storeRestoration != nil)
        let store = try requireStore(afterPrefs.storeRestoration)
        let configuration = ApplicationDataMigration.Configuration(
            legacyDomains: [fixture.domain + ".legacy"], currentDomain: fixture.domain,
            legacyStoreURL: nil, stateDirectory: fixture.storeURL.deletingLastPathComponent())
        FileHandle.standardError.write(
            Data(
                ("Restore paths: " + store.sourceStoreURL.path + " vs "
                    + configuration.stateDirectory.appending(path: "Repositories.store").path + "\n").utf8))
        let identityNow = try MigrationDirectoryIdentity.read(configuration.stateDirectory)
        let alive = kill(candidateIdentity.pid, 0)
        let aliveError = errno
        FileHandle.standardError.write(
            Data(
                ("Restore identity: " + String(describing: identityNow == store.directoryIdentity) + " pid "
                    + String(alive) + "/" + String(aliveError) + " hash "
                    + String(UpdateManifestValidator.digest(store.data) == store.sha256) + "\n").utf8))
        let storeResult = try ApplicationDataMigration.restoreCurrentStoreBackup(
            store, configuration: configuration,
            stoppedWriterPID: candidateIdentity.pid)
        _ = try await ProductionUpdateInstaller.confirmStoreRestored(
            verified: verified!, restoredSHA256: storeResult.restoredSHA256)
        try check(
            "Current-v2 SQLite snapshot restores recents/favorites bytes",
            try Data(contentsOf: fixture.storeURL) == fixture.storeBackup.data)
        let recordedExit = try await ProductionUpdateInstaller.recordedRollbackExit(verified: verified!)
        try check(
            "Rollback retains actual new-process exit evidence", recordedExit?.source == candidateIdentity)
        verified = nil
        let restored = try await ProductionUpdateInstaller.recover(
            ticket: ticket, trustedKeyRing: fixture.ring)
        guard case .rolledBack(let receipt) = restored else {
            throw fail("Rollback journal not reconstructed")
        }
        try check(
            "Restored-data receipt remains durable across re-open",
            receipt.preferencesRestoration == nil && receipt.storeRestoration == nil)

        let abortedFixture = try await Fixture()
        let abortedTicket = try await abortedFixture.prepare()
        let abort = try await ProductionUpdateInstaller.abortPrepared(
            ticket: abortedTicket, reason: "Private helper did not become ready")
        try check(
            "Prepared timeout abort retains original app and allows continuation",
            abort.phase == .blocked && (try abortedFixture.version(abort.currentApp)) == "2.0.0")
        try check(
            "Abort signal is bounded and bound to the same ticket",
            try await ProductionUpdateInstaller.readHelperAbort(ticket: abortedTicket)?.id == abortedTicket.id
        )
        do {
            try await ProductionUpdateInstaller.writeSourceAbort(
                ticket: abortedTicket, reason: "foreign caller")
            throw fail("Non-source abort accepted")
        } catch is UpdateFailure {
            passed.append("Same-user non-source process cannot authorize source abort")
        }
        try abortedFixture.sourceInput.fileHandleForWriting.close()
        abortedFixture.source.waitUntilExit()
        let gapFixture = try await Fixture()
        let gapTicket = try await gapFixture.prepare()
        var gapVerified: VerifiedUpdateHandoff? = try await ProductionUpdateInstaller.readAndValidate(
            ticket: gapTicket, trustedKeyRing: gapFixture.ring)
        let gapMonitor = try UpdateSourceProcessMonitor(identity: gapVerified!.request.source)
        try gapFixture.sourceInput.fileHandleForWriting.close()
        gapFixture.source.waitUntilExit()
        let gapPermit = try await gapMonitor.waitForNormalExit(timeout: 2)
        var gapJournal = try await ProductionUpdateInstaller.readJournalSnapshot(verified: gapVerified!)
        gapJournal.sourceExitObservedAt = gapPermit.observedAt
        gapJournal.sourceExitStatus = gapPermit.exitStatus
        gapJournal.phase = .swapIntent
        gapJournal.revision += 1
        let journalEncoder = JSONEncoder()
        journalEncoder.dateEncodingStrategy = .iso8601
        try journalEncoder.encode(gapJournal).write(to: gapVerified!.request.journal, options: .atomic)
        // Fault injection only in this process-owned mock: crash after kernel swap
        // and before the helper can move the known old stage into Previous.app.
        guard
            renameatx_np(
                AT_FDCWD, gapVerified!.request.target.path, AT_FDCWD, gapVerified!.request.stage.path,
                UInt32(RENAME_SWAP)) == 0
        else { throw fail("Private swap injection") }
        gapVerified = nil
        let gapDecision = try await ProductionUpdateInstaller.recover(
            ticket: gapTicket, trustedKeyRing: gapFixture.ring)
        guard case .awaitingLaunch(let gapReceipt) = gapDecision else {
            throw fail("Swap crash gap was not reconstructed")
        }
        try check(
            "Crash gap recovery detects actual target-new/stage-old exchange",
            try gapFixture.version(gapReceipt.previousApp) == "2.0.0")
        gapVerified = try await ProductionUpdateInstaller.readAndValidateForRecovery(
            ticket: gapTicket, trustedKeyRing: gapFixture.ring)
        _ = try await ProductionUpdateInstaller.rollback(verified: gapVerified!)
        gapVerified = nil
        let unknownFixture = try await Fixture()
        let unknown = unknownFixture.sandbox.root.appending(path: ".WeGit-update-unknown")
        try FileManager.default.createDirectory(
            at: unknown, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var unknownRejected = false
        do { _ = try await unknownFixture.prepare() } catch { unknownRejected = true }
        try check("Unknown retained directory blocks new prepare and is preserved", unknownRejected)
        try check(
            "Unknown retained directory is not cleaned automatically",
            FileManager.default.fileExists(atPath: unknown.path))
        try unknownFixture.sourceInput.fileHandleForWriting.close()
        unknownFixture.source.waitUntilExit()
        let cancelledFixture = try await Fixture()
        let cancelledTicket = try await cancelledFixture.prepare()
        var cancelled: VerifiedUpdateHandoff? = try await ProductionUpdateInstaller.readAndValidate(
            ticket: cancelledTicket, trustedKeyRing: cancelledFixture.ring)
        let cancelMonitor = try UpdateSourceProcessMonitor(identity: cancelled!.request.source)
        // Isolated fault input models a legitimate source-abort file, then a later
        // ordinary Quit. The normal-exit permit must not override that intent.
        let sourceAbort = UpdateSourceAbort(
            id: cancelledTicket.id, documentSHA256: cancelledTicket.documentSHA256,
            authorizationSHA256: cancelled!.request.authorizationSHA256, source: cancelled!.request.source,
            reason: "private cancelled install")
        try JSONEncoder().encode(sourceAbort).write(
            to: cancelled!.request.directory.appending(path: "source-abort.json"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: cancelled!.request.directory.appending(path: "source-abort.json").path)
        try cancelledFixture.sourceInput.fileHandleForWriting.close()
        cancelledFixture.source.waitUntilExit()
        let cancelledExit = try await cancelMonitor.waitForNormalExit(timeout: 2)
        do {
            _ = try await ProductionUpdateInstaller.apply(verified: cancelled!, permit: cancelledExit)
            throw fail("Source abort ignored after normal Quit")
        } catch is UpdateFailure { passed.append("Source abort intent wins over later normal-exit permit") }
        _ = try await ProductionUpdateInstaller.abortPrepared(
            verified: cancelled!, reason: sourceAbort.reason)
        cancelled = nil
        let crashFixture = try await Fixture()
        let crashIdentity = try UpdateProcessIdentity.capture(pid: crashFixture.source.processIdentifier)
        let crashMonitor = try UpdateSourceProcessMonitor(identity: crashIdentity)
        crashFixture.source.terminate()
        crashFixture.source.waitUntilExit()
        do {
            _ = try await crashMonitor.waitForNormalExit(timeout: 2)
            throw fail("SIGTERM counted as normal exit")
        } catch is UpdateFailure {
            passed.append("Kernel-observed signal exit cannot authorize original app replacement")
        }

        let result: [String: Any] = [
            "passed": passed, "total": passed.count, "failed": 0,
            "scope":
                "Private non-XCTest copied/ad-hoc mock apps and temporary public-key ring; no real app, preferences or DB changed",
            "productionKeysGenerated": false, "actualProductionInstall": false, "xctestExecuted": false,
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(
            to: URL(fileURLWithPath: arguments[1]), options: .atomic)
        try fixture.sandbox.removeAfterInspection()
        try abortedFixture.sandbox.removeAfterInspection()
        try crashFixture.sandbox.removeAfterInspection()
        try gapFixture.sandbox.removeAfterInspection()
        try unknownFixture.sandbox.removeAfterInspection()
        try cancelledFixture.sandbox.removeAfterInspection()
        print("\(passed.count) persistent update controls passed")
    }

    private static func fail(_ message: String) -> NSError {
        NSError(
            domain: "WeGit.ProductionUpdateControls", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func requireStore(_ store: ApplicationStoreBackup?) throws -> ApplicationStoreBackup {
        guard let store else { throw fail("Missing current-v2 store restoration") }
        return store
    }
}

private final class Fixture {
    let sandbox = try! UpdateInstallationSandbox()
    let source = Process()
    let sourceInput = Pipe()
    let originalPreferences: Data
    let currentPreferences: Data
    let package: Data
    let storeURL: URL
    let storeBackup: ApplicationStoreBackup
    let ring: UpdateKeyRing
    let update: TrustedUpdate
    var download: UpdateDownload?
    let domain = "com.willxue.wegit.UITests.ProductionUpdate." + UUID().uuidString

    init() async throws {
        let storeDirectory = sandbox.root.appending(path: "private-v2-store")
        try FileManager.default.createDirectory(
            at: storeDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        storeURL = storeDirectory.appending(path: "Repositories.store")
        try Self.sqlite(
            storeURL,
            sql:
                "CREATE TABLE recents(path TEXT); INSERT INTO recents VALUES('before-update'); CREATE TABLE favorites(path TEXT); INSERT INTO favorites VALUES('saved');"
        )
        let storeData = try Data(contentsOf: storeURL)
        var storeInfo = stat()
        guard lstat(storeDirectory.path, &storeInfo) == 0 else { throw UpdateFailure.changed }
        guard let storeIdentity = try MigrationDirectoryIdentity.read(storeDirectory) else {
            throw UpdateFailure.changed
        }
        storeBackup = ApplicationStoreBackup(
            sourceStoreURL: storeURL, data: storeData, sha256: Self.hash(storeData),
            directoryIdentity: storeIdentity)
        originalPreferences = try PropertyListSerialization.data(
            fromPropertyList: ["format": 1, "values": ["legacy": "v1 中文"]], format: .binary, options: 0)
        currentPreferences = try PropertyListSerialization.data(
            fromPropertyList: ["format": 1, "values": ["draft": "v2 Current 😀"]], format: .binary, options: 0)
        try Self.makeApp(sandbox.currentApp, version: "2.0.0", build: "1")
        try Self.makeApp(sandbox.replacementApp, version: "2.0.1", build: "2")
        package = try Self.package(sandbox.replacementApp)
        let key = Curve25519.Signing.PrivateKey()
        let now = Date()
        let formatter = ISO8601DateFormatter()
        ring = UpdateKeyRing(keys: [
            UpdatePublicKey(
                id: "private-control-public-key", publicKey: key.publicKey.rawRepresentation,
                notBefore: now.addingTimeInterval(-3600), notAfter: now.addingTimeInterval(7200),
                minimumVersion: "2.0.0", channels: [.stable])
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ring).write(to: sandbox.root.appending(path: "temporary-public-ring.json"))
        let installedBytes = try Self.size(sandbox.replacementApp)
        let packageDigest = Self.hash(package)
        let artifacts = UpdateVariant.allCases.map { variant in
            let base =
                "https://github.com/WeOpen/WeGit/releases/download/v2.0.1/WeGit-2.0.1-macos-\(variant.rawValue)-adhoc"
            return UpdateArtifact(
                variant: variant, url: base + ".dmg", sha256: Self.hash(MockProtocol.body),
                downloadBytes: Int64(MockProtocol.body.count),
                installedBytes: installedBytes, manifestURL: base + ".manifest.json",
                manifestSHA256: packageDigest)
        }
        let manifest = UpdateManifest(
            version: "2.0.1", channel: .stable, build: 2, sourceCommit: String(repeating: "a", count: 40),
            publishedAt: formatter.string(from: now.addingTimeInterval(-60)),
            expiresAt: formatter.string(from: now.addingTimeInterval(3600)),
            keyID: "private-control-public-key", releaseNotes: "Private persistent installer fixture",
            artifacts: artifacts)
        let payload = try UpdateManifestValidator.canonicalJSON(manifest)
        let signed = try UpdateManifestValidator.canonicalJSON(
            SignedUpdateManifest(payload: payload, signature: key.signature(for: payload)))
        guard
            case .available(let valid) = try UpdateManifestValidator.validate(
                signed, ring: ring, channel: .stable,
                installed: InstalledUpdateVersion(version: "2.0.0", build: 1, variant: .universal))
        else { throw UpdateFailure.invalidManifest }
        update = valid
        download = try await UpdateHTTPClient(testingProtocol: MockProtocol.self).download(update)
        source.executableURL = sandbox.currentApp.appending(path: "Contents/MacOS/WeGit")
        source.standardInput = sourceInput
        source.standardOutput = FileHandle.nullDevice
        source.standardError = FileHandle.nullDevice
        try source.run()
    }
    func prepare() async throws -> UpdateHandoffTicket {
        let backup = try UpdateDataBackup(
            originalPreferences: originalPreferences, currentPreferences: currentPreferences,
            currentStoreBackup: storeBackup)
        let plan = try await UpdateInstaller.preflight(
            currentApp: sandbox.currentApp, replacementApp: sandbox.replacementApp,
            update: update, packageManifest: package, dataBackup: backup,
            activity: UpdateInstallationActivity(
                busyTasks: 0, windowIDs: [], persistedWindowIDs: [], persistenceFlushed: true, generation: 1))
        return try await ProductionUpdateInstaller.prepare(
            plan: plan, download: download!, preferencesDomain: domain,
            scope: .isolatedControl,
            originalProcess: UpdateProcessIdentity.capture(pid: source.processIdentifier))
    }
    func mutateStore() throws {
        try Self.sqlite(storeURL, sql: "INSERT INTO recents VALUES('candidate-version-change');")
    }
    private static func sqlite(_ url: URL, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw UpdateFailure.changed
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw UpdateFailure.changed }
    }
    func version(_ app: URL) throws -> String {
        let info =
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: app.appending(path: "Contents/Info.plist")), format: nil)
            as! [String: Any]
        return info["CFBundleShortVersionString"] as! String
    }
    private static func makeApp(_ app: URL, version: String, build: String) throws {
        for name in ["Contents/MacOS", "Contents/Helpers", "Contents/Resources"] {
            try FileManager.default.createDirectory(
                at: app.appending(path: name), withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/cat"), to: app.appending(path: "Contents/MacOS/WeGit"))
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/cat"), to: app.appending(path: "Contents/Helpers/WeGitAskPass"))
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: CommandLine.arguments[0]),
            to: app.appending(path: "Contents/Helpers/WeGitUpdater"))
        let resource = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(
            path: "WeGit_WeGitCore.bundle")
        try FileManager.default.copyItem(
            at: resource, to: app.appending(path: "Contents/Resources/WeGit_WeGitCore.bundle"))
        let info = [
            "CFBundleIdentifier": "com.willxue.wegit", "CFBundleExecutable": "WeGit",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "WeGitReleaseVersion": version, "CFBundleVersion": build,
            "WeGitDistributionVariant": "universal", "LSMinimumSystemVersion": "26.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
            to: app.appending(path: "Contents/Info.plist"))
        try JSONSerialization.data(withJSONObject: ["architectures": ["arm64", "x86_64"]]).write(
            to: app.appending(path: "Contents/Resources/build-source.json"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--deep", "--sign", "-", "--timestamp=none", app.path]
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw UpdateFailure.signature }
    }
    private static func package(_ app: URL) throws -> Data {
        var binaries: [String: Any] = [:]
        for path in [
            "Contents/MacOS/WeGit", "Contents/Helpers/WeGitAskPass", "Contents/Helpers/WeGitUpdater",
        ] {
            binaries[path] = [
                "sha256": hash(try Data(contentsOf: app.appending(path: path))),
                "architectures": ["arm64", "x86_64"],
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "gitCommit": String(repeating: "a", count: 40), "releaseTag": "v2.0.1",
                "version": "2.0.1", "buildVersion": "2", "bundleIdentifier": "com.willxue.wegit",
                "workspaceDirty": false,
                "mode": "adhoc", "signing": "ad-hoc", "notarized": false, "minimumSystemVersion": "26.0",
                "buildReceiptSHA256": hash(
                    try Data(contentsOf: app.appending(path: "Contents/Resources/build-source.json"))),
                "architectures": ["arm64", "x86_64"], "archiveSHA256": hash(MockProtocol.body),
                "imageBytes": MockProtocol.body.count, "bundleBytes": size(app), "binaries": binaries,
            ], options: [.sortedKeys])
    }
    private static func size(_ app: URL) throws -> Int64 {
        var total: Int64 = 0
        for case let file as URL in FileManager.default.enumerator(
            at: app, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])!
        {
            let value = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if value.isRegularFile == true { total += Int64(value.fileSize ?? 0) }
        }
        return total
    }
    private static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data(repeating: 80, count: 1024)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "1024"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
