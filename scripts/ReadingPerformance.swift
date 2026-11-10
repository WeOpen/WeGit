import CryptoKit
import Darwin
import Foundation
import WeGitCore

private final class ReadingMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    private var peak = 0
    init() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sample() }
        sample()
        timer.resume()
    }
    private func sample() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS { lock.withLock { peak = max(peak, Int(info.resident_size)) } }
    }
    func finish() -> Int {
        sample()
        timer.cancel()
        return lock.withLock { peak }
    }
    deinit { timer.cancel() }
}

@main struct ReadingPerformance {
    struct Fixtures: Decodable {
        let format: Int
        let complete: Bool
        let diagnosticOnly: Bool
        let git: String
        let workloads: [Fixture]
    }
    struct Fixture: Codable {
        let name: String
        let repository: String
        let commits: Int
        let references: Int
        let paths: Int
        let changedPaths: Int
        let base: String
        let target: String
        let stashes: Int
        let stashObjectID: String
        let expectedQueryCommits: [String]
        let expectedQueryReferences: [String: String]
        let preparedSeconds: Double
        let indexSHA256: String
        let objectCounts: String
        let historyShape: String
        let worktreeShape: String
    }
    struct Sample: Codable {
        let iteration: Int
        let comparisonFirstMilliseconds: Double
        let comparisonNextMilliseconds: Double
        let queryFirstMilliseconds: Double
        let queryNextMilliseconds: Double
        let switchFirstMilliseconds: Double
        let queryCancelMilliseconds: Double
        let comparisonCancelMilliseconds: Double
        let residentBytes: Int
        let queryFirstScopes: [String]
        let queryFirstResultCounts: [String: Int]
        let queryFixtureIdentitiesVerified: Bool
        let queryWrapperPID: Int32
        let queryChildPID: Int32
        let comparisonWrapperPID: Int32
        let comparisonChildPID: Int32
        let queryProcessGroupExitVerified: Bool
        let comparisonProcessGroupExitVerified: Bool
    }
    struct Workload: Codable {
        let fixture: Fixture
        let samples: [Sample]
        let p95: [String: Double]
        let maximumResidentBytes: Int
        let violations: [String]
        let passed: Bool
    }
    enum Failure: Error { case assertion(String) }
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.assertion(message) }
    }
    static func milliseconds(_ value: Duration) -> Double {
        Double(value.components.seconds) * 1000 + Double(value.components.attoseconds) / 1e15
    }
    static func p95(_ values: [Double]) -> Double {
        values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1]
    }
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    static func verifyQueryResults(_ results: [RepositoryQueryResult], fixture: Fixture) throws {
        var seen: Set<String> = []
        for result in results {
            try require(seen.insert(result.id).inserted, "Query page contains a duplicate identity")
            switch result {
            case .commit(let value):
                try require(
                    fixture.expectedQueryCommits.contains(value.id), "Query returned an unrelated commit")
            case .trackedPath(let value):
                let filename = URL(fileURLWithPath: value).lastPathComponent
                let number = Int(filename.dropFirst(5).dropLast(4))
                try require(
                    number.map {
                        (0..<fixture.paths).contains($0)
                            && value == String(format: "paths/group-%03d/file-%06d.txt", $0 / 1000, $0)
                    } == true,
                    "Query returned an unrelated path")
            case .branch(let value):
                try require(
                    fixture.expectedQueryReferences[value.id] == value.oid,
                    "Query returned an unrelated branch")
            case .tag(let value):
                try require(
                    fixture.expectedQueryReferences[value.reference] == value.objectID
                        && value.targetCommit == value.objectID && !value.annotated,
                    "Query returned an unrelated tag")
            case .stash(let value):
                try require(
                    value.objectID == fixture.stashObjectID && value.selector == "stash@{0}",
                    "Query lost the fixed stash identity")
            case .worktree(let value):
                try require(
                    URL(fileURLWithPath: value.path).standardizedFileURL
                        == URL(fileURLWithPath: fixture.repository).standardizedFileURL
                        && value.head == fixture.target, "Query lost the fixed worktree identity")
            case .command(let value):
                try require(value.id == "fixture-command" && value.enabled, "Query lost the supplied command")
            }
        }
    }
    static func cancellation<T: Sendable>(
        marker: URL, operation: @escaping @Sendable () async throws -> T
    ) async throws -> (Double, pid_t, pid_t) {
        try? FileManager.default.removeItem(at: marker)
        let task = Task { try await operation() }
        let clock = ContinuousClock()
        do {
            let deadline = clock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: marker.path), clock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let pids = try String(contentsOf: marker, encoding: .utf8)
                .split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            try require(
                pids.count == 2 && pids.allSatisfy { $0 > 0 && kill($0, 0) == 0 },
                "Cancellation did not reach live Git wrapper and child")
            let start = clock.now
            task.cancel()
            do {
                _ = try await task.value
                throw Failure.assertion("Cancelled read returned a result")
            } catch ProcessFailure.cancelled {} catch is CancellationError {}
            while kill(-pids[0], 0) == 0, clock.now < start.advanced(by: .seconds(2)) {
                try await Task.sleep(for: .milliseconds(5))
            }
            try require(kill(-pids[0], 0) == -1 && errno == ESRCH, "Cancelled read process group survived")
            return (milliseconds(start.duration(to: clock.now)), pids[0], pids[1])
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
    }
    static func wrapper(command: String, marker: URL, destination: URL, git: URL) throws {
        let script = """
            #!/bin/bash
            set -eu
            for argument in "$@"; do
              if [[ "$argument" == \(quote(command)) ]]; then
                sleep 60 &
                child_pid=$!
                trap 'trap "" TERM INT; kill "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; exit 143' TERM INT
                printf '%s %s\\n' "$$" "$child_pid" > \(quote(marker.path))
                wait "$child_pid"
              fi
            done
            exec \(quote(git.path)) "$@"
            """
        try Data(script.utf8).write(to: destination, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            print("Usage: checks fixtures.json result.json input-receipt.json")
            exit(2)
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let receiptURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: fixtureURL))
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))
        let root = fixtureURL.deletingLastPathComponent()
        try require(
            fixtures.format == 1 && fixtures.complete
                && fixtures.workloads.map(\.name) == ["ordinary", "large"], "Incomplete fixture manifest")
        let sampleCount = fixtures.diagnosticOnly ? 2 : 30
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let git = URL(fileURLWithPath: fixtures.git)
        let engine = GitEngine(executable: git, environment: environment)
        let gitVersion = try await engine.run(["--version"], in: root).text.trimmingCharacters(in: .newlines)
        var reports: [Workload] = []
        var active: [Sample] = []
        var phase = "verify fixture"
        var activeName = ""
        var activeIteration = 0
        var partialMeasurements: [String: Double] = [:]
        var failure: String?
        let clock = ContinuousClock()
        do {
            for fixture in fixtures.workloads {
                activeName = fixture.name
                active = []
                let repository = URL(fileURLWithPath: fixture.repository)
                try require(
                    repository.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
                    "Fixture escaped private root")
                if !fixtures.diagnosticOnly {
                    try require(
                        fixture.commits == (fixture.name == "ordinary" ? 10_000 : 100_000)
                            && fixture.references == 10_000 && fixture.paths == 100_000
                            && fixture.changedPaths == (fixture.name == "ordinary" ? 100 : 1000),
                        "Formal fixture scale changed")
                }
                let location = try await RepositoryService.discover(repository, engine: engine)
                let initialIndex = try hash(location.gitDirectory.appending(path: "index"))
                try require(initialIndex == fixture.indexSHA256, "Fixture index changed before sampling")
                let initialStashes = try await RepositoryService(location: location, engine: engine)
                    .stashes(limit: 100)
                try require(
                    fixture.stashes == 1 && initialStashes.entries.count == fixture.stashes
                        && initialStashes.entries.first?.objectID == fixture.stashObjectID
                        && !initialStashes.hasMore, "Fixture stash changed before sampling")
                let queryMarker = root.appending(path: fixture.name + "-query-ready")
                let compareMarker = root.appending(path: fixture.name + "-comparison-ready")
                let queryWrapper = root.appending(path: fixture.name + "-query-git")
                let compareWrapper = root.appending(path: fixture.name + "-comparison-git")
                try wrapper(command: "for-each-ref", marker: queryMarker, destination: queryWrapper, git: git)
                try wrapper(command: "rev-list", marker: compareMarker, destination: compareWrapper, git: git)
                for iteration in 1...sampleCount {
                    activeIteration = iteration
                    partialMeasurements = [:]
                    // New service and anchors every iteration. Retained OS object/page
                    // cache is explicitly uncontrolled; the first raw sample remains.
                    let service = RepositoryService(location: location, engine: engine)
                    let sampler = ReadingMemorySampler()
                    phase = "comparison first"
                    var start = clock.now
                    let plan = try await service.prepareReferenceComparison(
                        base: "refs/heads/base", target: "refs/heads/main", kind: .mergeBase)
                    let comparison = try await service.referenceComparison(plan)
                    let first = try await service.comparisonCommits(plan, count: 100)
                    let compareFirst = milliseconds(start.duration(to: clock.now))
                    partialMeasurements["comparisonFirstMilliseconds"] = compareFirst
                    try require(
                        plan.base.id == fixture.base && plan.target.id == fixture.target
                            && plan.mergeBases == [fixture.base] && comparison.effectiveBase == fixture.base
                            && comparison.comparison.files.count == fixture.changedPaths
                            && first.commits.count == 100 && first.nextOffset == 100,
                        "Comparison lost fixed endpoints, files or first page")
                    phase = "comparison next"
                    start = clock.now
                    let second = try await service.comparisonCommits(
                        plan, offset: first.nextOffset!, count: 100)
                    let compareNext = milliseconds(start.duration(to: clock.now))
                    partialMeasurements["comparisonNextMilliseconds"] = compareNext
                    try require(
                        second.commits.count == 100
                            && Set(first.commits.map(\.id)).isDisjoint(with: second.commits.map(\.id)),
                        "Comparison pages overlap or truncate")
                    phase = "query first"
                    start = clock.now
                    let anchor = try await service.repositoryQueryAnchor(
                        scope: .all,
                        commands: [
                            RepositoryQueryCommand(
                                id: "fixture-command", title: "Fixture command", symbol: "magnifyingglass")
                        ])
                    let queryFirst = try await service.repositoryQueryPage(anchor, count: 100)
                    let queryFirstMS = milliseconds(start.duration(to: clock.now))
                    partialMeasurements["queryFirstMilliseconds"] = queryFirstMS
                    try require(
                        queryFirst.results.count == 100 && queryFirst.next != nil
                            && Set(queryFirst.results.map(\.scope)).isSuperset(of: [
                                .commits, .trackedPaths, .branches, .tags, .stashes, .worktrees, .commands,
                            ]), "All-scope query lost a category or first page")
                    try verifyQueryResults(queryFirst.results, fixture: fixture)
                    let firstCounts = Dictionary(grouping: queryFirst.results, by: { $0.scope.rawValue })
                        .mapValues(\.count)
                    phase = "query next"
                    start = clock.now
                    let queryNext = try await service.repositoryQueryPage(
                        anchor, after: queryFirst.next, count: 100)
                    let queryNextMS = milliseconds(start.duration(to: clock.now))
                    partialMeasurements["queryNextMilliseconds"] = queryNextMS
                    try require(
                        queryNext.results.count == 100
                            && Set(queryFirst.results.map(\.id)).isDisjoint(with: queryNext.results.map(\.id)),
                        "Query pages overlap or truncate")
                    try verifyQueryResults(queryNext.results, fixture: fixture)
                    phase = "query cancel"
                    let delayedQuery = RepositoryService(
                        location: location,
                        engine: GitEngine(executable: queryWrapper, environment: environment))
                    let queryCancel = try await cancellation(marker: queryMarker) {
                        try await delayedQuery.repositoryQueryAnchor(scope: .commits, query: "obsolete query")
                    }
                    partialMeasurements["queryCancelMilliseconds"] = queryCancel.0
                    phase = "switch replacement query"
                    start = clock.now
                    let replacement = try await service.repositoryQueryAnchor(
                        scope: .trackedPaths, query: "file-")
                    let replacementPage = try await service.repositoryQueryPage(replacement, count: 100)
                    let switchMS = milliseconds(start.duration(to: clock.now))
                    partialMeasurements["switchFirstMilliseconds"] = switchMS
                    try require(
                        replacementPage.results.count == 100
                            && replacementPage.results.allSatisfy {
                                $0.scope == .trackedPaths && $0.title.contains("file-")
                            }, "Replacement query returned obsolete or wrong-scope results")
                    phase = "comparison cancel"
                    let delayedComparison = RepositoryService(
                        location: location,
                        engine: GitEngine(executable: compareWrapper, environment: environment))
                    let compareCancel = try await cancellation(marker: compareMarker) {
                        try await delayedComparison.comparisonCommits(plan, count: 100)
                    }
                    partialMeasurements["comparisonCancelMilliseconds"] = compareCancel.0
                    let resident = sampler.finish()
                    try require(resident > 0, "RSS sampling failed")
                    active.append(
                        Sample(
                            iteration: iteration, comparisonFirstMilliseconds: compareFirst,
                            comparisonNextMilliseconds: compareNext, queryFirstMilliseconds: queryFirstMS,
                            queryNextMilliseconds: queryNextMS, switchFirstMilliseconds: switchMS,
                            queryCancelMilliseconds: queryCancel.0,
                            comparisonCancelMilliseconds: compareCancel.0,
                            residentBytes: resident,
                            queryFirstScopes: Set(queryFirst.results.map { $0.scope.rawValue }).sorted(),
                            queryFirstResultCounts: firstCounts, queryFixtureIdentitiesVerified: true,
                            queryWrapperPID: queryCancel.1,
                            queryChildPID: queryCancel.2,
                            comparisonWrapperPID: compareCancel.1, comparisonChildPID: compareCancel.2,
                            queryProcessGroupExitVerified: true, comparisonProcessGroupExitVerified: true))
                    partialMeasurements = [:]
                }
                phase = "read-only fixture verification"
                try require(
                    try hash(location.gitDirectory.appending(path: "index")) == initialIndex,
                    "Measured reads changed index")
                let currentHead = try await engine.run(["rev-parse", "HEAD"], in: repository).text
                    .trimmingCharacters(in: .newlines)
                try require(currentHead == fixture.target, "Measured reads changed HEAD")
                let values = [
                    "comparisonFirst": p95(active.map(\.comparisonFirstMilliseconds)),
                    "comparisonNext": p95(active.map(\.comparisonNextMilliseconds)),
                    "queryFirst": p95(active.map(\.queryFirstMilliseconds)),
                    "queryNext": p95(active.map(\.queryNextMilliseconds)),
                    "switchFirst": p95(active.map(\.switchFirstMilliseconds)),
                    "queryCancel": p95(active.map(\.queryCancelMilliseconds)),
                    "comparisonCancel": p95(active.map(\.comparisonCancelMilliseconds)),
                    "residentBytes": p95(active.map { Double($0.residentBytes) }),
                ]
                let memory = fixture.name == "ordinary" ? 256 * 1024 * 1024 : 512 * 1024 * 1024
                let budgets: [String: Double] = [
                    "comparisonFirst": 2000, "comparisonNext": 1000,
                    "queryFirst": 2000, "queryNext": 1000, "switchFirst": 2000,
                    "queryCancel": 500, "comparisonCancel": 500,
                ]
                var violations = budgets.keys.sorted().filter { values[$0]! >= budgets[$0]! }
                let maximumRSS = active.map(\.residentBytes).max()!
                if maximumRSS > memory { violations.append("residentBytes") }
                reports.append(
                    Workload(
                        fixture: fixture, samples: active, p95: values,
                        maximumResidentBytes: maximumRSS, violations: violations, passed: violations.isEmpty))
                active = []
            }
        } catch { failure = String(describing: error) }
        let measuredPassed = failure == nil && reports.count == 2 && reports.allSatisfy(\.passed)
        let report: [String: Any] = [
            "format": 1, "scope": "comparison-and-unified-query-release-core",
            "diagnosticOnly": fixtures.diagnosticOnly,
            "allPassed": measuredPassed && !fixtures.diagnosticOnly,
            "diagnosticPassed": fixtures.diagnosticOnly && measuredPassed, "xctestExecuted": false,
            "requiredSamples": 30, "executedSamplesPerWorkload": sampleCount,
            "failure": failure as Any? ?? NSNull(), "phase": phase, "activeWorkload": activeName,
            "activeIteration": activeIteration, "partialMeasurements": partialMeasurements,
            "fixtureRoot": root.path, "fixturesSHA256": try hash(fixtureURL), "inputReceipt": receipt,
            "environment": [
                "git": gitVersion, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "processorCount": ProcessInfo.processInfo.processorCount,
            ],
            "cacheConditions":
                "New service and anchors each sample; packed objects/refs from fixture generation; first raw sample retained; OS filesystem cache uncontrolled; no cache flushing or warmup removal.",
            "cancellationConditions":
                "Live marker-synchronized private Git wrappers with child process; old read must throw cancellation and entire process group exit; replacement tracked-path query uses real Git.",
            "limits": [
                "firstMilliseconds": 2000, "nextMilliseconds": 1000, "cancelMilliseconds": 500,
                "ordinaryResidentBytes": 256 * 1024 * 1024, "largeResidentBytes": 512 * 1024 * 1024,
            ],
            "workloads": try JSONSerialization.jsonObject(with: JSONEncoder().encode(reports)),
            "incompleteSamples": try JSONSerialization.jsonObject(with: JSONEncoder().encode(active)),
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output, options: .atomic)
        if !measuredPassed {
            print("Reading performance failed; original samples and private fixture retained: \(root.path)")
            exit(1)
        }
        print(
            fixtures.diagnosticOnly
                ? "Reading development control passed; formal scale/samples not executed."
                : "Reading Release performance passed with 30 samples per workload.")
    }
}
