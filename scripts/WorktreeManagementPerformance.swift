import Foundation
import WeGitCore

@main struct WorktreeManagementPerformance {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("Worktree performance check failed: \(error)\n".utf8))
            exit(1)
        }
    }
    static func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: end).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
    static func run() async throws {
        let clock = ContinuousClock()
        var workloads: [[String: Any]] = []
        let budget = 2000.0
        var allPassed = false
        defer {
            if let path = CommandLine.arguments.dropFirst().first {
                let report: [String: Any] = [
                    "diagnosticOnly": true, "scope": "Release CLI; not UI or complete release acceptance",
                    "budgetMilliseconds": budget, "allPassed": allPassed, "workloads": workloads,
                ]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: path))
            }
        }
        for count in [10, 5000] {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "WeGitWorktreePerformance-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let parent = root.resolvingSymlinksInPath()
            var completed = false
            defer {
                if completed {
                    try? FileManager.default.removeItem(at: parent)
                } else {
                    print("Performance fixture preserved: " + parent.path)
                }
            }
            let repo = parent.appending(path: "main")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: false)
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["GIT_CONFIG_SYSTEM"] = "/dev/null"
            let engine = GitEngine(environment: env)
            @discardableResult func git(_ args: [String]) async throws -> Data {
                try await engine.run(args, in: repo, timeout: 120).stdout
            }
            try await git(["init", "-b", "main"])
            for (key, value) in [
                ("user.name", "Performance Fixture"), ("user.email", "fixture@example.invalid"),
                ("commit.gpgsign", "false"), ("core.hooksPath", parent.appending(path: "no-hooks").path),
                ("core.autocrlf", "false"),
            ] {
                try await git(["config", key, value])
            }
            let payload = Data("controlled worktree bytes\n".utf8)
            for i in 0..<count { try payload.write(to: repo.appending(path: "file-\(i)")) }
            try await git(["add", "."])
            try await git(["commit", "-m", "Fixture"])
            let bare = parent.appending(path: "remote.git")
            try await git(["init", "--bare", bare.path])
            try await git(["remote", "add", "origin", bare.path])
            try await git(["push", "origin", "main"])
            let service = try await RepositoryService(
                location: RepositoryService.discover(repo, engine: engine), engine: engine)
            let head = try await service.head()
            let index = try Data(contentsOf: service.location.gitDirectory.appending(path: "index"))
            var samples: [[String: Double]] = []
            for iteration in 0..<30 {
                let destination = parent.appending(path: "linked-\(iteration)")
                let start = clock.now
                let plan = try await service.prepareWorktreeCreation(
                    at: destination, kind: .newBranch("sample-\(iteration)"))
                let prepared = clock.now
                _ = try await service.executeWorktreeCreation(plan)
                let created = clock.now
                let row = try await service.worktrees().first { $0.path == destination.path }!
                let removeStart = clock.now
                let removal = try await service.prepareWorktreeRemoval(row)
                let removePrepared = clock.now
                let receipt = try await service.executeWorktreeRemoval(removal)
                let removed = clock.now
                for i in 0..<count {
                    guard
                        try Data(contentsOf: receipt.preservedDirectory.appending(path: "file-\(i)"))
                            == payload
                    else { throw ModelFailure.changed }
                }
                guard try await service.head() == head,
                    try Data(contentsOf: service.location.gitDirectory.appending(path: "index")) == index,
                    !FileManager.default.fileExists(atPath: destination.path)
                else { throw ModelFailure.changed }
                samples.append([
                    "prepareCreation": milliseconds(start, prepared),
                    "executeCreation": milliseconds(prepared, created),
                    "prepareRemoval": milliseconds(removeStart, removePrepared),
                    "executeRemoval": milliseconds(removePrepared, removed),
                ])
                try FileManager.default.removeItem(at: receipt.preservedDirectory.deletingLastPathComponent())
            }
            var p95: [String: Double] = [:]
            for key in ["prepareCreation", "executeCreation", "prepareRemoval", "executeRemoval"] {
                let values = samples.map { $0[key]! }.sorted()
                p95[key] = values[Int(ceil(Double(values.count) * 0.95)) - 1]
            }
            workloads.append([
                "fileCount": count, "sampleCount": samples.count, "verifiedSamples": samples.count,
                "samples": samples, "p95Milliseconds": p95, "passed": p95.values.allSatisfy { $0 <= budget },
            ])
            completed = true
            print("Release worktree \(count) files, 30 verified samples: \(p95)")
        }
        allPassed = workloads.allSatisfy { $0["passed"] as? Bool == true }
        guard allPassed else {
            throw NSError(
                domain: "WorktreePerformance", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Recorded worktree p95 exceeds the predeclared background budget"
                ])
        }
    }
}
