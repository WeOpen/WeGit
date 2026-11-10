import CryptoKit
import Darwin
import Foundation
import SQLite3

@testable import WeGitCore

// The shared fixture's immutable inputs are read by the preparation task while
// the control only observes its private directory; mutations wait for that task.
extension Fixture: @unchecked Sendable {}

@main struct UpdateRetentionChecks {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var passed: [String] = []
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else { throw failure(name) }
            passed.append(name)
            FileHandle.standardError.write(Data(("Passed: " + name + "\n").utf8))
        }
        func list(_ fixture: Fixture, ring: UpdateKeyRing? = nil) async throws -> UpdateRetentionInventory {
            try await ProductionUpdateInstaller.inventory(
                target: fixture.sandbox.currentApp,
                trustedKeyRing: ring ?? fixture.ring, requiredScope: .isolatedControl)
        }
        func cleanupPlan(_ fixture: Fixture, _ entry: UpdateRetentionEntry) async throws
            -> UpdateRetentionCleanupPlan
        {
            try await ProductionUpdateInstaller.prepareCleanup(
                entry: entry, target: fixture.sandbox.currentApp,
                trustedKeyRing: fixture.ring, requiredScope: .isolatedControl)
        }
        func rejects(_ operation: () async throws -> Void) async throws -> Bool {
            do { try await operation() } catch { return true }
            return false
        }
        let fixture = try await Fixture()
        defer {
            try? fixture.sourceInput.fileHandleForWriting.close()
            fixture.source.waitUntilExit()
            try? fixture.sandbox.removeAfterInspection()
        }
        let empty = try await list(fixture, ring: UpdateKeyRing(keys: []))
        try check(
            "Empty inventory needs no configured production keys",
            empty.entries.isEmpty && !empty.capacityBlocked)
        let currentBytes = try Data(contentsOf: fixture.storeURL)
        let ticket = try await fixture.prepare()
        let directory = URL(fileURLWithPath: ticket.directory)
        let preparation = directory.appending(path: "preparation.json")
        try check(
            "Prepare durably records bounded ownership before handoff",
            FileManager.default.fileExists(atPath: preparation.path))
        let prior = try UpdateRetentionTree.read(directory, hashing: true, cancellation: IOCancellation())
        let prepared = try await list(fixture)
        try check(
            "Prepared transaction is visible but never cleaned or replayed",
            prepared.entries.count == 1 && prepared.entries[0].state == .prepared
                && !prepared.entries[0].canClean)
        try check(
            "Inventory leaves transaction bytes and identities unchanged",
            prior == (try UpdateRetentionTree.read(directory, hashing: true, cancellation: IOCancellation())))
        let untrusted = try await list(fixture, ring: UpdateKeyRing(keys: []))
        try check(
            "Missing trust preserves entry and bytes without granting cleanup",
            untrusted.entries.count == 1 && untrusted.entries[0].state == .unverified
                && !untrusted.entries[0].canClean && untrusted.entries[0].bytes == prior.bytes
                && untrusted.capacityBlocked)
        var lease: VerifiedUpdateHandoff? = try await ProductionUpdateInstaller.readAndValidateForRecovery(
            ticket: ticket, trustedKeyRing: fixture.ring)
        let busy = try await list(fixture)
        try check(
            "Active transaction lease disables cleanup",
            busy.entries[0].state == .busy && !busy.entries[0].canClean)
        lease = nil
        _ = lease
        _ = try await ProductionUpdateInstaller.abortPrepared(ticket: ticket, reason: "Private cancellation")
        let aborted = try await list(fixture)
        try check(
            "Verified explicit abort becomes cleanable while source app remains intact",
            aborted.entries[0].state == .blocked && aborted.entries[0].canClean)
        let summary = try ProductionUpdateInstaller.diagnosticSummary(aborted)
        let summaryText = String(decoding: summary, as: UTF8.self)
        try check(
            "Export contains no authorization token paths preferences or database data",
            !summaryText.contains(ticket.token) && !summaryText.contains(fixture.sandbox.root.path)
                && !summaryText.contains("v2 Current") && !summaryText.contains("before-update")
                && summaryText.contains("\"recoveryBackup\" : false"))
        let stale = try await cleanupPlan(fixture, aborted.entries[0])
        let unknown = directory.appending(path: "unknown-user-data")
        try Data("retained".utf8).write(to: unknown)
        try check(
            "Added unknown files reject confirmed cleanup without mutation",
            try await rejects {
                try await ProductionUpdateInstaller.executeCleanup(stale, trustedKeyRing: fixture.ring)
            })
        try check("Unknown file remains intact", try Data(contentsOf: unknown) == Data("retained".utf8))
        try FileManager.default.removeItem(at: unknown)
        let refresh = try await list(fixture)
        let plan = try await cleanupPlan(fixture, refresh.entries[0])
        let journalURL = directory.appending(path: "journal.json")
        var journal = try JSONDecoder().decode(UpdateInstallJournal.self, from: Data(contentsOf: journalURL))
        journal.revision += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: journalURL)
        try check(
            "Journal revision change invalidates an earlier confirmation",
            try await rejects {
                try await ProductionUpdateInstaller.executeCleanup(plan, trustedKeyRing: fixture.ring)
            })
        let final = try await list(fixture)
        let finalPlan = try await cleanupPlan(fixture, final.entries[0])
        try await ProductionUpdateInstaller.executeCleanup(finalPlan, trustedKeyRing: fixture.ring)
        try check(
            "Explicit cleanup removes the exact transaction",
            !FileManager.default.fileExists(atPath: directory.path))
        try check(
            "Cleanup leaves installed app and current database untouched",
            (try fixture.version(fixture.sandbox.currentApp)) == "2.0.0"
                && (try Data(contentsOf: fixture.storeURL)) == currentBytes)

        let orphan = fixture.sandbox.root.appending(path: ".WeGit-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: orphan, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("unknown".utf8).write(to: orphan.appending(path: "partial"))
        let orphanInventory = try await list(fixture)
        try check(
            "No-ticket legacy orphan stays visible and capacity blocked",
            orphanInventory.entries.count == 1 && orphanInventory.entries[0].state == .unverified
                && orphanInventory.entries[0].bytes == 7 && orphanInventory.capacityBlocked)
        try check(
            "Unrecognized ownership cannot be bypassed by a new preparation",
            try await rejects { _ = try await fixture.prepare() })
        try FileManager.default.removeItem(at: orphan)

        let interruptedTask = Task { try await fixture.prepare() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var found: URL?
        while ContinuousClock.now < deadline {
            let values = try FileManager.default.contentsOfDirectory(
                at: fixture.sandbox.root, includingPropertiesForKeys: nil)
            found = values.first {
                $0.lastPathComponent.hasPrefix(".WeGit-update-")
                    && FileManager.default.fileExists(atPath: $0.appending(path: "preparation.json").path)
            }
            if found != nil {
                interruptedTask.cancel()
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        var cancelled = false
        do { _ = try await interruptedTask.value } catch is CancellationError { cancelled = true }
        guard let interrupted = found else { throw failure("Missing actual preparing stage") }
        try check(
            "Real preparation cancellation retains identifiable pre-ticket state",
            cancelled
                && !FileManager.default.fileExists(atPath: interrupted.appending(path: "ticket.json").path))
        let interruptedInventory = try await list(fixture)
        try check(
            "Preparation without ticket remains counted and selectable",
            interruptedInventory.entries.count == 1 && interruptedInventory.entries[0].state == .preparing
                && interruptedInventory.entries[0].bytes != nil)
        guard interruptedInventory.entries[0].canClean else {
            throw failure("Fixture cancellation left unknown partial bytes; retain for inspection")
        }
        let interruptedPlan = try await cleanupPlan(fixture, interruptedInventory.entries[0])
        try await ProductionUpdateInstaller.executeCleanup(interruptedPlan, trustedKeyRing: fixture.ring)
        try check(
            "Known pre-ticket ownership can be explicitly cleaned",
            !FileManager.default.fileExists(atPath: interrupted.path))

        // Exercise an interrupted cleanup from a real signed and aborted transaction.
        let resumeTicket = try await fixture.prepare()
        _ = try await ProductionUpdateInstaller.abortPrepared(
            ticket: resumeTicket, reason: "Private cleanup resume")
        let resumeEntry = try await list(fixture).entries[0]
        let resumePlan = try await cleanupPlan(fixture, resumeEntry)
        let resumeDirectory = URL(fileURLWithPath: resumeTicket.directory)
        let task = Task {
            try await ProductionUpdateInstaller.executeCleanup(resumePlan, trustedKeyRing: fixture.ring)
        }
        let sidecar = fixture.sandbox.root.appending(path: ".WeGit-cleanup-" + resumeEntry.id + ".json")
        let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < cleanupDeadline && !FileManager.default.fileExists(atPath: sidecar.path) {
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        var stopped = false
        do { try await task.value } catch is CancellationError { stopped = true }
        try check(
            "Cleanup cancellation keeps durable bounded progress",
            stopped && FileManager.default.fileExists(atPath: sidecar.path))
        let originalProgressData = try Data(contentsOf: sidecar)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let originalProgress = try decoder.decode(UpdateCleanupProgress.self, from: originalProgressData)
        let unexpected = resumeDirectory.appending(path: "zz-unexpected")
        try Data("unknown user bytes".utf8).write(to: unexpected)
        let actualTree = try UpdateRetentionTree.read(
            resumeDirectory, hashing: true, cancellation: IOCancellation())
        var forgedFiles = originalProgress.tree.files
        forgedFiles["zz-unexpected"] = actualTree.files["zz-unexpected"]!
        let forgedTree = UpdateRetentionTree(
            root: originalProgress.tree.root,
            directories: originalProgress.tree.directories, files: forgedFiles,
            bytes: originalProgress.tree.bytes + actualTree.files["zz-unexpected"]!.bytes)
        var forgedProgress = UpdateCleanupProgress(
            format: originalProgress.format, entry: originalProgress.entry,
            target: originalProgress.target, scope: originalProgress.scope, parent: originalProgress.parent,
            tree: forgedTree, binding: originalProgress.binding,
            authorization: originalProgress.authorization,
            deleted: originalProgress.deleted, pending: originalProgress.pending,
            rootRemoved: originalProgress.rootRemoved)
        try forgedProgress.save()
        let forgedInventory = try await list(fixture)
        try check(
            "A valid public signature cannot authorize unknown files added to cleanup intent",
            forgedInventory.entries.count == 1 && forgedInventory.entries[0].state == .unverified
                && !forgedInventory.entries[0].canClean)
        let noKeyProgress = try await list(fixture, ring: UpdateKeyRing(keys: []))
        try check(
            "Cleanup progress never bypasses the configured trust ring",
            noKeyProgress.entries[0].state == .unverified && !noKeyProgress.entries[0].canClean)
        try FileManager.default.removeItem(at: unexpected)
        try originalProgressData.write(to: sidecar)
        let interruptedWrite = fixture.sandbox.root.appending(
            path: ".WeGit-cleanup-write-" + UUID().uuidString)
        try Data("partial sidecar".utf8).write(to: interruptedWrite)
        let tempInventory = try await list(fixture)
        try check(
            "Interrupted sidecar write remains one unknown entry without hiding valid records",
            tempInventory.entries.count == 2 && tempInventory.entries.contains(where: \.canClean)
                && tempInventory.capacityBlocked)
        try FileManager.default.removeItem(at: interruptedWrite)
        let resumedInventory = try await list(fixture)
        try check(
            "Partial cleanup remains explicitly resumable",
            resumedInventory.entries.count == 1 && resumedInventory.entries[0].canClean)
        let resumeNext = try await cleanupPlan(fixture, resumedInventory.entries[0])
        try await ProductionUpdateInstaller.executeCleanup(resumeNext, trustedKeyRing: fixture.ring)
        try check(
            "Explicit resume completes remaining files and removes parent-side intent",
            !FileManager.default.fileExists(atPath: resumeDirectory.path)
                && !FileManager.default.fileExists(atPath: sidecar.path))
        let tailTicket = try await fixture.prepare()
        _ = try await ProductionUpdateInstaller.abortPrepared(
            ticket: tailTicket, reason: "Private finalization gap")
        let tailEntry = try await list(fixture).entries[0]
        let tailPlan = try await cleanupPlan(fixture, tailEntry)
        let tailTask = Task {
            try await ProductionUpdateInstaller.executeCleanup(tailPlan, trustedKeyRing: fixture.ring)
        }
        let tailSidecar = fixture.sandbox.root.appending(path: ".WeGit-cleanup-" + tailEntry.id + ".json")
        while !FileManager.default.fileExists(atPath: tailSidecar.path) {
            try await Task.sleep(for: .milliseconds(1))
        }
        tailTask.cancel()
        do { try await tailTask.value } catch is CancellationError {}
        var tail = try decoder.decode(UpdateCleanupProgress.self, from: Data(contentsOf: tailSidecar))
        tail.deleted = Set(tail.orderedPaths)
        tail.pending = "/"
        tail.rootRemoved = false
        try tail.save()
        // Model the exact durable gap after the authorized root rmdir and before
        // acknowledging it. Only this private fixture is removed by the control.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: tailTicket.directory))
        let tailInventory = try await list(fixture)
        try check(
            "Crash after final rmdir remains visible through the parent-side intent",
            tailInventory.entries.count == 1 && tailInventory.entries[0].canClean)
        let tailNext = try await cleanupPlan(fixture, tailInventory.entries[0])
        try await ProductionUpdateInstaller.executeCleanup(tailNext, trustedKeyRing: fixture.ring)
        try check(
            "Explicit finalization removes only its completed sidecar",
            !FileManager.default.fileExists(atPath: tailSidecar.path))

        let completed = try await Fixture()
        defer { try? completed.sandbox.removeAfterInspection() }
        let completedTicket = try await completed.prepare()
        var completeVerified: VerifiedUpdateHandoff? = try await ProductionUpdateInstaller.readAndValidate(
            ticket: completedTicket, trustedKeyRing: completed.ring)
        let sourceIdentity = try UpdateProcessIdentity.capture(pid: completed.source.processIdentifier)
        let sourceMonitor = try UpdateSourceProcessMonitor(identity: sourceIdentity)
        try completed.sourceInput.fileHandleForWriting.close()
        completed.source.waitUntilExit()
        let permit = try await sourceMonitor.waitForNormalExit(timeout: 2)
        _ = try await ProductionUpdateInstaller.apply(verified: completeVerified!, permit: permit)
        let candidate = Process()
        let candidateInput = Pipe()
        candidate.executableURL = completed.sandbox.currentApp.appending(path: "Contents/MacOS/WeGit")
        candidate.standardInput = candidateInput
        candidate.standardOutput = FileHandle.nullDevice
        try candidate.run()
        defer {
            try? candidateInput.fileHandleForWriting.close()
            candidate.waitUntilExit()
        }
        let newProcess = try UpdateProcessIdentity.capture(pid: candidate.processIdentifier)
        let newMonitor = try UpdateSourceProcessMonitor(identity: newProcess)
        _ = try await ProductionUpdateInstaller.recordLaunchedProcess(
            verified: completeVerified!, monitor: newMonitor)
        let ready = try await ProductionUpdateInstaller.writeReadiness(
            ticket: completedTicket, process: newProcess,
            migrationCompleted: true, windowsRestored: true, preferencesFlushed: true, isolated: true)
        _ = try await ProductionUpdateInstaller.confirmLaunch(verified: completeVerified!, readiness: ready)
        completeVerified = nil
        let completedInventory = try await list(completed)
        try check(
            "Actual installed and ready transaction is a cleanable completed record",
            completedInventory.entries.count == 1 && completedInventory.entries[0].state == .completed
                && completedInventory.entries[0].canClean)
        let completedPlan = try await cleanupPlan(completed, completedInventory.entries[0])
        try await ProductionUpdateInstaller.executeCleanup(completedPlan, trustedKeyRing: completed.ring)
        try check(
            "Completed cleanup preserves the running installed application",
            candidate.isRunning
                && (try completed.version(completed.sandbox.currentApp)) == "2.0.1"
                && !FileManager.default.fileExists(atPath: completedTicket.directory))

        let result: [String: Any] = [
            "total": passed.count, "passed": passed, "failed": 0,
            "xctestExecuted": false, "actualProductionInstall": false,
            "scope":
                "Private signed mock apps, real persistent preparation, SQLite and interrupted cleanup; no user installation",
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(
            to: output)
        print("\(passed.count) update retention controls passed")
    }
    private static func failure(_ name: String) -> NSError {
        NSError(domain: "WeGit.UpdateRetentionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
    }
}
