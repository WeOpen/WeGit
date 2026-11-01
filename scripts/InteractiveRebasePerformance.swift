import CryptoKit
import Darwin
import Foundation
import WeGitCore

@main struct InteractiveRebasePerformance {
    struct Sample: Codable {
        let iteration: Int
        let firstMilliseconds: Double
        let steadyMilliseconds: Double
        let cancelMilliseconds: Double
        let recoveredMilliseconds: Double
        let executeMilliseconds: Double
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
        let p95Execute: Double
        let p95ResidentBytes: Double
        let passed: Bool
    }
    enum Failure: Error { case assertion(String) }
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.assertion(message) }
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
    static func sourceFiles(_ source: URL) throws -> [String: String] {
        var paths = [
            "Package.swift", "scripts/InteractiveRebasePerformance.swift",
            "scripts/verify-interactive-rebase-performance.sh",
        ]
        let enumerator = FileManager.default.enumerator(
            at: source.appending(path: "WeGitCore"), includingPropertiesForKeys: [.isRegularFileKey])!
        for case let file as URL in enumerator {
            if ["swift", "strings", "stringsdict"].contains(file.pathExtension) {
                paths.append(String(file.path.dropFirst(source.path.count + 1)))
            }
        }
        var inputs: [String: String] = [:]
        for path in paths {
            inputs[path] = SHA256.hash(data: try Data(contentsOf: source.appending(path: path)))
                .map { String(format: "%02x", $0) }.joined()
        }
        return inputs
    }
    static func cancelRead(_ service: RepositoryService, upstream: GitBranch, ready: URL) async throws
        -> (milliseconds: Double, wrapper: pid_t, child: pid_t)
    {
        let clock = ContinuousClock()
        let task = Task { try await service.prepareInteractiveRebase(upstream: upstream) }
        do {
            let deadline = clock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: ready.path), clock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try require(
                FileManager.default.fileExists(atPath: ready.path),
                "read cancellation never reached readiness")
            let pids = try String(contentsOf: ready, encoding: .utf8)
                .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            try require(
                pids.count == 2 && pids.allSatisfy { $0 > 0 && kill($0, 0) == 0 },
                "read cancellation must reach both live processes")
            let start = clock.now
            task.cancel()
            do {
                _ = try await task.value
                throw Failure.assertion("cancelled read returned success")
            } catch ProcessFailure.cancelled {} catch is CancellationError {}
            while kill(-pids[0], 0) == 0, clock.now < start.advanced(by: .seconds(2)) {
                try await Task.sleep(for: .milliseconds(5))
            }
            try require(kill(-pids[0], 0) == -1 && errno == ESRCH, "read process group survived cancellation")
            return (milliseconds(start.duration(to: clock.now)), pids[0], pids[1])
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
    }
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixture = FileManager.default.temporaryDirectory.appending(
            path: "WeGitInteractivePerformance-\(UUID())")
        try FileManager.default.createDirectory(
            at: fixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var finished = false
        defer { if finished { try? FileManager.default.removeItem(at: fixture) } }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let executable = URL(fileURLWithPath: environment["WEGIT_TEST_GIT"] ?? "/usr/bin/git")
        let engine = GitEngine(executable: executable, environment: environment)
        let revision = try await engine.run(["rev-parse", "HEAD"], in: source).text.trimmingCharacters(
            in: .newlines)
        let gitVersion = try await engine.run(["--version"], in: source).text.trimmingCharacters(
            in: .newlines)
        let dirty = try await engine.run(["status", "--porcelain"], in: source).text.isEmpty == false
        let inputs = try sourceFiles(source)
        var reports: [Workload] = []
        var activeName = ""
        var activeSamples: [Sample] = []
        var phase = "fixture"
        var failure: String?
        do {
            for (name, files, commits, memoryBudget, storage) in [
                ("ordinary", 10, 5, 256 * 1024 * 1024, "loose"),
                ("large-loose", 5_000, 30, 512 * 1024 * 1024, "loose"),
                ("large-packed", 5_000, 30, 512 * 1024 * 1024, "packed"),
            ] {
                activeName = name
                activeSamples = []
                phase = "fixture.init"
                let directory = fixture.appending(path: name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                @discardableResult func git(_ args: [String]) async throws -> String {
                    try await engine.run(args, in: directory).text.trimmingCharacters(in: .newlines)
                }
                try await git(["init", "-b", "main"])
                for (key, value) in [
                    ("user.name", "Performance"), ("user.email", "fixture@example.invalid"),
                    ("commit.gpgsign", "false"), ("core.hooksPath", fixture.appending(path: "no-hooks").path),
                    ("gc.auto", "0"), ("maintenance.auto", "false"),
                ] { try await git(["config", key, value]) }
                for index in 0..<files {
                    try Data("base \(index)\n".utf8).write(to: directory.appending(path: "file-\(index)"))
                }
                try await git(["add", "."])
                try await git(["commit", "-m", "Base"])
                try await git(["switch", "-c", "topic"])
                for index in 0..<commits {
                    try Data("feature \(index)\n".utf8).write(to: directory.appending(path: "file-0"))
                    try await git(["commit", "-am", "Feature \(index)"])
                }
                let original = try await git(["rev-parse", "HEAD"])
                if storage == "packed" { try await git(["gc", "--quiet"]) }
                try await git(["fsck", "--full", "--no-dangling"])
                let statistics = try await git(["count-objects", "-v"])
                let packs = statistics.split(separator: "\n").first { $0.hasPrefix("packs: ") }
                    .flatMap { Int($0.dropFirst("packs: ".count)) }
                try require(
                    packs.map { storage == "packed" ? $0 > 0 : $0 == 0 } == true,
                    "declared object storage is not present")
                let location = try await RepositoryService.discover(directory, engine: engine)
                let upstream = try await RepositoryService(location: location, engine: engine).branches()
                    .first { $0.name == "main" }!
                let ready = location.gitDirectory.appending(path: "interactive-performance-ready")
                let pending = ready.appendingPathExtension("pending")
                let wrapper = location.gitDirectory.appending(path: "interactive-performance-git")
                let body = """
                    #!/bin/sh
                    matching=0
                    for word in "$@"; do test "$word" = merge-base && matching=1; done
                    if test "$matching" = 1; then
                      trap 'exit 143' TERM
                      /bin/sleep 10 &
                      child=$!
                      printf '%s %s\\n' "$$" "$child" > \(quote(pending.path)) || exit 1
                      /bin/mv \(quote(pending.path)) \(quote(ready.path)) || exit 1
                      wait "$child"
                    fi
                    exec \(quote(executable.path)) "$@"
                    """
                try Data(body.utf8).write(to: wrapper)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
                let delayedEngine = GitEngine(executable: wrapper, environment: environment)
                for iteration in 0..<30 {
                    phase = "sample.\(iteration).read"
                    let service = RepositoryService(location: location, engine: engine)
                    let index = try Data(contentsOf: location.gitDirectory.appending(path: "index"))
                    let clock = ContinuousClock()
                    var start = clock.now
                    let first = try await service.prepareInteractiveRebase(upstream: upstream)
                    let firstMs = milliseconds(start.duration(to: clock.now))
                    start = clock.now
                    let steady = try await service.prepareInteractiveRebase(upstream: upstream)
                    let steadyMs = milliseconds(start.duration(to: clock.now))
                    try require(
                        first.head == original && first.steps.count == commits && steady.steps == first.steps,
                        "invalid read sample")
                    phase = "sample.\(iteration).cancel"
                    try? FileManager.default.removeItem(at: ready)
                    try? FileManager.default.removeItem(at: pending)
                    let cancelled = try await cancelRead(
                        RepositoryService(location: location, engine: delayedEngine), upstream: upstream,
                        ready: ready)
                    start = clock.now
                    let recovered = try await service.prepareInteractiveRebase(upstream: upstream)
                    let recoveredMs = milliseconds(start.duration(to: clock.now))
                    try require(
                        recovered.head == original && recovered.steps == first.steps
                            && Data(contentsOf: location.gitDirectory.appending(path: "index")) == index,
                        "read or cancellation changed HEAD/index")
                    phase = "sample.\(iteration).execute"
                    let adjusted = recovered.replacing(
                        steps: recovered.steps.enumerated().map { index, step in
                            InteractiveRebaseStep(
                                id: step.id, subject: step.subject, author: step.author,
                                action: index == 0 ? .reword : .pick,
                                message: index == 0 ? "Reworded sample \(iteration)" : nil)
                        })
                    start = clock.now
                    guard case .completed = try await service.executeInteractiveRebase(adjusted) else {
                        throw Failure.assertion("write sample did not complete")
                    }
                    let executeMs = milliseconds(start.duration(to: clock.now))
                    try require(
                        try await git(["rev-list", "--count", upstream.oid + "..HEAD"]) == String(commits),
                        "write sample commit count")
                    try require(
                        try await git(["show", "HEAD:file-0"]) == "feature \(commits - 1)",
                        "write sample tree")
                    let rss = try await ProcessRunner().run(
                        ProcessRequest(
                            executable: URL(fileURLWithPath: "/bin/ps"),
                            arguments: ["-o", "rss=", "-p", String(getpid())], environment: environment))
                    guard rss.exitCode == 0,
                        let kib = Int(rss.text.trimmingCharacters(in: .whitespacesAndNewlines)), kib > 0
                    else { throw Failure.assertion("invalid RSS") }
                    var usage = rusage()
                    try require(
                        getrusage(RUSAGE_SELF, &usage) == 0 && usage.ru_maxrss > 0, "invalid peak RSS")
                    activeSamples.append(
                        Sample(
                            iteration: iteration, firstMilliseconds: firstMs, steadyMilliseconds: steadyMs,
                            cancelMilliseconds: cancelled.milliseconds, recoveredMilliseconds: recoveredMs,
                            executeMilliseconds: executeMs,
                            residentBytes: max(kib * 1024, Int(usage.ru_maxrss)),
                            wrapperPID: cancelled.wrapper, childPID: cancelled.child))
                    try await git(["reset", "--hard", original])
                }
                let first = percentile(activeSamples.map(\.firstMilliseconds))
                let steady = percentile(activeSamples.map(\.steadyMilliseconds))
                let cancel = percentile(activeSamples.map(\.cancelMilliseconds))
                let recovered = percentile(activeSamples.map(\.recoveredMilliseconds))
                let execute = percentile(activeSamples.map(\.executeMilliseconds))
                let rss = percentile(activeSamples.map { Double($0.residentBytes) })
                let passed =
                    first <= 2_000 && steady <= 2_000 && cancel <= 500 && recovered <= 2_000
                    && execute <= 10_000 && rss <= Double(memoryBudget)
                reports.append(
                    Workload(
                        name: name, trackedFiles: files, replayCommits: commits, objectStorage: storage,
                        objectStatistics: statistics, samples: activeSamples, p95First: first,
                        p95Steady: steady,
                        p95Cancel: cancel, p95Recovered: recovered, p95Execute: execute,
                        p95ResidentBytes: rss, passed: passed))
                print(
                    "\(name): 30 valid Release samples; read \(first)ms, steady \(steady)ms, cancel \(cancel)ms, recovery \(recovered)ms, execute \(execute)ms, RSS \(rss); passed=\(passed)"
                )
            }
        } catch { failure = String(describing: error) }
        let encoder = JSONEncoder()
        let workloads = try JSONSerialization.jsonObject(with: encoder.encode(reports))
        let partial = try JSONSerialization.jsonObject(with: encoder.encode(activeSamples))
        let allPassed = failure == nil && reports.count == 3 && reports.allSatisfy(\.passed)
        let report: [String: Any] = [
            "sourceRevision": revision, "workspaceDirty": dirty, "sourceFiles": inputs,
            "gitVersion": gitVersion,
            "configuration": "ordinary Release Core", "xctestExecuted": false, "samplesPerWorkload": 30,
            "memoryProbe":
                "Maximum of current RSS and the process lifetime resident high-water mark; child Git RSS excluded",
            "cancellationProbe":
                "Live delay wrapper plus child process; full process-group exit and subsequent real prepare required",
            "budgets": [
                "firstMilliseconds": 2_000, "steadyMilliseconds": 2_000, "cancelMilliseconds": 500,
                "recoveredMilliseconds": 2_000, "executeMilliseconds": 10_000,
                "ordinaryResidentBytes": 256 * 1024 * 1024, "largeResidentBytes": 512 * 1024 * 1024,
            ],
            "workloads": workloads, "allPassed": allPassed, "failure": failure as Any? ?? NSNull(),
            "phase": phase, "activeWorkload": activeName, "activeSamples": partial, "fixture": fixture.path,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output)
        guard allPassed else {
            throw Failure.assertion(
                "Release budgets or sample validity failed; complete and partial arrays retained")
        }
        finished = true
    }
}
