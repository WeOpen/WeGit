import Darwin
import Foundation
import WeGitCore

@main struct ProcessSignalDiagnostics {
    private enum Failure: Error { case assertion(String) }

    static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let helper = base.appending(path: "signal-probe")
        let runner = ProcessRunner()
        let script = base.appending(path: "wrapper.sh")
        let source = """
            #!/bin/sh
            "$WEGIT_SIGNAL_HELPER" snapshot "$WEGIT_SIGNAL_REPORT"
            if [ "$WEGIT_SIGNAL_HELPER_CHILD" = "1" ]; then
              "$WEGIT_SIGNAL_HELPER" sleep "$WEGIT_SIGNAL_CHILD_REPORT" "$WEGIT_SIGNAL_CHILD_READY" &
            else
              /bin/sleep 30 &
            fi
            child=$!
            trap 'printf term > "$WEGIT_SIGNAL_TRAP"; wait "$child" 2>/dev/null; exit 143' TERM INT
            printf '%s\\n%s\\n' "$$" "$child" > "$WEGIT_SIGNAL_READY"
            wait "$child"
            exit $?
            """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var records: [[String: Any]] = []
        let clock = ContinuousClock()
        for kind in ["direct-exec-sleep", "shell-sleep", "shell-helper-exec-sleep"] {
            for iteration in 1...3 {
                let prefix = kind + "-" + String(iteration)
                let report = base.appending(path: prefix + ".json")
                let childReport = base.appending(path: prefix + "-child.json")
                let ready = base.appending(path: prefix + ".ready")
                let trapped = base.appending(path: prefix + ".trap")
                let childReady = base.appending(path: prefix + "-child.ready")
                var environment = ProcessInfo.processInfo.environment
                environment["WEGIT_SIGNAL_HELPER"] = helper.path
                environment["WEGIT_SIGNAL_HELPER_CHILD"] = kind == "shell-helper-exec-sleep" ? "1" : "0"
                environment["WEGIT_SIGNAL_REPORT"] = report.path
                environment["WEGIT_SIGNAL_CHILD_REPORT"] = childReport.path
                environment["WEGIT_SIGNAL_CHILD_READY"] = childReady.path
                environment["WEGIT_SIGNAL_TRAP"] = trapped.path
                environment["WEGIT_SIGNAL_READY"] = ready.path
                let request = ProcessRequest(
                    executable: kind == "direct-exec-sleep" ? helper : script,
                    arguments: kind == "direct-exec-sleep" ? ["sleep", report.path, ready.path] : [],
                    environment: environment, timeout: 5)
                let task = Task { try await runner.run(request) }
                let deadline = clock.now.advanced(by: .seconds(2))
                while (!FileManager.default.fileExists(atPath: ready.path)
                    || (kind == "shell-helper-exec-sleep" && !FileManager.default.fileExists(atPath: childReady.path))), clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard FileManager.default.fileExists(atPath: ready.path) else {
                    task.cancel()
                    _ = await task.result
                    throw Failure.assertion("No executing process marker: " + prefix)
                }
                let ids = try String(contentsOf: ready, encoding: .utf8)
                    .split(separator: "\n").compactMap { Int32($0) }
                guard let pid = ids.first, ids.allSatisfy({ Darwin.kill($0, 0) == 0 }) else {
                    task.cancel()
                    _ = await task.result
                    throw Failure.assertion("Marker did not identify live processes: " + prefix)
                }
                let started = clock.now
                task.cancel()
                let result = await task.result
                let duration = started.duration(to: clock.now).components
                let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
                guard case .failure(let error) = result,
                    (error as? ProcessFailure).map({ if case .cancelled = $0 { true } else { false } }) == true
                else { throw Failure.assertion("Cancellation outcome changed: " + prefix) }
                let groupGone = Darwin.kill(-pid, 0) == -1 && errno == ESRCH
                guard groupGone else { throw Failure.assertion("Live process group after return: " + prefix) }
                let recovery = try await runner.run(
                    ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []))
                guard recovery.exitCode == 0 else { throw Failure.assertion("Capacity did not recover") }
                var item: [String: Any] = [
                    "kind": kind, "iteration": iteration, "cancelMilliseconds": milliseconds,
                    "signalState": try JSONSerialization.jsonObject(with: Data(contentsOf: report)),
                    "executingPids": ids, "processGroupGone": groupGone, "capacityRecovered": true,
                    "trapObserved": FileManager.default.fileExists(atPath: trapped.path),
                ]
                if FileManager.default.fileExists(atPath: childReport.path) {
                    item["childSignalState"] = try JSONSerialization.jsonObject(with: Data(contentsOf: childReport))
                }
                records.append(item)
                print(prefix + ": " + String(milliseconds) + " ms")
            }
        }
        let result: [String: Any] = [
            "scope": "Private diagnostic of actual ProcessRunner execution and cancellation. Child signal queries are read-only. Parent signal state is unchanged. Not XCTest or a Git workload benchmark.",
            "samples": records,
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: base.appending(path: "result.json"), options: .atomic)
    }
}
