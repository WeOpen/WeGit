import CryptoKit
import Darwin
import Foundation
import WeGitCore

@main struct RebasePerformance {
    struct Sample: Codable {
        let iteration: Int
        let firstMilliseconds: Double
        let steadyMilliseconds: Double
        let cancelMilliseconds: Double
        let recoveredMilliseconds: Double
        let residentBytes: Int
        let wrapperPID: Int32
        let childPID: Int32
    }
    struct Workload: Codable {
        let name: String
        let trackedFiles: Int
        let replayCommits: Int
        let objectStorage: String
        let objectStatistics: String
        let samples: [Sample]
        let p95First: Double
        let p95Steady: Double
        let p95Cancel: Double
        let p95Recovered: Double
        let p95ResidentBytes: Double
        let passed: Bool
    }
    enum Failure: Error { case assertion(String) }
    static func require(_ test: Bool, _ text: String) throws {
        guard test else { throw Failure.assertion(text) }
    }
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    static func percentile(_ values: [Double]) -> Double {
        values.sorted()[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)]
    }
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func cancellation(
        service: RepositoryService, target: GitBranch, ready: URL
    ) async throws -> (milliseconds: Double, wrapper: pid_t, child: pid_t) {
        let clock = ContinuousClock()
        let task = Task { try await service.prepareRebase(target: target) }
        var pids: [pid_t] = []
        do {
            let deadline = clock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: ready.path), clock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            pids = try String(contentsOf: ready, encoding: .utf8).split(
                whereSeparator: \.isWhitespace
            ).compactMap { pid_t($0) }
            try require(
                pids.count == 2 && pids.allSatisfy { kill($0, 0) == 0 },
                "Delayed read did not start its real processes; marker PIDs: \(pids)")
            let start = clock.now
            task.cancel()
            do {
                _ = try await task.value
                throw Failure.assertion("Cancellation returned success")
            } catch ProcessFailure.cancelled {} catch is CancellationError {}
            while kill(-pids[0], 0) == 0, clock.now < start.advanced(by: .seconds(2)) {
                try await Task.sleep(for: .milliseconds(5))
            }
            let elapsed = milliseconds(start.duration(to: clock.now))
            try require(
                kill(-pids[0], 0) == -1 && errno == ESRCH, "Read process group survived cancellation")
            return (elapsed, pids[0], pids[1])
        } catch {
            task.cancel()
            _ = try? await task.value
            if let group = pids.first {
                let deadline = clock.now.advanced(by: .seconds(2))
                while kill(-group, 0) == 0, clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try require(
                    kill(-group, 0) == -1 && errno == ESRCH,
                    "Read process group survived failed probe cleanup: \(error)")
            }
            throw error
        }
    }
    static func validateFailureFixture(parent: URL, identity: stat) throws {
        var current = stat()
        guard lstat(parent.path, &current) == 0, current.st_dev == identity.st_dev,
            current.st_ino == identity.st_ino, current.st_uid == getuid(), current.st_mode & 0o077 == 0,
            let files = FileManager.default.enumerator(
                at: parent, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { throw Failure.assertion("Failure fixture identity changed") }
        var bytes = 0
        var entries = 0
        for case let url as URL in files {
            entries += 1
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
            try require(entries <= 20_000 && bytes <= 16 * 1024 * 1024, "Failure fixture exceeds bounds")
        }
    }
    static func retainFailureFixture(parent: URL, output: URL, identity: stat) async throws -> String {
        try validateFailureFixture(parent: parent, identity: identity)
        let archive = output.deletingLastPathComponent().appending(path: "failure-fixture.tar.gz")
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-czf", archive.path, "-C", parent.path, "."], timeout: 30))
        try require(result.exitCode == 0, "Failure fixture archive failed")
        return archive.lastPathComponent
    }
    static func main() async {
        do { try await run() } catch {
            let details = (error as? GitFailure)?.details ?? String(describing: error)
            FileHandle.standardError.write(Data(("Rebase performance check failed: " + details + "\n").utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "WeGitRebasePerformance-\(UUID())")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var parentIdentity = stat()
        guard lstat(parent.path, &parentIdentity) == 0 else { throw Failure.assertion("Missing fixture") }
        var finished = false
        defer { if finished { try? FileManager.default.removeItem(at: parent) } }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let executable = URL(fileURLWithPath: environment["WEGIT_TEST_GIT"] ?? "/usr/bin/git")
        let engine = GitEngine(executable: executable, environment: environment)
        let revision = try await engine.run(["rev-parse", "HEAD"], in: root).text.trimmingCharacters(
            in: .newlines)
        let version = try await engine.run(["--version"], in: root).text.trimmingCharacters(in: .newlines)
        let inputPaths =
            ["Package.swift", "scripts/RebasePerformance.swift", "scripts/verify-rebase-performance.sh"]
            + (try FileManager.default.contentsOfDirectory(
                atPath: root.appending(path: "WeGitCore/GitCore").path))
            .filter { $0.hasPrefix("Rebase") && $0.hasSuffix(".swift") }.map { "WeGitCore/GitCore/" + $0 }
            + ["WeGitCore/Domain/RebaseOperation.swift", "WeGitCore/Infrastructure/ProcessRunner.swift"]
        var inputs: [String: String] = [:]
        for path in inputPaths {
            inputs[path] = SHA256.hash(data: try Data(contentsOf: root.appending(path: path))).map {
                String(format: "%02x", $0)
            }.joined()
        }
        var reports: [Workload] = []
        var activeWorkload = ""
        var activeSamples: [Sample] = []
        var phase = "fixture"
        do {
            for (name, files, commits, memoryBudget, storage) in [
                ("ordinary", 10, 5, 256 * 1024 * 1024, "loose"),
                ("large-loose", 5_000, 30, 512 * 1024 * 1024, "loose"),
                ("large-packed", 5_000, 30, 512 * 1024 * 1024, "packed"),
            ] {
                activeWorkload = name
                activeSamples = []
                phase = "fixture.init"
                let directory = parent.appending(path: name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                @discardableResult func git(_ args: [String]) async throws -> String {
                    try await engine.run(args, in: directory).text.trimmingCharacters(in: .newlines)
                }
                try await git(["init", "-b", "main"])
                for (key, value) in [
                    ("user.name", "Performance"), ("user.email", "fixture@example.invalid"),
                    ("commit.gpgsign", "false"), ("core.hooksPath", parent.appending(path: "no-hooks").path),
                    ("gc.auto", "0"), ("maintenance.auto", "false"),
                ] {
                    try await git(["config", key, value])
                }
                for index in 0..<files {
                    try Data("base \(index)\n".utf8).write(to: directory.appending(path: "file-\(index)"))
                }
                phase = "fixture.add"
                try await git(["add", "."])
                phase = "fixture.base-commit"
                try await git(["commit", "-m", "Base"])
                try await git(["switch", "-c", "feature"])
                for index in 0..<commits {
                    phase = "fixture.feature-commit.\(index)"
                    try Data("feature \(index)\n".utf8).write(to: directory.appending(path: "file-0"))
                    try await git(["commit", "-am", "Feature \(index)"])
                }
                let original = try await git(["rev-parse", "HEAD"])
                phase = "fixture.switch-main"
                try await git(["switch", "main"])
                try Data("target\n".utf8).write(to: directory.appending(path: "file-1"))
                phase = "fixture.target-commit"
                try await git(["commit", "-am", "Target"])
                phase = "fixture.switch-feature"
                try await git(["switch", "feature"])
                phase = "fixture.object-storage"
                if storage == "packed" { try await git(["gc", "--quiet"]) }
                let statistics = try await git(["count-objects", "-v"])
                let packs = statistics.split(separator: "\n").first { $0.hasPrefix("packs: ") }
                    .flatMap { Int($0.dropFirst("packs: ".count)) }
                try require(
                    packs.map { storage == "packed" ? $0 > 0 : $0 == 0 } == true,
                    "Fixture object storage differs from its declared workload")
                phase = "fixture.fsck"
                _ = try await git(["fsck", "--full", "--no-reflogs"])
                phase = "fixture.discover"
                let location = try await RepositoryService.discover(directory, engine: engine)
                let target = try await RepositoryService(location: location, engine: engine).branches().first
                { $0.name == "main" }!
                let indexPath = location.gitDirectory.appending(path: "index")
                let indexBytes = try Data(contentsOf: indexPath)
                let ready = location.gitDirectory.appending(path: "performance-ready")
                let pendingReady = ready.appendingPathExtension("pending")
                let wrapper = location.gitDirectory.appending(path: "performance-git")
                let script =
                    "#!/bin/sh\nmatching=0\nfor word in \"$@\"; do [ \"$word\" = merge-base ] && matching=1; done\nif [ \"${WEGIT_REBASE_DELAY:-0}\" = 1 ] && [ \"$matching\" = 1 ]; then\n trap 'exit 143' TERM\n /bin/sleep 10 &\n child=$!\n printf '%s %s\\n' \"$$\" \"$child\" > "
                    + quote(pendingReady.path) + "\n /bin/mv " + quote(pendingReady.path) + " "
                    + quote(ready.path) + "\n wait \"$child\"\nfi\nexec " + quote(executable.path)
                    + " \"$@\"\n"
                try Data(script.utf8).write(to: wrapper)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
                var delayedEnvironment = environment
                delayedEnvironment["WEGIT_REBASE_DELAY"] = "1"
                let delayedEngine = GitEngine(executable: wrapper, environment: delayedEnvironment)
                var samples: [Sample] = []
                for iteration in 0..<30 {
                    phase = "sample.\(iteration).first"
                    let service = RepositoryService(location: location, engine: engine)
                    let clock = ContinuousClock()
                    var start = clock.now
                    let first = try await service.prepareRebase(target: target)
                    let firstMs = milliseconds(start.duration(to: clock.now))
                    phase = "sample.\(iteration).steady"
                    start = clock.now
                    let steady = try await service.prepareRebase(target: target)
                    let steadyMs = milliseconds(start.duration(to: clock.now))
                    try require(
                        first.head == original && steady.head == original && first.commits.count == commits
                            && first.conflictPaths.isEmpty, "Invalid replay sample")
                    try? FileManager.default.removeItem(at: ready)
                    let delayed = RepositoryService(location: location, engine: delayedEngine)
                    phase = "sample.\(iteration).cancel"
                    let cancelled = try await cancellation(service: delayed, target: target, ready: ready)
                    phase = "sample.\(iteration).recovered"
                    start = clock.now
                    let recovered = try await service.prepareRebase(target: target)
                    let recoveredMs = milliseconds(start.duration(to: clock.now))
                    let rss = try await ProcessRunner().run(
                        ProcessRequest(
                            executable: URL(fileURLWithPath: "/bin/ps"),
                            arguments: ["-o", "rss=", "-p", String(getpid())], environment: environment))
                    guard rss.exitCode == 0,
                        let kib = Int(rss.text.trimmingCharacters(in: .whitespacesAndNewlines)), kib > 0
                    else { throw Failure.assertion("Invalid measured RSS") }
                    try require(
                        recovered.head == original && recovered.commits.count == commits
                            && Data(contentsOf: indexPath) == indexBytes, "Recovered read changed HEAD/index")
                    samples.append(
                        Sample(
                            iteration: iteration, firstMilliseconds: firstMs, steadyMilliseconds: steadyMs,
                            cancelMilliseconds: cancelled.milliseconds, recoveredMilliseconds: recoveredMs,
                            residentBytes: kib * 1024, wrapperPID: cancelled.wrapper,
                            childPID: cancelled.child))
                    activeSamples = samples
                }
                let first = percentile(samples.map(\.firstMilliseconds))
                let steady = percentile(samples.map(\.steadyMilliseconds))
                let cancel = percentile(samples.map(\.cancelMilliseconds))
                let recovered = percentile(samples.map(\.recoveredMilliseconds))
                let memory = percentile(samples.map { Double($0.residentBytes) })
                let passed =
                    first <= 2_000 && steady <= 2_000 && cancel <= 500 && recovered <= 2_000
                    && memory <= Double(memoryBudget)
                reports.append(
                    Workload(
                        name: name, trackedFiles: files, replayCommits: commits,
                        objectStorage: storage, objectStatistics: statistics, samples: samples,
                        p95First: first, p95Steady: steady, p95Cancel: cancel, p95Recovered: recovered,
                        p95ResidentBytes: memory, passed: passed))
                print(
                    "\(name): 30 valid Release samples; first \(first)ms, steady \(steady)ms, cancel \(cancel)ms, recovered \(recovered)ms, RSS \(memory); passed=\(passed)"
                )
            }
        } catch {
            var partial: [String: Any] = [
                "sourceRevision": revision, "gitVersion": version, "inputs": inputs, "fixture": parent.path,
                "validWorkloads": reports.count, "activeWorkload": activeWorkload,
                "phase": phase,
                "workloads": try JSONSerialization.jsonObject(with: JSONEncoder().encode(reports)),
                "activeValidSamples": try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(activeSamples)), "allPassed": false,
                "error": String(describing: error),
            ]
            do {
                partial["failureFixtureArchive"] = try await retainFailureFixture(
                    parent: parent, output: output, identity: parentIdentity)
            } catch { partial["failureFixtureArchiveError"] = String(describing: error) }
            try JSONSerialization.data(withJSONObject: partial, options: [.prettyPrinted, .sortedKeys]).write(
                to: output, options: .atomic)
            throw error
        }
        let data = try JSONEncoder().encode(reports)
        var report: [String: Any] = [
            "sourceRevision": revision, "gitVersion": version, "inputs": inputs,
            "configuration": "ordinary Release Core", "fixture": parent.path, "samplesPerWorkload": 30,
            "budgetsMilliseconds": ["first": 2_000, "steady": 2_000, "cancel": 500, "recovered": 2_000],
            "workloads": try JSONSerialization.jsonObject(with: data),
            "allPassed": reports.allSatisfy(\.passed),
            "scope":
                "CLI fixed-range preparation with explicit loose/packed object storage and fixture-only automatic maintenance disabled; cancellation after a delay wrapper and child are alive; no claim about unmodified Git's large-repo cancellation or native/version acceptance",
        ]
        if !reports.allSatisfy(\.passed) {
            do {
                report["failureFixtureArchive"] = try await retainFailureFixture(
                    parent: parent, output: output, identity: parentIdentity)
            } catch { report["failureFixtureArchiveError"] = String(describing: error) }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output, options: .atomic)
        guard reports.allSatisfy(\.passed) else {
            throw Failure.assertion("Declared Release budgets failed; all valid samples retained")
        }
        finished = true
    }
}
