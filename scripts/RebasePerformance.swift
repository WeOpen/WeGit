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
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "WeGitRebasePerformance-\(UUID())")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
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
        do {
            for (name, files, commits, memoryBudget) in [
                ("ordinary", 10, 5, 256 * 1024 * 1024), ("large", 5_000, 30, 512 * 1024 * 1024),
            ] {
                activeWorkload = name
                activeSamples = []
                let directory = parent.appending(path: name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                @discardableResult func git(_ args: [String]) async throws -> String {
                    try await engine.run(args, in: directory).text.trimmingCharacters(in: .newlines)
                }
                try await git(["init", "-b", "main"])
                for (key, value) in [
                    ("user.name", "Performance"), ("user.email", "fixture@example.invalid"),
                    ("commit.gpgsign", "false"), ("core.hooksPath", parent.appending(path: "no-hooks").path),
                ] {
                    try await git(["config", key, value])
                }
                for index in 0..<files {
                    try Data("base \(index)\n".utf8).write(to: directory.appending(path: "file-\(index)"))
                }
                try await git(["add", "."])
                try await git(["commit", "-m", "Base"])
                try await git(["switch", "-c", "feature"])
                for index in 0..<commits {
                    try Data("feature \(index)\n".utf8).write(to: directory.appending(path: "file-0"))
                    try await git(["commit", "-am", "Feature \(index)"])
                }
                let original = try await git(["rev-parse", "HEAD"])
                try await git(["switch", "main"])
                try Data("target\n".utf8).write(to: directory.appending(path: "file-1"))
                try await git(["commit", "-am", "Target"])
                try await git(["switch", "feature"])
                let location = try await RepositoryService.discover(directory, engine: engine)
                let target = try await RepositoryService(location: location, engine: engine).branches().first
                { $0.name == "main" }!
                let indexPath = location.gitDirectory.appending(path: "index")
                let indexBytes = try Data(contentsOf: indexPath)
                let ready = location.gitDirectory.appending(path: "performance-ready")
                let wrapper = location.gitDirectory.appending(path: "performance-git")
                let script =
                    "#!/bin/sh\nmatching=0\nfor word in \"$@\"; do [ \"$word\" = merge-base ] && matching=1; done\nif [ \"${WEGIT_REBASE_DELAY:-0}\" = 1 ] && [ \"$matching\" = 1 ]; then\n trap 'exit 143' TERM\n /bin/sleep 10 &\n child=$!\n printf '%s %s\\n' \"$$\" \"$child\" > "
                    + quote(ready.path) + "\n wait \"$child\"\nfi\nexec " + quote(executable.path)
                    + " \"$@\"\n"
                try Data(script.utf8).write(to: wrapper)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
                var delayedEnvironment = environment
                delayedEnvironment["WEGIT_REBASE_DELAY"] = "1"
                let delayedEngine = GitEngine(executable: wrapper, environment: delayedEnvironment)
                var samples: [Sample] = []
                for iteration in 0..<30 {
                    let service = RepositoryService(location: location, engine: engine)
                    let clock = ContinuousClock()
                    var start = clock.now
                    let first = try await service.prepareRebase(target: target)
                    let firstMs = milliseconds(start.duration(to: clock.now))
                    start = clock.now
                    let steady = try await service.prepareRebase(target: target)
                    let steadyMs = milliseconds(start.duration(to: clock.now))
                    try require(
                        first.head == original && steady.head == original && first.commits.count == commits
                            && first.conflictPaths.isEmpty, "Invalid replay sample")
                    try? FileManager.default.removeItem(at: ready)
                    let delayed = RepositoryService(location: location, engine: delayedEngine)
                    let task = Task { try await delayed.prepareRebase(target: target) }
                    let deadline = clock.now.advanced(by: .seconds(5))
                    while !FileManager.default.fileExists(atPath: ready.path), clock.now < deadline {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    let pids = try String(contentsOf: ready, encoding: .utf8).split(
                        whereSeparator: \.isWhitespace
                    ).compactMap { pid_t($0) }
                    try require(
                        pids.count == 2 && pids.allSatisfy { kill($0, 0) == 0 },
                        "Delayed read did not start its real processes")
                    start = clock.now
                    task.cancel()
                    do {
                        _ = try await task.value
                        throw Failure.assertion("Cancellation returned success")
                    } catch ProcessFailure.cancelled {} catch is CancellationError {}
                    while kill(-pids[0], 0) == 0, clock.now < start.advanced(by: .seconds(2)) {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    let cancelMs = milliseconds(start.duration(to: clock.now))
                    try require(
                        kill(-pids[0], 0) == -1 && errno == ESRCH, "Read process group survived cancellation")
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
                            cancelMilliseconds: cancelMs, recoveredMilliseconds: recoveredMs,
                            residentBytes: kib * 1024, wrapperPID: pids[0], childPID: pids[1]))
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
                        name: name, trackedFiles: files, replayCommits: commits, samples: samples,
                        p95First: first, p95Steady: steady, p95Cancel: cancel, p95Recovered: recovered,
                        p95ResidentBytes: memory, passed: passed))
                print(
                    "\(name): 30 valid Release samples; first \(first)ms, steady \(steady)ms, cancel \(cancel)ms, recovered \(recovered)ms, RSS \(memory); passed=\(passed)"
                )
            }
        } catch {
            let partial: [String: Any] = [
                "sourceRevision": revision, "inputs": inputs, "fixture": parent.path,
                "validWorkloads": reports.count, "activeWorkload": activeWorkload,
                "activeValidSamples": try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(activeSamples)), "allPassed": false,
                "error": String(describing: error),
            ]
            try JSONSerialization.data(withJSONObject: partial, options: [.prettyPrinted, .sortedKeys]).write(
                to: output, options: .atomic)
            throw error
        }
        let data = try JSONEncoder().encode(reports)
        let report: [String: Any] = [
            "sourceRevision": revision, "gitVersion": version, "inputs": inputs,
            "configuration": "ordinary Release Core", "fixture": parent.path, "samplesPerWorkload": 30,
            "budgetsMilliseconds": ["first": 2_000, "steady": 2_000, "cancel": 500, "recovered": 2_000],
            "workloads": try JSONSerialization.jsonObject(with: data),
            "allPassed": reports.allSatisfy(\.passed),
            "scope":
                "CLI fixed-range preparation and cancellation after a delay wrapper and child are alive; no claim about unmodified Git's large-repo cancellation or native/version acceptance",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output, options: .atomic)
        guard reports.allSatisfy(\.passed) else {
            throw Failure.assertion("Declared Release budgets failed; all valid samples retained")
        }
        finished = true
    }
}
