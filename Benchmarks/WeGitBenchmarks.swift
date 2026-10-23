import CryptoKit
import Darwin
import Foundation
import WeGitCore

private struct FixtureManifest: Codable, Sendable {
    let label: String
    let trackedFiles: Int
    let commits: Int
    let branches: Int
    let modifiedFiles: Int
    let diffPath: String
    let largeDiffPath: String?
}

private struct Measurement: Encodable {
    let name: String
    let firstRunMs: Double
    let samplesMs: [Double]
    var medianMs: Double {
        let values = samplesMs.sorted()
        return (values[(values.count - 1) / 2] + values[values.count / 2]) / 2
    }
    var p95Ms: Double { samplesMs.sorted()[Int(ceil(Double(samplesMs.count) * 0.95)) - 1] }
    private enum CodingKeys: String, CodingKey { case name, firstRunMs, samplesMs, medianMs, p95Ms }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(firstRunMs, forKey: .firstRunMs)
        try values.encode(samplesMs, forKey: .samplesMs)
        try values.encode(medianMs, forKey: .medianMs)
        try values.encode(p95Ms, forKey: .p95Ms)
    }
}

private struct Report: Encodable {
    let measuredAt: Date
    let fixture: FixtureManifest
    let sourceDigest: String
    let system: String
    let git: String
    let conditions: String
    let measurements: [Measurement]
    let backendPeakMiB: Double
    let childPeakMiB: Double
    let cancelledOperations: Int
    let completedBeforeCancellation: Int
    let featureFixture: [String: Int]
    let featureReadBudgetMs: Double
    let featureReadBudgetPassed: Bool
}

@main
struct WeGitBenchmarks {
    static func main() async {
        do { try await run() } catch {
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        #if DEBUG
            throw ModelFailure.unsupported("Benchmarks require a Release build.")
        #else
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 4 else {
                throw ModelFailure.unsupported(
                    "Usage: WeGitBenchmarks <fixture> <output.json> <source-root> <samples>=30")
            }
            let root = URL(fileURLWithPath: args[0]).standardizedFileURL
            let output = URL(fileURLWithPath: args[1]).standardizedFileURL
            guard let samples = Int(args[3]), (30...500).contains(samples),
                !FileManager.default.fileExists(atPath: output.path)
            else {
                throw ModelFailure.unsupported("Use 30–500 samples and a new output file.")
            }
            let manifest = try JSONDecoder().decode(
                FixtureManifest.self,
                from: Data(contentsOf: root.appending(path: ".git/wegit-benchmark.json")))
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
            let installation = try await GitInstallation.detect(
                preferred: URL(fileURLWithPath: "/usr/bin/git"))
            let engine = GitEngine(executable: installation.executable, environment: environment)
            let location = try await RepositoryService.discover(root, engine: engine)
            let service = RepositoryService(location: location, engine: engine)
            let version = installation.version
            let digest = try sourceDigest(URL(fileURLWithPath: args[2]))
            let state = try await service.status()
            guard state.files.count == manifest.modifiedFiles else { throw ModelFailure.changed }
            var measurements: [Measurement] = []
            measurements.append(
                try await measure("status", samples: samples) {
                    let state = try await service.status()
                    guard state.files.count == manifest.modifiedFiles else { throw ModelFailure.changed }
                })
            measurements.append(
                try await measure("coordinated_snapshot", samples: samples) {
                    _ = try await service.readSnapshot()
                })
            for split in [false, true] {
                measurements.append(
                    try await measure(
                        split ? "split_diff_first_page" : "unified_diff_first_page", samples: samples
                    ) {
                        let result = try await service.readDiff(path: manifest.diffPath, layer: .unstaged)
                        guard case .loaded(let diff) = result else { throw ModelFailure.changed }
                        let document = try await DiffDisplayDocument.prepare(diff, split: split)
                        let page = try await document.page(from: 0)
                        guard !page.rows.isEmpty else { throw ModelFailure.changed }
                    })
            }
            measurements.append(
                try await measure("history_first_200_and_graph", samples: samples) {
                    let anchor = try await service.historyAnchor()
                    let page = try await service.historyPage(anchor)
                    var graph = CommitGraphLayoutEngine()
                    guard graph.append(page.commits).count == 200 else { throw ModelFailure.changed }
                })
            var cancelled = 0
            var completed = 0
            if let large = manifest.largeDiffPath {
                measurements.append(
                    try await measure("large_diff_summary", samples: samples) {
                        guard case .deferred = try await service.readDiff(path: large, layer: .unstaged)
                        else { throw ModelFailure.changed }
                    })
                measurements.append(
                    try await measure("large_disk_diff_first_page", samples: samples) {
                        guard
                            case .disk(let snapshot) = try await service.readDiff(
                                path: large, layer: .unstaged, loadLarge: true)
                        else {
                            throw ModelFailure.changed
                        }
                        _ = try await snapshot.page()
                    })
                let snapshot = try await service.diskDiff(path: large, layer: .unstaged)
                let first = try await snapshot.page()
                guard let next = first.next else { throw ModelFailure.changed }
                measurements.append(
                    try await measure("existing_disk_snapshot_next_page", samples: samples) {
                        _ = try await snapshot.page(from: next)
                    })
                var latencies: [Double] = []
                for _ in 0..<samples {
                    let task = Task { try await service.diskDiff(path: large, layer: .unstaged) }
                    try await Task.sleep(for: .milliseconds(10))
                    let start = ContinuousClock.now
                    task.cancel()
                    do {
                        _ = try await task.value
                        completed += 1
                    } catch is CancellationError {
                        cancelled += 1
                        latencies.append(milliseconds(since: start))
                    } catch ProcessFailure.cancelled {
                        cancelled += 1
                        latencies.append(milliseconds(since: start))
                    }
                }
                if !latencies.isEmpty {
                    measurements.append(
                        Measurement(
                            name: "large_diff_cancellation", firstRunMs: latencies[0], samplesMs: latencies))
                }
            }
            let featureMeasurements = try await measureFeatureReads(engine: engine, samples: samples)
            measurements += featureMeasurements
            let featureBudgetPassed = featureMeasurements.allSatisfy { $0.p95Ms < 2000 }
            var usage = rusage()
            var children = rusage()
            getrusage(RUSAGE_SELF, &usage)
            getrusage(RUSAGE_CHILDREN, &children)
            let report = Report(
                measuredAt: Date(), fixture: manifest, sourceDigest: digest,
                system: ProcessInfo.processInfo.operatingSystemVersionString, git: version,
                conditions:
                    "Release; serial samples; warm filesystem cache after fixture creation; firstRun is the first measured call, not a cold OS cache; no SwiftUI rendering or UI cache; no network",
                measurements: measurements, backendPeakMiB: Double(usage.ru_maxrss) / 1_048_576,
                childPeakMiB: Double(children.ru_maxrss) / 1_048_576,
                cancelledOperations: cancelled, completedBeforeCancellation: completed,
                featureFixture: ["denseCommits": 5000, "tags": 1000, "remotes": 4, "stashRecords": 20],
                featureReadBudgetMs: 2000, featureReadBudgetPassed: featureBudgetPassed)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: output, options: .withoutOverwriting)
            print("Saved report: \(output.path)")
            guard featureBudgetPassed else {
                throw ModelFailure.unsupported(
                    "Feature read p95 exceeded the 2000 ms budget; retained the report.")
            }
        #endif
    }

    private static func measureFeatureReads(engine: GitEngine, samples: Int) async throws -> [Measurement] {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitFeatureBenchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        @discardableResult func git(_ args: [String], input: Data? = nil) async throws -> String {
            let value = try await engine.run(args, in: root, input: input, timeout: 120).text
            return value.hasSuffix("\n") ? String(value.dropLast()) : value
        }
        try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "WeGit Benchmark"), ("user.email", "benchmark@example.invalid"),
            ("commit.gpgsign", "false"), ("tag.gpgsign", "false"),
            ("core.hooksPath", root.appending(path: ".git/no-hooks").path),
        ] {
            try await git(["config", key, value])
        }
        var stream = ""
        for index in 1...5000 {
            let message = "Dense commit \(index)"
            let text = "Value \(index)\n"
            stream +=
                "commit refs/heads/main\ncommitter Benchmark <benchmark@example.invalid> \(1_700_000_000 + index) +0000\ndata \(message.utf8.count)\n\(message)\nM 100644 inline file.txt\ndata \(text.utf8.count)\n\(text)\n"
        }
        try await git(["fast-import", "--quiet"], input: Data(stream.utf8))
        try await git(["reset", "--hard", "HEAD"])
        let head = try await git(["rev-parse", "HEAD"])
        let tree = try await git(["rev-parse", "HEAD^{tree}"])
        let tags = (0..<1000).map { "create refs/tags/releases/\($0) \(head)\n" }.joined()
        try await git(["update-ref", "--stdin"], input: Data(tags.utf8))
        for index in 0..<4 {
            try await git([
                "remote", "add", "remote-\(index)", root.appending(path: ".git/bare-\(index)").path,
            ])
        }
        let indexCommit = try await git(
            ["commit-tree", tree, "-p", head], input: Data("Index fixture\n".utf8))
        for index in 0..<20 {
            let working = try await git(
                ["commit-tree", tree, "-p", head, "-p", indexCommit],
                input: Data("Working fixture \(index)\n".utf8))
            try await git(["stash", "store", "-m", "Read fixture \(index)", working])
        }
        let location = try await RepositoryService.discover(root, engine: engine)
        let service = RepositoryService(location: location, engine: engine)
        guard try await service.tags(limit: 2000).entries.count == 1000,
            try await service.stashes().entries.count == 20,
            try await service.remoteManagement().remotes.count == 4
        else { throw ModelFailure.changed }
        var values: [Measurement] = []
        values.append(
            try await measure("v1_1_stash_list_20", samples: samples) { _ = try await service.stashes() })
        values.append(
            try await measure("v1_1_remote_configuration_4", samples: samples) {
                _ = try await service.remoteManagement()
            })
        values.append(
            try await measure("v1_1_tag_list_1000", samples: samples) { _ = try await service.tags() })
        values.append(
            try await measure("v1_1_file_history_5000_first_query", samples: samples) {
                let anchor = try await service.fileHistoryAnchor(FileHistoryQuery(path: "file.txt"))
                guard try await service.fileHistoryPage(anchor).entries.count == 100 else {
                    throw ModelFailure.changed
                }
            })
        try FileManager.default.removeItem(at: root)
        return values
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    private static func measure(_ name: String, samples: Int, operation: () async throws -> Void) async throws
        -> Measurement
    {
        var times: [Double] = []
        let first = ContinuousClock.now
        try await operation()
        let firstRun = milliseconds(since: first)
        for index in 0..<samples {
            let start = ContinuousClock.now
            try await operation()
            times.append(milliseconds(since: start))
            if (index + 1).isMultiple(of: 10) { print("\(name): \(index + 1)/\(samples)") }
        }
        let result = Measurement(name: name, firstRunMs: firstRun, samplesMs: times)
        print(String(format: "%@: median %.2f ms, P95 %.2f ms", name, result.medianMs, result.p95Ms))
        return result
    }

    private static func sourceDigest(_ root: URL) throws -> String {
        var paths: [URL] = [root.appending(path: "Package.swift"), root.appending(path: "project.yml")]
        for directory in ["WeGitCore", "WeGit", "WeGitAskPass", "Benchmarks"] {
            let base = root.appending(path: directory)
            if let enumerator = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [.isRegularFileKey])
            {
                for case let url as URL in enumerator where url.pathExtension == "swift" { paths.append(url) }
            }
        }
        var hash = SHA256()
        for path in paths.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data(path.path.replacingOccurrences(of: root.path + "/", with: "").utf8))
            hash.update(data: try Data(contentsOf: path))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
