import Darwin
import Foundation
import WeGitCore

private actor ReadRequestRecorder: ProcessRunning {
    struct Entry: Sendable {
        let arguments: [String]
        let directory: URL?
        let limit: Int
    }
    private var entries: [Entry] = []
    private let runner = ProcessRunner()

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        entries.append(
            Entry(arguments: request.arguments, directory: request.directory, limit: request.outputLimit))
        return try await runner.run(request)
    }
    func take() -> [Entry] {
        defer { entries.removeAll() }
        return entries
    }
}

@main struct WorktreeReadPerformance {
    private enum Failure: Error { case assertion(String) }
    private static let listArguments = [
        "--no-pager", "--literal-pathspecs", "--no-optional-locks", "worktree", "list", "--porcelain", "-z",
    ]
    private static let budgets = ["firstList": 250.0, "cancelResponse": 500.0, "postCancelList": 250.0]
    private static let sampleCount = 30

    static func main() async {
        var workloads: [[String: Any]] = []
        var failure: String?
        do { try await run(workloads: &workloads) } catch {
            failure = String(describing: error)
            FileHandle.standardError.write(Data("Worktree read check failed: \(error)\n".utf8))
        }
        let report: [String: Any] = [
            "diagnosticOnly": true,
            "scope":
                "Optimized Release CLI; first request per fresh service, filesystem cache uncontrolled; cancellation uses a private delayed list wrapper, not a slow unmodified Git benchmark. Not UI or complete version acceptance.",
            "budgetMilliseconds": budgets, "requiredSamplesPerWorkload": sampleCount,
            "allPassed": failure == nil, "failure": failure as Any? ?? NSNull(), "workloads": workloads,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        do {
            guard let path = CommandLine.arguments.dropFirst().first else {
                throw Failure.assertion("Missing report path")
            }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Cannot retain read report: \(error)\n".utf8))
            exit(1)
        }
        if failure != nil { exit(1) }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.assertion(message) }
    }
    private static func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant)
        -> Double
    {
        let value = start.duration(to: end).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
    private static func verifyRequests(_ entries: [ReadRequestRecorder.Entry], root: URL) throws {
        try require(
            entries.count == 1,
            "Listing must issue exactly one metadata request, without sibling status scans")
        guard let entry = entries.first else { throw Failure.assertion("Missing list request") }
        try require(
            entry.arguments == listArguments && entry.directory == root && entry.limit == 4 * 1024 * 1024,
            "List request changed command, repository or bounded output limit")
    }
    private static func verifyRows(_ rows: [GitWorktree], locations: [RepositoryLocation], head: String)
        throws
    {
        try require(rows.count == locations.count, "Missing or unexpected worktree registration")
        try require(
            Set(rows.map(\.path)) == Set(locations.map { $0.root.path }), "Canonical worktree paths differ")
        for (index, location) in locations.enumerated() {
            guard let row = rows.first(where: { $0.path == location.root.path }) else {
                throw Failure.assertion("Registered worktree absent")
            }
            try require(
                row.head == head && row.branchName == (index == 0 ? "main" : "sibling-\(index - 1)")
                    && row.primary == (index == 0), "Worktree OID, branch or primary identity differs")
        }
    }

    private static func run(workloads: inout [[String: Any]]) async throws {
        let clock = ContinuousClock()
        for (fileCount, siblingCount) in [(10, 1), (5000, 1), (10, 32)] {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "WeGitWorktreeRead-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let parent = root.resolvingSymlinksInPath()
            var completed = false
            defer {
                if completed {
                    try? FileManager.default.removeItem(at: parent)
                } else {
                    print("Read fixture retained: " + parent.path)
                }
            }
            let repo = parent.appending(path: "main")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: false)
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
            let engine = GitEngine(environment: environment)
            @discardableResult func git(_ arguments: [String]) async throws -> Data {
                try await engine.run(arguments, in: repo, timeout: 120).stdout
            }
            try await git(["init", "-b", "main"])
            for (key, value) in [
                ("user.name", "Read Performance Fixture"), ("user.email", "fixture@example.invalid"),
                ("commit.gpgsign", "false"), ("core.hooksPath", parent.appending(path: "no-hooks").path),
                ("core.autocrlf", "false"),
            ] { try await git(["config", key, value]) }
            let payload = Data("controlled read-only worktree bytes\n".utf8)
            for index in 0..<fileCount { try payload.write(to: repo.appending(path: "file-\(index)")) }
            try await git(["add", "."])
            try await git(["commit", "-m", "Read fixture"])
            var locations = [try await RepositoryService.discover(repo, engine: engine)]
            for index in 0..<siblingCount {
                let destination = parent.appending(path: "sibling-\(index)")
                try await git(["worktree", "add", "-b", "sibling-\(index)", destination.path, "HEAD"])
                locations.append(try await RepositoryService.discover(destination, engine: engine))
            }
            let head = String(decoding: try await git(["rev-parse", "HEAD"]), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            let refs = try await git(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"])
            var baseline: [URL: Data] = [:]
            for (treeIndex, location) in locations.enumerated() {
                // Include dirty, untracked and ignored data. A list must leave these bytes untouched.
                try Data("locally changed bytes\n".utf8).write(to: location.root.appending(path: "file-0"))
                try Data("untracked private bytes\n".utf8).write(
                    to: location.root.appending(path: "untracked"))
                try Data("ignored private bytes\n".utf8).write(to: location.root.appending(path: "ignored"))
                for name in (0..<fileCount).map({ "file-\($0)" }) + ["untracked", "ignored"] {
                    let path = location.root.appending(path: name)
                    baseline[path] = try Data(contentsOf: path)
                }
                for name in ["HEAD", "index"] {
                    let path = location.gitDirectory.appending(path: name)
                    baseline[path] = try Data(contentsOf: path)
                }
                if treeIndex > 0 {
                    baseline[location.root.appending(path: ".git")] = try Data(
                        contentsOf: location.root.appending(path: ".git"))
                }
            }
            let exclude = locations[0].commonDirectory.appending(path: "info/exclude")
            try Data("ignored\n".utf8).write(to: exclude)
            baseline[exclude] = try Data(contentsOf: exclude)
            let config = locations[0].commonDirectory.appending(path: "config")
            baseline[config] = try Data(contentsOf: config)

            let wrapper = parent.appending(path: "delayed-git")
            let script = """
                #!/bin/sh
                case " $* " in
                  *" worktree list --porcelain -z "*)
                    printf '%s\\n' "$$" > "$WEGIT_READ_PID"
                    /bin/sleep 30 &
                    child=$!
                    trap 'wait "$child" 2>/dev/null; exit 143' TERM INT
                    printf '%s\\n' "$child" > "$WEGIT_READ_CHILD"
                    /usr/bin/touch "$WEGIT_READ_READY"
                    wait "$child"
                    exit $?
                    ;;
                esac
                exec /usr/bin/git "$@"
                """
            try Data(script.utf8).write(to: wrapper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let recorder = ReadRequestRecorder()
            let recordedEngine = GitEngine(runner: recorder, environment: environment)
            let workloadIndex = workloads.count
            workloads.append([
                "fileCount": fileCount, "siblingCount": siblingCount, "registeredWorktrees": locations.count,
                "sampleCount": 0, "verifiedSamples": 0, "samples": [], "passed": false,
                "fixturePath": parent.path,
            ])
            var samples: [[String: Any]] = []
            for iteration in 0..<sampleCount {
                _ = await recorder.take()
                let service = RepositoryService(location: locations[0], engine: recordedEngine)
                let listStart = clock.now
                let rows = try await service.worktrees()
                let listEnd = clock.now
                try verifyRows(rows, locations: locations, head: head)
                try verifyRequests(await recorder.take(), root: locations[0].root)

                let marker = parent.appending(path: "ready-\(iteration)")
                let pidPath = parent.appending(path: "pid-\(iteration)")
                let childPath = parent.appending(path: "child-\(iteration)")
                var delayedEnvironment = environment
                delayedEnvironment["WEGIT_READ_READY"] = marker.path
                delayedEnvironment["WEGIT_READ_PID"] = pidPath.path
                delayedEnvironment["WEGIT_READ_CHILD"] = childPath.path
                let delayedEngine = GitEngine(executable: wrapper, environment: delayedEnvironment)
                let delayedService = RepositoryService(location: locations[0], engine: delayedEngine)
                let reading = Task { try await delayedService.worktrees() }
                let deadline = clock.now.advanced(by: .seconds(2))
                while !FileManager.default.fileExists(atPath: marker.path), clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard FileManager.default.fileExists(atPath: marker.path),
                    let processID = Int32(
                        try String(contentsOf: pidPath, encoding: .utf8).trimmingCharacters(in: .newlines)),
                    let childID = Int32(
                        try String(contentsOf: childPath, encoding: .utf8).trimmingCharacters(in: .newlines))
                else {
                    reading.cancel()
                    _ = await reading.result
                    throw Failure.assertion("Delayed list never reached an executing process")
                }
                try require(
                    Darwin.kill(processID, 0) == 0 && Darwin.kill(childID, 0) == 0,
                    "Cancellation sample must observe an executing process and child")
                let cancelStart = clock.now
                reading.cancel()
                let outcome = await reading.result
                let cancelEnd = clock.now
                switch outcome {
                case .success: throw Failure.assertion("Cancelled list returned success")
                case .failure(let error):
                    guard
                        error is CancellationError
                            || (error as? ProcessFailure).map({
                                if case .cancelled = $0 { true } else { false }
                            }) == true
                    else { throw error }
                }
                try require(
                    Darwin.kill(-processID, 0) == -1 && errno == ESRCH,
                    "Cancellation left a live process group")
                guard case .cancelled? = (await delayedEngine.activity.all()).first?.state else {
                    throw Failure.assertion("Activity did not record cancellation")
                }

                let recoveredService = RepositoryService(location: locations[0], engine: recordedEngine)
                let recoveredStart = clock.now
                let recovered = try await recoveredService.worktrees()
                let recoveredEnd = clock.now
                try verifyRows(recovered, locations: locations, head: head)
                try verifyRequests(await recorder.take(), root: locations[0].root)
                try require(
                    try await git(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"])
                        == refs,
                    "Read/cancellation changed branch refs")
                for (path, bytes) in baseline {
                    try require(
                        try Data(contentsOf: path) == bytes,
                        "Read/cancellation changed original bytes: " + path.path)
                }
                samples.append([
                    "iteration": iteration + 1, "firstList": milliseconds(listStart, listEnd),
                    "cancelResponse": milliseconds(cancelStart, cancelEnd),
                    "postCancelList": milliseconds(recoveredStart, recoveredEnd),
                    "snapshotVerified": true, "listRequestCount": 1, "postCancelListRequestCount": 1,
                    "executingProcessAndChildObserved": true, "cancelledProcessGroupGone": true,
                ])
                workloads[workloadIndex]["samples"] = samples
                workloads[workloadIndex]["sampleCount"] = samples.count
                workloads[workloadIndex]["verifiedSamples"] = samples.count
            }
            var percentiles: [String: Double] = [:]
            for key in budgets.keys {
                let values = samples.compactMap { $0[key] as? Double }.sorted()
                try require(
                    values.count == sampleCount && values.allSatisfy { $0.isFinite && $0 >= 0 },
                    "Invalid raw samples")
                percentiles[key] = values[Int(ceil(Double(sampleCount) * 0.95)) - 1]
            }
            let passed = budgets.allSatisfy { percentiles[$0.key]! <= $0.value }
            workloads[workloadIndex]["p95Milliseconds"] = percentiles
            workloads[workloadIndex]["passed"] = passed
            workloads[workloadIndex]["fixturePath"] = passed ? NSNull() : parent.path as Any
            completed = passed
            print(
                "Release reads: \(fileCount) files, \(siblingCount) siblings, \(sampleCount) verified samples: \(percentiles)"
            )
        }
        try require(
            workloads.allSatisfy { $0["passed"] as? Bool == true },
            "Recorded P95 exceeds the predeclared read/cancel budget")
    }
}
