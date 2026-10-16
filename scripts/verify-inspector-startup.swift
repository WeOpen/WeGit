import CryptoKit
import Darwin
import Foundation

// Run serially in an interactive login session after scripts/build.sh Debug.
// This checks restored-startup survival; InspectorRestorationTests checks UI behavior.
func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws
    -> (Int32, String)
{
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw NSError(
            domain: "WeGit.StartupRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func persistenceID(_ root: URL) throws -> String {
    let parts = try [root, root.appending(path: ".git")].map { url in
        var info = stat()
        try require(lstat(url.path, &info) == 0, "Could not read fixture identity")
        return
            "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }
    return sha256(Data(parts.joined(separator: "|").utf8))
}

func main() throws {
    let arguments = CommandLine.arguments
    try require(
        arguments.count == 3, "Usage: swift scripts/verify-inspector-startup.swift <Debug.app> <report.json>")
    let app = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    let manager = FileManager.default
    let receipt = try Data(contentsOf: app.appending(path: "Contents/Resources/build-source.json"))
    let build = try JSONSerialization.jsonObject(with: receipt) as! [String: Any]
    try require(
        build["configuration"] as? String == "Debug", "Only a Debug build supports isolated preferences")
    let info =
        try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appending(path: "Contents/Info.plist")), format: nil) as! [String: Any]
    let bundleID = info["CFBundleIdentifier"] as! String
    let existing = try run("/usr/bin/pgrep", ["-x", "WeGit"])
    try require(existing.0 == 1, "Quit WeGit and stop native UI tests before running this serial regression")
    try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let root = manager.temporaryDirectory.appending(path: "WeGitInspectorStartup-" + UUID().uuidString)
    try manager.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: root) }
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    let gitResult = try run("/usr/bin/xcrun", ["--find", "git"])
    try require(gitResult.0 == 0, gitResult.1)
    let git = gitResult.1.trimmingCharacters(in: .whitespacesAndNewlines)
    func fixtureGit(_ arguments: [String]) throws -> String {
        let result = try run(git, ["-C", root.path] + arguments, environment: environment)
        try require(result.0 == 0, result.1)
        return result.1
    }
    _ = try fixtureGit(["init", "-b", "main"])
    _ = try fixtureGit(["config", "user.name", "Startup Fixture"])
    _ = try fixtureGit(["config", "user.email", "startup@example.invalid"])
    _ = try fixtureGit(["config", "commit.gpgsign", "false"])
    let file = root.appending(path: "Inspector.swift")
    try Data("let inspector = 1\n".utf8).write(to: file)
    _ = try fixtureGit(["add", "."])
    _ = try fixtureGit(["commit", "-m", "Inspector startup fixture"])
    try Data("let inspector = 2\n".utf8).write(to: file)
    let beforeHead = try fixtureGit(["rev-parse", "HEAD"])
    let beforeStatus = try fixtureGit(["status", "--porcelain=v1"])
    let beforeIndex = try Data(contentsOf: root.appending(path: ".git/index"))
    let key = "workspace:" + (try persistenceID(root))
    let suite = "com.willxue.wegit.UITests"
    let defaults = UserDefaults(suiteName: suite)!
    let saved = defaults.persistentDomain(forName: suite)
    let native = UserDefaults(suiteName: bundleID)!
    func windowKey(_ key: String) -> Bool {
        key.hasPrefix("NSWindow Frame ") || key.hasPrefix("NSSplitView Subview Frames ")
    }
    let originalWindow = (native.persistentDomain(forName: bundleID) ?? [:]).filter { windowKey($0.key) }
    func restorePreferences() {
        if let saved {
            defaults.setPersistentDomain(saved, forName: suite)
        } else {
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.synchronize()
        native.synchronize()
        let current = native.persistentDomain(forName: bundleID) ?? [:]
        for key in current.keys where windowKey(key) && originalWindow[key] == nil {
            native.removeObject(forKey: key)
        }
        for (key, value) in originalWindow { native.set(value, forKey: key) }
        native.synchronize()
    }
    defer { restorePreferences() }
    environment["WEGIT_UI_TEST_REPOSITORY"] = root.path
    var cases: [[String: Any]] = []
    for appearance in ["light", "dark"] {
        for (route, name) in [("提交历史", "history"), ("更改", "changes"), ("分支", "branches")] {
            let view: [String: Any] = [
                "route": route, "selectedFile": "unstaged|Inspector.swift", "inspector": true,
                "filter": "", "branchFilter": "", "splitDiff": true, "wordDiff": false,
                "contextLines": 3, "ignoreWhitespace": false, "changeFilter": "all",
            ]
            let seed = try JSONSerialization.data(withJSONObject: view, options: [.sortedKeys])
            defaults.setPersistentDomain(
                [
                    key: seed, "appearance": appearance, "language": "zh-Hans", "gitExecutable": git,
                    "restoreWindow": true,
                ],
                forName: suite)
            defaults.synchronize()
            let log = output.deletingLastPathComponent().appending(path: "startup-\(name)-\(appearance).log")
            manager.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = app.appending(path: "Contents/MacOS/WeGit")
            process.arguments = [
                "--uitesting", "--uitesting-keep-preferences", "--uitesting-window-state", UUID().uuidString,
            ]
            process.environment = environment
            process.standardOutput = handle
            process.standardError = handle
            let start = Date()
            try process.run()
            while process.isRunning && Date().timeIntervalSince(start) < 10 {
                Thread.sleep(forTimeInterval: 0.1)
            }
            let survived = process.isRunning
            if survived { process.terminate() }
            process.waitUntilExit()
            try handle.close()
            defaults.synchronize()
            let restoredData = defaults.data(forKey: key)
            let restored = try restoredData.map {
                try JSONSerialization.jsonObject(with: $0) as! [String: Any]
            }
            let preserved = restored?["route"] as? String == route && restored?["inspector"] as? Bool == true
            cases.append([
                "route": route, "appearance": appearance, "inspector": true,
                "survivedSeconds": Date().timeIntervalSince(start), "survived": survived,
                "savedStatePreserved": preserved, "terminationStatusAfterCleanup": process.terminationStatus,
                "log": log.lastPathComponent,
            ])
            print("\(name)/\(appearance): \(survived && preserved ? "PASS" : "FAIL")")
            fflush(stdout)
        }
    }
    let afterStatus = try fixtureGit(["status", "--porcelain=v1"])
    let intact =
        try fixtureGit(["rev-parse", "HEAD"]) == beforeHead && afterStatus == beforeStatus
        && Data(contentsOf: file) == Data("let inspector = 2\n".utf8)
    let afterIndex = try Data(contentsOf: root.appending(path: ".git/index"))
    restorePreferences()
    let windowRestored = NSDictionary(dictionary: originalWindow).isEqual(
        to: (native.persistentDomain(forName: bundleID) ?? [:]).filter { windowKey($0.key) })
    let suiteRestored = NSDictionary(dictionary: defaults.persistentDomain(forName: suite) ?? [:]).isEqual(
        to: saved ?? [:])
    let report: [String: Any] = [
        "date": ISO8601DateFormatter().string(from: Date()), "app": app.path,
        "buildReceiptSHA256": sha256(receipt), "applicationSourceFiles": build["sourceFiles"]!,
        "scriptSHA256": sha256(try Data(contentsOf: URL(fileURLWithPath: arguments[0]))),
        "fixture": "Private committed repository with one unstaged Swift file",
        "gitVersion": try fixtureGit(["--version"]).trimmingCharacters(in: .whitespacesAndNewlines),
        "fixtureDataIntact": intact, "fixtureIndexBytesUnchanged": beforeIndex == afterIndex,
        "preferencesRestored": suiteRestored && windowRestored, "cases": cases,
        "scope":
            "Restored-startup liveness and persisted state; native interaction assertions remain separate",
        "passed": intact && suiteRestored && windowRestored
            && cases.allSatisfy {
                $0["survived"] as? Bool == true && $0["savedStatePreserved"] as? Bool == true
            },
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
        to: output)
    try require(report["passed"] as? Bool == true, "Startup regression failed; inspect \(output.path)")
}

do { try main() } catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
