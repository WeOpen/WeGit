import Foundation
import WeGitCore

private struct FailConfigEdit: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("--file"),
            request.arguments.contains(where: { $0.hasSuffix(".pushurl") })
        {
            throw ProcessFailure.timedOut
        }
        return try await ProcessRunner().run(request)
    }
}

@main struct RemoteManagementChecks {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(
                Data(("Remote management check failed: " + error.localizedDescription + "\n").utf8))
            if let error = error as? GitFailure {
                FileHandle.standardError.write(Data((error.details + "\n").utf8))
            }
            exit(1)
        }
    }
    static func run() async throws {
        var checks: [String] = []
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else {
                throw NSError(
                    domain: "WeGit.RemoteChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
            }
            checks.append(name)
        }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitRemoteChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let global = root.appending(path: "global")
        let globalBytes = Data(
            "[remote \"inherited\"]\n url = https://example.invalid/inherited.git\n fetch = +refs/heads/*:refs/remotes/inherited/*\n"
                .utf8)
        try globalBytes.write(to: global)
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_GLOBAL"] = global.path
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let engine = GitEngine(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: env)
        @discardableResult func git(_ args: [String], in directory: URL? = nil) async throws -> Data {
            try await engine.run(args, in: directory ?? work).stdout
        }
        try await git(["init", "-b", "main"])
        try await git(["config", "user.name", "Remote Fixture"])
        try await git(["config", "user.email", "remote@example.invalid"])
        try await git(["config", "commit.gpgsign", "false"])
        try await git(["config", "core.hooksPath", root.appending(path: "no-hooks").path])
        try Data("base\n".utf8).write(to: work.appending(path: "file"))
        try await git(["add", "."])
        try await git(["commit", "-m", "Base"])
        let location = try await RepositoryService.discover(work, engine: engine)
        let service = RepositoryService(location: location, engine: engine)
        let head = try await service.head()
        let a = root.appending(path: "a.git")
        let b = root.appending(path: "b.git")
        try await git(["init", "--bare", a.path])
        try await git(["init", "--bare", b.path])
        var snapshot = try await service.remoteManagement()
        try check(
            "Inherited remote and source are visible",
            snapshot.remotes.first?.values.contains { $0.scope == "global" } == true)
        try check("Inherited remote is read only", snapshot.remotes.first?.canEdit == false)
        try await service.changeRemote(
            .add(name: "origin", fetchURL: a.path, pushURL: nil), in: snapshot, expectedHead: head)
        snapshot = try await service.remoteManagement()
        let origin = snapshot.remotes.first { $0.name == "origin" }!
        try check(
            "New remote is editable and repository local",
            origin.canEdit && origin.values.allSatisfy { $0.scope == "local" })
        try check(
            "New remote has a standard fetch refspec",
            origin.values.contains {
                $0.key == "remote.origin.fetch" && $0.value == "+refs/heads/*:refs/remotes/origin/*"
            })
        let oldPlan = try await service.preparePush(remote: "origin", branch: "main", expectedHead: head)
        try await service.changeRemote(
            .update(name: "origin", fetchURL: b.path, pushURL: nil), in: snapshot, expectedHead: head)
        var stalePlanRejected = false
        do { _ = try await service.push(oldPlan) } catch ModelFailure.changed { stalePlanRejected = true }
        try check("Address edits invalidate a previously confirmed push", stalePlanRejected)
        try check(
            "Rejected old plan leaves old remote empty",
            try await git(["ls-remote", a.path, "refs/heads/main"]).isEmpty)
        let newPlan = try await service.preparePush(
            remote: "origin", branch: "main", setUpstream: true, expectedHead: head)
        _ = try await service.push(newPlan)
        try check(
            "Newly confirmed push reaches the edited bare remote",
            String(decoding: try await git(["rev-parse", "refs/heads/main"], in: b), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == head)
        snapshot = try await service.remoteManagement()
        try await git(["config", "unrelated.fixture", "external edit"])
        let config = location.commonDirectory.appending(path: "config")
        let changedBytes = try Data(contentsOf: config)
        var stale = false
        do {
            try await service.changeRemote(
                .update(name: "origin", fetchURL: a.path, pushURL: nil), in: snapshot, expectedHead: head)
        } catch ModelFailure.changed { stale = true }
        try check("External config changes reject stale edits", stale)
        try check(
            "Rejected stale edit preserves exact changed config", try Data(contentsOf: config) == changedBytes
        )
        try await git(["config", "remote.origin.tagopt", "--no-tags"])
        snapshot = try await service.remoteManagement()
        try await service.changeRemote(
            .update(name: "origin", fetchURL: b.path, pushURL: a.path), in: snapshot, expectedHead: head)
        let details = try await service.remoteDetails(name: "origin")
        try check(
            "Fetch and independent push endpoints remain distinct",
            details.fetchURL == b.path && details.pushURLs == [a.path])
        try check(
            "URL edits preserve custom remote metadata",
            try await git(["config", "--get", "remote.origin.tagopt"]) == Data("--no-tags\n".utf8))
        try check(
            "URL edits preserve unrelated config",
            try await git(["config", "--get", "unrelated.fixture"]) == Data("external edit\n".utf8))
        let independent = try await service.preparePush(remote: "origin", branch: "main", expectedHead: head)
        _ = try await service.push(independent)
        try check(
            "Explicit push endpoint is the only confirmed destination",
            String(decoding: try await git(["rev-parse", "refs/heads/main"], in: a), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == head)
        snapshot = try await service.remoteManagement()
        let beforeFailure = try Data(contentsOf: config)
        let failingEngine = GitEngine(
            executable: URL(fileURLWithPath: "/usr/bin/git"), runner: FailConfigEdit(), environment: env)
        let failing = RepositoryService(location: location, engine: failingEngine)
        var editFailed = false
        do {
            try await failing.changeRemote(
                .update(name: "origin", fetchURL: a.path, pushURL: b.path), in: snapshot, expectedHead: head)
        } catch ProcessFailure.timedOut { editFailed = true }
        try check("A failed private edit reports its failure", editFailed)
        try check(
            "A failed second field leaves both original endpoints intact",
            try Data(contentsOf: config) == beforeFailure)
        try check(
            "A failed edit cleans only its own lock",
            !FileManager.default.fileExists(atPath: config.path + ".lock"))
        try await git(["config", "--add", "remote.origin.url", a.path])
        snapshot = try await service.remoteManagement()
        try check(
            "Multiple URL values are visible and read only",
            snapshot.remotes.first { $0.name == "origin" }!.fetchURLs.count == 2
                && snapshot.remotes.first { $0.name == "origin" }!.canEdit == false)
        let multiple = try Data(contentsOf: config)
        var multiRejected = false
        do {
            try await service.changeRemote(.remove(name: "origin"), in: snapshot, expectedHead: head)
        } catch ModelFailure.changed { multiRejected = true }
        try check(
            "Complex deletion is rejected without reducing multiple URLs",
            multiRejected && (try Data(contentsOf: config)) == multiple)
        try await git(["config", "--unset-all", "remote.origin.url"])
        try await git(["config", "--add", "remote.origin.url", b.path])
        snapshot = try await service.remoteManagement()
        try await service.changeRemote(
            .add(name: "origin.child", fetchURL: a.path, pushURL: nil), in: snapshot, expectedHead: head)
        snapshot = try await service.remoteManagement()
        try check(
            "Dotted remote subsections remain separate",
            snapshot.remotes.first { $0.name == "origin" }!.values.allSatisfy {
                !$0.key.hasPrefix("remote.origin.child.")
            })
        try await git([
            "config", "remote.secret.url", "https://fixture-user:fixture-password@example.invalid/repo.git",
        ])
        snapshot = try await service.remoteManagement()
        let secret = snapshot.remotes.first { $0.name == "secret" }!
        try check(
            "Credential-bearing addresses are redacted and read only",
            !secret.canEdit && !secret.displayFetchURLs.joined().contains("fixture-password"))
        let included = location.commonDirectory.appending(path: "remote-include")
        try Data("[remote \"included\"]\n url = https://example.invalid/included.git\n".utf8).write(
            to: included)
        try await git(["config", "include.path", included.path])
        let includedSnapshot = try await service.remoteManagement()
        try check(
            "Included local-scope remote is read only at its real origin",
            includedSnapshot.remotes.first { $0.name == "included" }?.canEdit == false)
        let beforeIncludedChange = try Data(contentsOf: config)
        try Data("[remote \"included\"]\n url = https://example.invalid/changed.git\n".utf8).write(
            to: included)
        var includeRejected = false
        do {
            try await service.changeRemote(
                .add(name: "stale-include", fetchURL: a.path, pushURL: nil), in: includedSnapshot,
                expectedHead: head)
        } catch ModelFailure.changed { includeRejected = true }
        try check("External included-file changes invalidate the editor", includeRejected)
        try check(
            "Stale included-file rejection preserves local config",
            try Data(contentsOf: config) == beforeIncludedChange)
        try (globalBytes + Data("[branch \"main\"]\n merge = refs/heads/main\n".utf8)).write(to: global)
        let inheritedBranch = try await service.remoteManagement()
        try check(
            "Inherited branch associations prevent destructive local removal",
            inheritedBranch.remotes.first { $0.name == "origin" }?.canDelete == false)
        try globalBytes.write(to: global)
        snapshot = try await service.remoteManagement()
        let signed = "https://example.invalid/a?sig=fixture-signature"
        try check(
            "Opaque signed URL queries are redacted", !Redaction.text(signed).contains("fixture-signature"))
        let lock = URL(fileURLWithPath: config.path + ".lock")
        try Data("other writer\n".utf8).write(to: lock)
        var lockRejected = false
        do {
            try await service.changeRemote(
                .add(name: "blocked", fetchURL: a.path, pushURL: nil), in: snapshot, expectedHead: head)
        } catch ModelFailure.changed { lockRejected = true }
        try check("An existing config writer prevents mutation", lockRejected)
        try check(
            "Another writer's lock is preserved", try Data(contentsOf: lock) == Data("other writer\n".utf8))
        try FileManager.default.removeItem(at: lock)
        try await git(["fetch", "origin"])
        snapshot = try await service.remoteManagement()
        try check(
            "Removal previews impacted upstream branches",
            snapshot.remotes.first { $0.name == "origin" }!.upstreamBranches == ["main"])
        try await service.changeRemote(.remove(name: "origin"), in: snapshot, expectedHead: head)
        let remaining = try await service.remoteManagement()
        try check(
            "Removal deletes only the confirmed remote section",
            !remaining.remotes.contains { $0.name == "origin" }
                && remaining.remotes.contains { $0.name == "origin.child" })
        try check("Removal clears the owned branch association", try await service.upstreamTarget() == nil)
        try check(
            "Removal retains local tracking refs for recovery",
            try await git(["show-ref", "--verify", "refs/remotes/origin/main"]).isEmpty == false)
        let invalidBefore = try Data(contentsOf: config)
        for name in ["-option", ".", "bad name", "bad..name"] {
            var rejected = false
            do {
                try await service.changeRemote(
                    .add(name: name, fetchURL: a.path, pushURL: nil), in: remaining, expectedHead: head)
            } catch { rejected = true }
            try check("Invalid remote name is rejected: " + name, rejected)
        }
        try check("Rejected names leave config unchanged", try Data(contentsOf: config) == invalidBefore)
        try check(
            "All edits preserve HEAD and working bytes",
            try await service.head() == head
                && Data(contentsOf: work.appending(path: "file")) == Data("base\n".utf8))
        try check(
            "All edits preserve private global config bytes", try Data(contentsOf: global) == globalBytes)
        var timings: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            _ = try await service.remoteManagement()
            let elapsed = start.duration(to: .now).components
            timings.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        let orderedSamples = timings
        timings.sort()
        let metrics: [String: Any] = [
            "samplesMs": orderedSamples, "samples": timings.count,
            "medianMs": timings[15],
            "p95Ms": timings[28],
            "remoteCount": remaining.remotes.count,
        ]
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted]).write(
            to: URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appending(
                path: "performance.json"))
        try check("Remote snapshot completes within a two-second p95 read budget", timings[28] < 2000)
        let copy = root.appending(path: "config-copy")
        try Data(contentsOf: config).write(to: copy)
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: copy)
        var linkRejected = false
        do { _ = try await service.remoteManagement() } catch { linkRejected = true }
        try check(
            "Symlinked repository config is never replaced",
            linkRejected && (try Data(contentsOf: copy)) == invalidBefore)
        try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted]).write(
            to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("\(checks.count) isolated remote management checks passed.")
    }
}
