import Darwin
import Foundation

@testable import WeGitCore

private actor QueueGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func hold() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@main struct ConflictEditorPerformance {
    private enum Failure: Error { case assertion(String) }
    private static let sampleCount = 30
    private static let operationBudgetMilliseconds = 2_000.0
    private static let cancellationBudgetMilliseconds = 500.0
    private static let trackedPaths = ["conflict.txt"] + (0..<5000).map { "file-\($0).txt" }

    static func main() async {
        do {
            guard let reportPath = CommandLine.arguments.dropFirst().first else {
                throw Failure.assertion("Missing JSON report path")
            }
            var workloads: [[String: Any]] = []
            for workload in ["ordinary", "large-loose", "large-packed"] {
                workloads.append(try await run(workload))
            }
            let passed = workloads.allSatisfy { $0["passed"] as? Bool == true }
            let report: [String: Any] = [
                "scope": "Release Core conflict read/save/resolve with isolated disposable Git fixtures",
                "compilerMode":
                    "Release optimization with -enable-testing for internal queue waiter observation; no XCTest execution",
                "requiredSamplesPerWorkload": sampleCount,
                "budgetsMilliseconds": [
                    "read": operationBudgetMilliseconds,
                    "save": operationBudgetMilliseconds,
                    "markResolved": operationBudgetMilliseconds,
                    "queuedSaveCancellation": cancellationBudgetMilliseconds,
                ],
                "residentMemoryBudgetsBytes": ["ordinary": 256 * 1024 * 1024, "large": 512 * 1024 * 1024],
                "allPassed": passed,
                "xctestExecuted": false,
                "workloads": workloads,
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            guard passed else { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("Conflict editor performance failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ workload: String) async throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitConflictEditorPerf-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer {
            if completed {
                try? FileManager.default.removeItem(at: root)
            } else {
                print("Retained failed private fixture: \(root.path)")
            }
        }

        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let engine = GitEngine(environment: environment)
        @discardableResult func git(_ arguments: [String], accepted: Set<Int32> = [0]) async throws
            -> ProcessResult
        {
            try await engine.run(arguments, in: root, accepted: accepted, timeout: 120)
        }

        try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Conflict Editor Performance"),
            ("user.email", "conflict-performance@example.invalid"),
            ("commit.gpgsign", "false"),
            ("core.hooksPath", root.appending(path: "no-hooks").path),
            ("gc.auto", "0"),
            ("maintenance.auto", "false"),
        ] {
            try await git(["config", key, value])
        }
        let lines = (0..<1024).map { "base line \($0)" }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: root.appending(path: "conflict.txt"))
        for path in (workload == "ordinary" ? Array(trackedPaths.prefix(11)) : trackedPaths).dropFirst() {
            try Data("stable \(path)\n".utf8).write(to: root.appending(path: path))
        }
        try await git(["add", "."])
        try await git(["commit", "-m", "Base"])
        try await git(["switch", "-c", "feature"])
        try Data((lines + "feature\n").utf8).write(to: root.appending(path: "conflict.txt"))
        try await git(["commit", "-am", "Feature"])
        try await git(["switch", "main"])
        try Data((lines + "target\n").utf8).write(to: root.appending(path: "conflict.txt"))
        try await git(["commit", "-am", "Target"])
        try await git(["switch", "feature"])
        if workload == "large-packed" {
            try await git(["gc", "--aggressive", "--prune=now"])
        }
        let objectStats = try await git(["count-objects", "-v"])
        let counts = parseCounts(objectStats.text)
        if workload == "large-packed" {
            try require(
                counts["in-pack", default: 0] > 0 && counts["packs", default: 0] > 0,
                "Packed fixture did not remain packed before measurements")
        } else {
            try require(counts["packs", default: 0] == 0, "Loose fixture unexpectedly has a pack")
        }
        let location = try await RepositoryService.discover(root, engine: engine)
        let service = RepositoryService(location: location, engine: engine)
        let clock = ContinuousClock()
        var read: [Double] = []
        var save: [Double] = []
        var resolve: [Double] = []
        var cancel: [Double] = []
        let output = Data((lines + "resolved\n").utf8)

        for _ in 0..<sampleCount {
            try await git(["merge", "main"], accepted: [0, 1, 128])
            let readStart = clock.now
            let document = try await service.readConflictEditor(
                path: "conflict.txt", expectedHead: try await service.head())
            read.append(milliseconds(readStart, clock.now))

            let saveStart = clock.now
            let saved = try await service.saveConflictResult(
                document, text: String(decoding: output, as: UTF8.self))
            save.append(milliseconds(saveStart, clock.now))

            let gate = QueueGate()
            let holder = Task {
                try await service.queue.perform { await gate.hold() }
            }
            while !(await gate.started) { await Task.yield() }
            let queued = Task {
                try await service.saveConflictResult(saved, text: "cancelled queued draft\n")
            }
            let queueDeadline = clock.now.advanced(by: .seconds(2))
            while await service.queue.pendingOperationCountForTesting == 0,
                clock.now < queueDeadline
            {
                try await Task.sleep(for: .milliseconds(1))
            }
            try require(
                await service.queue.pendingOperationCountForTesting == 1,
                "Cancelled save did not enter the FIFO queue")
            let cancelStart = clock.now
            queued.cancel()
            do {
                _ = try await queued.value
                throw Failure.assertion("Cancelled queued save returned success")
            } catch is CancellationError {
                cancel.append(milliseconds(cancelStart, clock.now))
            }
            await gate.release()
            try await holder.value
            let resolveStart = clock.now
            try await service.markConflictResolved(saved)
            resolve.append(milliseconds(resolveStart, clock.now))
            try await git(["commit", "-m", "Resolve conflict"])
            try await git(["reset", "--hard", "HEAD^"])
        }

        let memory = peakResidentBytes()
        let summary: [String: Any] = [
            "name": workload,
            "trackedFiles": workload == "ordinary" ? 10 : 5000,
            "objectStatisticsBeforeMeasurement": objectStats.text,
            "objectsAtStart": counts,
            "samples": zip(read.indices, read).map { index, value in
                [
                    "iteration": index, "readMilliseconds": value,
                    "saveMilliseconds": save[index], "markResolvedMilliseconds": resolve[index],
                    "queuedSaveCancelMilliseconds": cancel[index],
                ]
            },
            "p95ReadMilliseconds": p95(read),
            "p95SaveMilliseconds": p95(save),
            "p95MarkResolvedMilliseconds": p95(resolve),
            "p95QueuedSaveCancelMilliseconds": p95(cancel),
            "peakResidentBytes": memory,
            "passed": p95(read) <= operationBudgetMilliseconds
                && p95(save) <= operationBudgetMilliseconds
                && p95(resolve) <= operationBudgetMilliseconds
                && p95(cancel) <= cancellationBudgetMilliseconds
                && memory <= (workload == "ordinary" ? 256 : 512) * 1024 * 1024,
        ]
        completed = true
        return summary
    }

    private static func parseCounts(_ text: String) -> [String: Int] {
        Dictionary(
            uniqueKeysWithValues: text.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: ":", maxSplits: 1)
                guard fields.count == 2, let value = Int(fields[1].trimmingCharacters(in: .whitespaces))
                else { return nil }
                return (String(fields[0]), value)
            })
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.assertion(message) }
    }

    private static func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant)
        -> Double
    {
        let elapsed = start.duration(to: end).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }

    private static func p95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }

    private static func peakResidentBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return Int64.max }
        return Int64(usage.ru_maxrss)
    }
}
