import Foundation
import WeGitCore

@main struct SyncCountsChecks {
    static func main() throws {
        var checks: [String] = []
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(
                    domain: "WeGit.SyncCounts", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks.append(message)
        }
        func counts(_ status: RepositoryStatus, loaded: Bool = true, stale: Bool = false)
            -> RepositorySyncCounts
        {
            RepositorySyncCounts(status: status, hasLoaded: loaded, isStale: stale)
        }
        var status = try StatusParser.parse(
            Data(
                "# branch.oid fixture\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +12 -3\0"
                    .utf8))
        try require(
            counts(status).ahead == 12 && counts(status).behind == 3, "Ahead and behind keep their directions"
        )
        try require(counts(status, loaded: false).ahead == nil, "Unloaded state hides cached counts")
        try require(counts(status, stale: true).behind == nil, "Stale state hides cached counts")
        status.ahead = 0
        status.behind = 0
        try require(
            counts(status).ahead == 0 && counts(status).behind == 0, "Known synchronized state displays zero")
        for invalid in ["no-upstream", "unborn", "detached", "missing-ahead", "missing-behind", "negative"] {
            var changed = status
            switch invalid {
            case "no-upstream": changed.upstream = nil
            case "unborn": changed.head = nil
            case "detached": changed.branch = "(detached)"
            case "missing-ahead": changed.ahead = nil
            case "missing-behind": changed.behind = nil
            default: changed.ahead = -1
            }
            try require(
                counts(changed).ahead == nil && counts(changed).behind == nil, "Unknown counts for " + invalid
            )
        }

        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitSyncCounts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = root
            process.arguments = ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
            environment["GIT_AUTHOR_NAME"] = "Sync Fixture"
            environment["GIT_AUTHOR_EMAIL"] = "sync@example.invalid"
            environment["GIT_COMMITTER_NAME"] = "Sync Fixture"
            environment["GIT_COMMITTER_EMAIL"] = "sync@example.invalid"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "WeGit.SyncCounts.Git", code: Int(process.terminationStatus))
            }
            return data
        }
        _ = try git(["init", "-b", "main"])
        let unborn = try StatusParser.parse(git(["status", "--porcelain=v2", "-z", "--branch"]))
        try require(counts(unborn).ahead == nil, "Real unborn repository has no count")
        _ = try git(["commit", "--allow-empty", "-m", "Base"])
        let base = String(decoding: try git(["rev-parse", "HEAD"]), as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        _ = try git(["remote", "add", "origin", root.path])
        for index in 1...3 { _ = try git(["commit", "--allow-empty", "-m", "Remote \(index)"]) }
        _ = try git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        _ = try git(["branch", "--set-upstream-to=origin/main", "main"])
        _ = try git(["reset", "--hard", base])
        for index in 1...2 { _ = try git(["commit", "--allow-empty", "-m", "Local \(index)"]) }
        let divergent = try StatusParser.parse(git(["status", "--porcelain=v2", "-z", "--branch"]))
        try require(
            counts(divergent).ahead == 2 && counts(divergent).behind == 3,
            "Real divergent history yields Push 2 and Pull 3")
        _ = try git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        let synchronized = try StatusParser.parse(git(["status", "--porcelain=v2", "-z", "--branch"]))
        try require(
            counts(synchronized).ahead == 0 && counts(synchronized).behind == 0,
            "Upstream refresh updates both counts to zero")
        _ = try git(["switch", "--detach"])
        let detached = try StatusParser.parse(git(["status", "--porcelain=v2", "-z", "--branch"]))
        try require(
            counts(detached).ahead == nil && counts(detached).behind == nil,
            "Real detached HEAD has no upstream count")
        let report: [String: Any] = ["passed": checks.count, "checks": checks]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 {
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("\(checks.count) sync count behavior checks passed.")
    }
}
