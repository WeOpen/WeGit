import CryptoKit
import Darwin
import Foundation
import WeGitCore

private final class RecoveryMemorySampler: @unchecked Sendable {
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

@main struct RecoveryPerformance {
    struct Sample: Codable {
        let iteration: Int
        let previewMilliseconds: Double
        let resetMilliseconds: Double
        let restorePreviewMilliseconds: Double
        let restoreMilliseconds: Double
        let reflogMilliseconds: Double
        let cancelMilliseconds: Double
        let residentBytes: Int
        let backupBytes: Int
        let wrapperPID: Int32
        let childPID: Int32
    }
    struct Workload: Codable {
        let name: String
        let files: Int
        let bytes: Int
        let samples: [Sample]
        let p95: [String: Double]
        let passed: Bool
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
    static func cancellation(service: RepositoryService, marker: URL) async throws -> (Double, pid_t, pid_t) {
        try? FileManager.default.removeItem(at: marker)
        let clock = ContinuousClock()
        let task = Task { try await service.reflog() }
        do {
            let deadline = clock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: marker.path), clock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let pids = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isWhitespace)
                .compactMap { pid_t($0) }
            try require(
                pids.count == 2 && pids.allSatisfy { $0 > 0 && kill($0, 0) == 0 },
                "Cancellation requires live wrapper and child")
            let start = clock.now
            task.cancel()
            do {
                _ = try await task.value
                throw Failure.assertion("Cancelled reflog succeeded")
            } catch ProcessFailure.cancelled {} catch is CancellationError {}
            while kill(-pids[0], 0) == 0, clock.now < start.advanced(by: .seconds(2)) {
                try await Task.sleep(for: .milliseconds(5))
            }
            try require(kill(-pids[0], 0) == -1 && errno == ESRCH, "Cancelled process group remains alive")
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
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitRecoveryPerformance-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let git = URL(fileURLWithPath: environment["WEGIT_TEST_GIT"] ?? "/usr/bin/git")
        let engine = GitEngine(executable: git, environment: environment)
        let revision = try await engine.run(["rev-parse", "HEAD"], in: source).text.trimmingCharacters(
            in: .newlines)
        var reports: [Workload] = []
        var active: [Sample] = []
        var phase = "fixture"
        var activeName = ""
        var failure: String?
        do {
            for (name, fileCount, volume, memory) in [
                ("ordinary", 100, 16 * 1024 * 1024, 256 * 1024 * 1024),
                ("large", 1000, 256 * 1024 * 1024, 512 * 1024 * 1024),
            ] {
                active = []
                activeName = name
                let repository = root.appending(path: name)
                try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: false)
                @discardableResult func run(_ arguments: [String]) async throws -> Data {
                    try await engine.run(arguments, in: repository, timeout: 120).stdout
                }
                try await run(["init", "-b", "main"])
                for (key, value) in [
                    ("user.name", "Recovery Performance"), ("user.email", "fixture@example.invalid"),
                    ("commit.gpgsign", "false"), ("core.hooksPath", root.appending(path: "no-hooks").path),
                    ("core.autocrlf", "false"), ("gc.auto", "0"), ("maintenance.auto", "false"),
                ] { try await run(["config", key, value]) }
                let paths = (0..<fileCount).map { "file-\($0)" }
                // The 256 MiB backup budget includes its raw index as well as files.
                let size = (volume - fileCount * 256) / fileCount
                for path in paths {
                    try Data(repeating: 65, count: size).write(to: repository.appending(path: path))
                }
                try await run(["add", "."])
                try await run(["commit", "-m", "Target"])
                let target = String(decoding: try await run(["rev-parse", "HEAD"]), as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                for path in paths {
                    try Data(repeating: 66, count: size).write(to: repository.appending(path: path))
                }
                try await run(["commit", "-am", "Current"])
                let current = String(decoding: try await run(["rev-parse", "HEAD"]), as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                let location = try await RepositoryService.discover(repository, engine: engine)
                let wrapper = root.appending(path: name + "-git")
                let marker = root.appending(path: name + "-cancel-ready")
                let script = """
                    #!/bin/bash
                    set -eu
                    for argument in "$@"; do
                      if [[ "$argument" == reflog ]]; then
                        sleep 60 &
                        child_pid=$!
                        trap 'trap "" TERM INT; kill "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; exit 143' TERM INT
                        printf '%s %s\\n' "$$" "$child_pid" > \(quote(marker.path))
                        wait "$child_pid"
                      fi
                    done
                    exec \(quote(git.path)) "$@"
                    """
                try Data(script.utf8).write(to: wrapper)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
                let delayed = RepositoryService(
                    location: location, engine: GitEngine(executable: wrapper, environment: environment))
                for iteration in 1...30 {
                    phase = "prepare fixture"
                    try await run(["reset", "--hard", current])
                    let working = Data(repeating: 67, count: size)
                    for path in paths { try working.write(to: repository.appending(path: path)) }
                    try await run(
                        ["add", "--"] + paths.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
                    let originalIndex = try Data(contentsOf: location.gitDirectory.appending(path: "index"))
                    let service = RepositoryService(location: location, engine: engine)
                    let sampler = RecoveryMemorySampler()
                    let clock = ContinuousClock()
                    phase = "preview"
                    var start = clock.now
                    let plan = try await service.prepareReset(target: target, mode: .hard)
                    let preview = milliseconds(start.duration(to: clock.now))
                    phase = "reset"
                    start = clock.now
                    let record = try await service.executeReset(plan)
                    let reset = milliseconds(start.duration(to: clock.now))
                    phase = "restore preview"
                    start = clock.now
                    let restorePlan = try await service.prepareRecoveryRestore(record, layer: .both)
                    let restorePreview = milliseconds(start.duration(to: clock.now))
                    phase = "restore"
                    start = clock.now
                    _ = try await service.executeRecoveryRestore(restorePlan)
                    let restore = milliseconds(start.duration(to: clock.now))
                    phase = "reflog"
                    start = clock.now
                    let log = try await service.reflog()
                    let reflog = milliseconds(start.duration(to: clock.now))
                    try require(
                        !log.isEmpty && log.allSatisfy(\.objectExists), "Reflog lost existing objects")
                    try require(
                        try Data(contentsOf: location.gitDirectory.appending(path: "index")) == originalIndex,
                        "Restore changed original index bytes")
                    for path in paths {
                        try require(
                            try Data(contentsOf: repository.appending(path: path)) == working,
                            "Restore changed raw file bytes")
                    }
                    phase = "cancel"
                    let cancel = try await cancellation(service: delayed, marker: marker)
                    let resident = sampler.finish()
                    active.append(
                        Sample(
                            iteration: iteration, previewMilliseconds: preview, resetMilliseconds: reset,
                            restorePreviewMilliseconds: restorePreview, restoreMilliseconds: restore,
                            reflogMilliseconds: reflog, cancelMilliseconds: cancel.0, residentBytes: resident,
                            backupBytes: record.totalBytes, wrapperPID: cancel.1, childPID: cancel.2))
                    for value in try await service.recoveryRecords() {
                        try await service.removeRecoveryRecord(value)
                    }
                }
                let values = [
                    "preview": p95(active.map(\.previewMilliseconds)),
                    "reset": p95(active.map(\.resetMilliseconds)),
                    "restorePreview": p95(active.map(\.restorePreviewMilliseconds)),
                    "restore": p95(active.map(\.restoreMilliseconds)),
                    "reflog": p95(active.map(\.reflogMilliseconds)),
                    "cancel": p95(active.map(\.cancelMilliseconds)),
                    "residentBytes": p95(active.map { Double($0.residentBytes) }),
                ]
                let passed =
                    active.count == 30
                    && ["preview", "reset", "restorePreview", "restore", "reflog"].allSatisfy {
                        values[$0]! < 2000
                    }
                    && values["cancel"]! < 500 && values["residentBytes"]! > 0
                    && values["residentBytes"]! <= Double(memory)
                reports.append(
                    Workload(
                        name: name, files: fileCount, bytes: size * fileCount, samples: active, p95: values,
                        passed: passed))
                try require(passed, "Recovery performance budget exceeded: " + name)
            }
        } catch { failure = String(describing: error) }
        let report: [String: Any] = [
            "format": 1, "sourceCommit": revision,
            "diagnosticOnly": true,
            "scope":
                "Ordinary optimized Release CLI, first fresh service per sample; filesystem cache uncontrolled. Private repositories/configuration. Not UI, installation or complete version acceptance.",
            "requiredSamples": 30, "allPassed": failure == nil, "failure": failure as Any? ?? NSNull(),
            "phase": phase, "activeWorkload": activeName,
            "workloads": try JSONSerialization.jsonObject(with: JSONEncoder().encode(reports)),
            "incompleteSamples": failure == nil
                ? [] : try JSONSerialization.jsonObject(with: JSONEncoder().encode(active)),
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output, options: .atomic)
        if let failure {
            print("Recovery performance failed; fixture retained: \(root.path): \(failure)")
            exit(1)
        }
        try FileManager.default.removeItem(at: root)
    }
}
