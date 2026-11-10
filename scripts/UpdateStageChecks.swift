import SQLite3

private enum StageCheckFailure: Error { case failed(String) }

@main struct UpdateStageChecks {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = output.deletingLastPathComponent().appending(path: "fixtures")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let domain = "com.willxue.wegit.UITests.UpdateStage." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            defaults.removePersistentDomain(forName: domain + ".v2")
        }
        let migration = try ApplicationDataMigration(
            defaults: defaults,
            configuration: .init(
                legacyDomains: [domain], currentDomain: domain + ".v2", legacyStoreURL: nil,
                stateDirectory: root.appending(path: "data")))
        var passed: [String] = []
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw StageCheckFailure.failed(name) }
            passed.append(name)
        }
        func stage(_ name: String) throws -> TransientUpdateStage {
            let parent = root.appending(path: name)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            return try TransientUpdateStage(target: parent.appending(path: "WeGit.app"))
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func seal(_ stage: TransientUpdateStage) async throws {
            try await stage.captureCleanupCandidate()
            try stage.authorizeCleanup()
        }
        func reject(_ operation: () async throws -> Void) async throws -> Bool {
            do { try await operation() } catch is UpdateFailure { return true }
            return false
        }
        let empty = try stage("empty")
        let absent = try await empty.captureStoreBackup(using: migration)
        try await seal(empty)
        try await empty.authorizeStoreCleanup(afterTransferring: absent)
        try await empty.finishAndRemove()
        try require(absent == nil && !exists(empty.root), "Absent database leaves no stage")

        var database: OpaquePointer?
        guard sqlite3_open(migration.currentStoreURL.path, &database) == SQLITE_OK, let database else {
            throw StageCheckFailure.failed("Private SQLite open")
        }
        guard
            sqlite3_exec(
                database, "CREATE TABLE example(value TEXT); INSERT INTO example VALUES('kept');", nil, nil,
                nil) == SQLITE_OK,
            sqlite3_close(database) == SQLITE_OK
        else { throw StageCheckFailure.failed("Private SQLite creation") }
        let sourceBytes = try Data(contentsOf: migration.currentStoreURL)

        let owned = try stage("owned")
        let backup = try await owned.captureStoreBackup(using: migration)!
        try await seal(owned)
        let durable = root.appending(path: "copied-backup.plist")
        let encoded = try PropertyListEncoder().encode(backup)
        try encoded.write(to: durable)
        let file = try FileHandle(forWritingTo: durable)
        try file.synchronize()
        try file.close()
        try await owned.authorizeStoreCleanup(afterTransferring: backup)
        try await owned.finishAndRemove()
        try require(
            !exists(owned.root) && (try Data(contentsOf: durable)) == encoded,
            "Authorized cleanup removes only the stage and retains transferred backup")

        let untransferred = try stage("untransferred")
        _ = try await untransferred.captureStoreBackup(using: migration)
        try await seal(untransferred)
        try await untransferred.finishAndRemove()
        try require(
            exists(untransferred.storeSnapshotDirectory), "Preflight alone preserves database capture")

        let changed = try stage("changed")
        let changedBackup = try await changed.captureStoreBackup(using: migration)!
        try await seal(changed)
        try Data("changed".utf8).write(
            to: changed.storeSnapshotDirectory.appending(path: "Repositories.store"))
        try require(
            await reject { try await changed.authorizeStoreCleanup(afterTransferring: changedBackup) },
            "Changed normalized bytes reject transfer authorization")
        try await changed.finishAndRemove()
        try require(exists(changed.storeSnapshotDirectory), "Failed authorization retains changed capture")

        let replaced = try stage("replaced")
        let replacedBackup = try await replaced.captureStoreBackup(using: migration)!
        try await seal(replaced)
        let normalized = replaced.storeSnapshotDirectory.appending(path: "Repositories.store")
        try FileManager.default.removeItem(at: normalized)
        try replacedBackup.data.write(to: normalized)
        try require(
            await reject { try await replaced.authorizeStoreCleanup(afterTransferring: replacedBackup) },
            "Identical bytes with a replaced inode remain unowned")

        let rawChanged = try stage("raw-changed")
        let rawBackup = try await rawChanged.captureStoreBackup(using: migration)!
        try await seal(rawChanged)
        try await rawChanged.authorizeStoreCleanup(afterTransferring: rawBackup)
        try Data("changed raw".utf8).write(
            to: rawChanged.storeSnapshotDirectory.appending(path: "raw-current/Repositories.store"))
        try require(
            await reject { try await rawChanged.finishAndRemove() },
            "Raw capture changed after authorization is retained")

        let injected = try stage("injected")
        let injectedBackup = try await injected.captureStoreBackup(using: migration)!
        try await seal(injected)
        try await injected.authorizeStoreCleanup(afterTransferring: injectedBackup)
        let unknown = injected.storeSnapshotDirectory.appending(path: "unknown")
        try Data("not owned".utf8).write(to: unknown)
        try require(
            await reject { try await injected.finishAndRemove() },
            "Unknown file injection prevents snapshot cleanup")
        try require(exists(unknown), "Unknown file remains byte intact")

        let redirected = try stage("redirected")
        let redirectedBackup = try await redirected.captureStoreBackup(using: migration)!
        try await seal(redirected)
        try await redirected.authorizeStoreCleanup(afterTransferring: redirectedBackup)
        let moved = root.appending(path: "moved-owned-capture")
        try FileManager.default.moveItem(at: redirected.storeSnapshotDirectory, to: moved)
        try FileManager.default.createSymbolicLink(
            at: redirected.storeSnapshotDirectory, withDestinationURL: moved)
        try require(
            await reject { try await redirected.finishAndRemove() },
            "Replaced snapshot directory is never followed")
        try require(
            exists(moved.appending(path: "Repositories.store")), "Redirect target retains captured database")

        let preexisting = try stage("preexisting")
        try FileManager.default.createDirectory(
            at: preexisting.storeSnapshotDirectory, withIntermediateDirectories: false)
        try require(
            await reject { _ = try await preexisting.captureStoreBackup(using: migration) },
            "Preexisting snapshot namespace cannot acquire ownership")

        let cancelled = try stage("cancelled")
        let cancelledBackup = try await cancelled.captureStoreBackup(using: migration)
        try await seal(cancelled)
        let authorization = Task { @MainActor in
            try await cancelled.authorizeStoreCleanup(afterTransferring: cancelledBackup)
        }
        authorization.cancel()
        var observedCancellation = false
        do { try await authorization.value } catch is CancellationError { observedCancellation = true }
        try await cancelled.finishAndRemove()
        try require(
            observedCancellation && exists(cancelled.storeSnapshotDirectory),
            "Cancelled worker never grants snapshot cleanup ownership")

        let repeated = root.appending(path: "repeated")
        try FileManager.default.createDirectory(at: repeated, withIntermediateDirectories: false)
        for _ in 0..<12 {
            let next = try TransientUpdateStage(target: repeated.appending(path: "WeGit.app"))
            let copy = try await next.captureStoreBackup(using: migration)
            try await seal(next)
            try await next.authorizeStoreCleanup(afterTransferring: copy)
            try await next.finishAndRemove()
        }
        try require(
            try FileManager.default.contentsOfDirectory(atPath: repeated.path).isEmpty,
            "Twelve successful transfers do not exhaust the ten-stage bound")
        try require(
            try Data(contentsOf: migration.currentStoreURL) == sourceBytes,
            "Original current database remains byte identical")
        let report: [String: Any] = [
            "format": 1, "total": passed.count, "passed": passed, "failed": 0,
            "xctestExecuted": false, "actualProductionInstall": false,
            "scope":
                "Real private SQLite capture; transfer authorization boundary control; no installer launch",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output)
        print("\(passed.count)/\(passed.count) private update-stage controls passed")
    }
}
