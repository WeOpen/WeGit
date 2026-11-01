import CryptoKit
import Darwin
import Foundation
import WeGitCore

@main struct SubmoduleLFSPerformance {
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
        let initializedSubmodules: Int
        let lfsObjects: Int
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
    struct Resources: Sendable {
        let modules: [SubmoduleStatus]
        let objects: [LFSObjectStatus]
    }
    enum Failure: Error { case assertion(String) }
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure.assertion(message) }
    }
    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    static func p95(_ values: [Double]) -> Double {
        values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1]
    }
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func read(_ service: RepositoryService) async throws -> Resources {
        let modules = try await service.submodules()
        let objects = try await service.lfsObjects()
        return Resources(modules: modules, objects: objects)
    }
    static func inputs(_ root: URL) throws -> [String: String] {
        var paths = [
            "Package.swift", "scripts/SubmoduleLFSPerformance.swift",
            "scripts/verify-submodule-lfs-performance.sh",
        ]
        let enumerator = FileManager.default.enumerator(
            at: root.appending(path: "WeGitCore"), includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in enumerator
        where ["swift", "strings", "stringsdict"].contains(url.pathExtension) {
            paths.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return try Dictionary(
            uniqueKeysWithValues: paths.map { path in
                (
                    path,
                    SHA256.hash(data: try Data(contentsOf: root.appending(path: path))).map {
                        String(format: "%02x", $0)
                    }.joined()
                )
            })
    }
    static func cancelRead(_ service: RepositoryService, ready: URL) async throws -> (Double, pid_t, pid_t) {
        let task = Task { try await read(service) }
        let clock = ContinuousClock()
        do {
            let deadline = clock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: ready.path), clock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try require(
                FileManager.default.fileExists(atPath: ready.path),
                "read never reached cancellation readiness")
            let pids = try String(contentsOf: ready, encoding: .utf8).split(whereSeparator: \.isWhitespace)
                .compactMap { pid_t($0) }
            try require(
                pids.count == 2 && pids.allSatisfy { $0 > 0 && kill($0, 0) == 0 },
                "read cancellation requires two live processes")
            let start = clock.now
            task.cancel()
            do {
                _ = try await task.value
                throw Failure.assertion("cancelled read succeeded")
            } catch ProcessFailure.cancelled {} catch is CancellationError {}
            while kill(-pids[0], 0) == 0, clock.now < start.advanced(by: .seconds(2)) {
                try await Task.sleep(for: .milliseconds(5))
            }
            try require(kill(-pids[0], 0) == -1 && errno == ESRCH, "cancelled read group remains alive")
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
        let hashes = try inputs(source)
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitResourcePerformance-\(UUID())")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var finished = false
        defer { if finished { try? FileManager.default.removeItem(at: root) } }
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
        var reports: [Workload] = []
        var activeSamples: [Sample] = []
        var activeName = ""
        var phase = "fixture"
        var failure: String?
        do {
            let childSource = root.appending(path: "child-source")
            try FileManager.default.createDirectory(at: childSource, withIntermediateDirectories: false)
            _ = try await engine.run(["init", "-b", "main"], in: childSource)
            for (key, value) in [
                ("user.name", "Resource Performance"), ("user.email", "fixture@example.invalid"),
                ("commit.gpgsign", "false"), ("gc.auto", "0"), ("maintenance.auto", "false"),
            ] {
                _ = try await engine.run(["config", key, value], in: childSource)
            }
            try Data("child\n".utf8).write(to: childSource.appending(path: "file.txt"))
            _ = try await engine.run(["add", "."], in: childSource)
            _ = try await engine.run(["commit", "-m", "Child source"], in: childSource)
            for (name, files, modules, objectCount, storage, memory) in [
                ("ordinary", 10, 1, 2, "loose", 256 * 1024 * 1024),
                ("large-loose", 5000, 5, 32, "loose", 512 * 1024 * 1024),
                ("large-packed", 5000, 5, 32, "packed", 512 * 1024 * 1024),
            ] {
                activeName = name
                activeSamples = []
                phase = "fixture.\(name)"
                let directory = root.appending(path: name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                @discardableResult func git(_ args: [String]) async throws -> String {
                    try await engine.run(args, in: directory).text.trimmingCharacters(in: .newlines)
                }
                try await git(["init", "-b", "main"])
                for (key, value) in [
                    ("user.name", "Resource Performance"), ("user.email", "fixture@example.invalid"),
                    ("commit.gpgsign", "false"), ("gc.auto", "0"), ("maintenance.auto", "false"),
                    ("core.hooksPath", root.appending(path: "no-hooks").path),
                ] {
                    try await git(["config", key, value])
                }
                for index in 0..<files {
                    try Data("ordinary \(index)\n".utf8).write(to: directory.appending(path: "file-\(index)"))
                }
                var payloads: [(path: String, oid: String, bytes: Data)] = []
                for index in 0..<objectCount {
                    let bytes = Data(repeating: UInt8(index), count: 64 * 1024)
                    let oid = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    let path = "payload-\(index).bin"
                    try Data(
                        "version https://git-lfs.github.com/spec/v1\noid sha256:\(oid)\nsize \(bytes.count)\n"
                            .utf8
                    ).write(to: directory.appending(path: path))
                    payloads.append((path, oid, bytes))
                }
                try await git(["add", "."])
                try await git(["commit", "-m", "Resource fixture"])
                for index in 0..<modules {
                    _ = try await engine.run(
                        ["submodule", "add", childSource.path, "modules/child-\(index)"], in: directory,
                        configuration: [("protocol.file.allow", "always")])
                }
                try await git(["commit", "-am", "Configured children"])
                if storage == "packed" { try await git(["gc", "--quiet"]) }
                try await git(["fsck", "--full", "--no-dangling"])
                let statistics = try await git(["count-objects", "-v"])
                let packs = statistics.split(separator: "\n").first(where: { $0.hasPrefix("packs: ") })
                    .flatMap { Int($0.dropFirst("packs: ".count)) }
                try require(
                    packs.map { storage == "packed" ? $0 > 0 : $0 == 0 } == true,
                    "declared object storage is absent")
                let location = try await RepositoryService.discover(directory, engine: engine)
                for payload in payloads {
                    let cache = location.commonDirectory.appending(
                        path: "lfs/objects/\(payload.oid.prefix(2))/\(payload.oid.dropFirst(2).prefix(2))")
                    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                    try payload.bytes.write(to: cache.appending(path: payload.oid))
                    try payload.bytes.write(to: directory.appending(path: payload.path))
                }
                let original = try await git(["rev-parse", "HEAD"])
                var childIndexes: [URL: Data] = [:]
                for index in 0..<modules {
                    let child = try await RepositoryService.discover(
                        directory.appending(path: "modules/child-\(index)"), engine: engine)
                    let path = child.gitDirectory.appending(path: "index")
                    childIndexes[path] = try Data(contentsOf: path)
                }
                let ready = location.gitDirectory.appending(path: "resource-performance-ready")
                let pending = ready.appendingPathExtension("pending")
                let wrapper = location.gitDirectory.appending(path: "resource-performance-git")
                let script = """
                    #!/bin/sh
                    matching=0
                    for word in "$@"; do test "$word" = ls-files && matching=1; done
                    if test "$matching" = 1; then
                      trap 'kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 143' TERM
                      /bin/sleep 30 &
                      child=$!
                      printf '%s %s\\n' "$$" "$child" > \(quote(pending.path)) || exit 1
                      /bin/mv \(quote(pending.path)) \(quote(ready.path)) || exit 1
                      wait "$child"
                    fi
                    exec \(quote(executable.path)) "$@"
                    """
                try Data(script.utf8).write(to: wrapper)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
                let delayed = GitEngine(executable: wrapper, environment: environment)
                for iteration in 0..<30 {
                    phase = "sample.\(name).\(iteration)"
                    let index = try Data(contentsOf: location.gitDirectory.appending(path: "index"))
                    let service = RepositoryService(location: location, engine: engine)
                    let clock = ContinuousClock()
                    var start = clock.now
                    let first = try await read(service)
                    let firstMs = milliseconds(start.duration(to: clock.now))
                    start = clock.now
                    let steady = try await read(service)
                    let steadyMs = milliseconds(start.duration(to: clock.now))
                    try require(
                        first.modules.count == modules && steady.modules == first.modules
                            && first.modules.allSatisfy { $0.state == .clean }, "invalid submodule sample")
                    try require(
                        first.objects.count == objectCount && steady.objects == first.objects
                            && first.objects.allSatisfy {
                                $0.objectAvailable && $0.workingTreeHydrated == true
                            }, "invalid LFS sample")
                    try? FileManager.default.removeItem(at: ready)
                    try? FileManager.default.removeItem(at: pending)
                    let cancellation = try await cancelRead(
                        RepositoryService(location: location, engine: delayed), ready: ready)
                    start = clock.now
                    let recovered = try await read(service)
                    let recoveredMs = milliseconds(start.duration(to: clock.now))
                    try require(
                        recovered.modules == first.modules && recovered.objects == first.objects,
                        "read did not recover after cancellation")
                    let final = try await git(["rev-parse", "HEAD"])
                    try require(
                        final == original
                            && Data(contentsOf: location.gitDirectory.appending(path: "index")) == index,
                        "read changed parent HEAD/index")
                    for (path, bytes) in childIndexes {
                        try require(try Data(contentsOf: path) == bytes, "read changed a child index")
                    }
                    let rss = try await ProcessRunner().run(
                        ProcessRequest(
                            executable: URL(fileURLWithPath: "/bin/ps"),
                            arguments: ["-o", "rss=", "-p", String(getpid())], environment: environment))
                    guard rss.exitCode == 0,
                        let kib = Int(rss.text.trimmingCharacters(in: .whitespacesAndNewlines)), kib > 0
                    else { throw Failure.assertion("invalid RSS") }
                    var usage = rusage()
                    try require(
                        getrusage(RUSAGE_SELF, &usage) == 0 && usage.ru_maxrss > 0,
                        "invalid resident high water")
                    activeSamples.append(
                        Sample(
                            iteration: iteration, firstMilliseconds: firstMs, steadyMilliseconds: steadyMs,
                            cancelMilliseconds: cancellation.0, recoveredMilliseconds: recoveredMs,
                            residentBytes: max(kib * 1024, Int(usage.ru_maxrss)), wrapperPID: cancellation.1,
                            childPID: cancellation.2))
                }
                let first = p95(activeSamples.map(\.firstMilliseconds))
                let steady = p95(activeSamples.map(\.steadyMilliseconds))
                let cancel = p95(activeSamples.map(\.cancelMilliseconds))
                let recovered = p95(activeSamples.map(\.recoveredMilliseconds))
                let resident = p95(activeSamples.map { Double($0.residentBytes) })
                let passed =
                    first <= 2000 && steady <= 2000 && recovered <= 2000 && cancel <= 500
                    && resident <= Double(memory)
                reports.append(
                    Workload(
                        name: name, trackedFiles: files, initializedSubmodules: modules,
                        lfsObjects: objectCount, objectStorage: storage, objectStatistics: statistics,
                        samples: activeSamples, p95First: first, p95Steady: steady, p95Cancel: cancel,
                        p95Recovered: recovered, p95ResidentBytes: resident, passed: passed))
                print(
                    "\(name): 30 valid Release samples; first \(first), steady \(steady), recovered \(recovered), cancel \(cancel)ms, RSS \(resident); passed=\(passed)"
                )
            }
        } catch { failure = String(describing: error) }
        let encoder = JSONEncoder()
        let allPassed = failure == nil && reports.count == 3 && reports.allSatisfy(\.passed)
        let report: [String: Any] = [
            "sourceRevision": revision, "workspaceDirty": dirty, "sourceFiles": hashes,
            "gitVersion": gitVersion, "configuration": "ordinary Release Core", "xctestExecuted": false,
            "samplesPerWorkload": 30,
            "budgets": [
                "firstMilliseconds": 2000, "steadyMilliseconds": 2000, "recoveredMilliseconds": 2000,
                "cancelMilliseconds": 500, "ordinaryResidentBytes": 256 * 1024 * 1024,
                "largeResidentBytes": 512 * 1024 * 1024,
            ],
            "workloads": try JSONSerialization.jsonObject(with: encoder.encode(reports)),
            "activeSamples": try JSONSerialization.jsonObject(with: encoder.encode(activeSamples)),
            "activeWorkload": activeName, "phase": phase, "allPassed": allPassed,
            "failure": failure as Any? ?? NSNull(), "fixture": root.path,
            "memoryProbe":
                "Maximum of current RSS and process lifetime resident high water; child Git RSS excluded",
            "cancellationProbe":
                "Live delay wrapper and child; entire group exit and a subsequent full real read required",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output)
        guard allPassed else {
            throw Failure.assertion(
                "resource read budgets or sample validity failed; complete and partial arrays retained")
        }
        finished = true
    }
}
