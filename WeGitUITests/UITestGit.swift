import AppKit
import XCTest

extension XCUIApplication {
    @MainActor func launchWeGit() {
        if !launchArguments.contains("-language") { launchArguments += ["-language", "zh-Hans"] }
        launch()
        activate()
        let menuReady = menuBars.menuBarItems["native-menu-app"].waitForExistence(timeout: 5)
        if !menuReady {
            XCTContext.runActivity(named: "Startup failure evidence") { activity in
                let applications = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.willxue.wegit.development")
                let metadata = applications.map {
                    "pid=\($0.processIdentifier) active=\($0.isActive) hidden=\($0.isHidden) "
                        + "finishedLaunching=\($0.isFinishedLaunching) policy=\($0.activationPolicy.rawValue)"
                }.joined(separator: "\n")
                let state = XCTAttachment(string: metadata + "\n" + debugDescription)
                state.name = "Application startup state"
                state.lifetime = .keepAlways
                activity.add(state)
                if let application = applications.first {
                    let sampleFile = FileManager.default.temporaryDirectory.appending(
                        path: "WeGitStartupSample-\(UUID().uuidString).txt")
                    defer { try? FileManager.default.removeItem(at: sampleFile) }
                    let sampler = Process()
                    let output = Pipe()
                    sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    sampler.arguments = [
                        String(application.processIdentifier), "1", "1", "-file", sampleFile.path,
                    ]
                    sampler.standardOutput = output
                    sampler.standardError = output
                    if (try? sampler.run()) != nil {
                        let diagnostic = output.fileHandleForReading.readDataToEndOfFile()
                        sampler.waitUntilExit()
                        let text =
                            (try? String(contentsOf: sampleFile, encoding: .utf8))
                            ?? String(decoding: diagnostic, as: UTF8.self)
                        let sample = XCTAttachment(string: text)
                        sample.name = "Application startup thread sample"
                        sample.lifetime = .keepAlways
                        activity.add(sample)
                    }
                }
                let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screen.name = "Startup desktop"
                screen.lifetime = .keepAlways
                activity.add(screen)
            }
        }
        XCTAssertTrue(menuReady)
        if !windows["main"].waitForExistence(timeout: 2) {
            XCTContext.runActivity(named: "Reopen the main window from its native menu") { _ in
                menuBars.menuBarItems["native-menu-window"].click()
                menuItems["native-command-showMainWindow"].click()
            }
        }
    }
}

struct UITestGit {
    @MainActor static func preservingClipboard(_ action: (NSPasteboard) -> Void) {
        let clipboard = NSPasteboard.general
        let saved =
            clipboard.pasteboardItems?.map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            } ?? []
        defer {
            clipboard.clearContents()
            clipboard.writeObjects(
                saved.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                })
        }
        action(clipboard)
    }

    private static let executable: Result<URL, any Error> = Result {
        let resolver = Process()
        let output = Pipe()
        resolver.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        resolver.arguments = ["--find", "git"]
        resolver.standardOutput = output
        resolver.standardError = output
        try resolver.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        resolver.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolver.terminationStatus == 0, path.hasPrefix("/"),
            FileManager.default.isExecutableFile(atPath: path)
        else {
            throw NSError(
                domain: "WeGitUITests.Toolchain", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve Git from the selected Xcode."])
        }
        return URL(fileURLWithPath: path)
    }
    private static let environment: [String: String] = {
        var value = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        value["GIT_CONFIG_GLOBAL"] = "/dev/null"
        value["GIT_CONFIG_SYSTEM"] = "/dev/null"
        value["GIT_TERMINAL_PROMPT"] = "0"
        value["PATH"] = "/usr/bin:/bin"
        value["LC_ALL"] = "C"
        return value
    }()

    // XCUITest uses the actual Xcode binary, avoiding /usr/bin/git's xcrun shim.
    // Verify its isolation support before any fixture command, without changing HOME.
    private static let isolation: Result<Void, any Error> = Result {
        let root = FileManager.default.temporaryDirectory.appending(path: "WeGitUIProbe-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appending(path: "global")
        let system = root.appending(path: "system")
        let key = "probe" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try Data("[wegitisolation]\n\(key) = global\n".utf8).write(to: global)
        try Data("[wegitisolation]\n\(key) = system\n".utf8).write(to: system)
        var isolated = environment
        isolated["GIT_CONFIG_GLOBAL"] = global.path
        isolated["GIT_CONFIG_SYSTEM"] = system.path
        isolated["GIT_CONFIG_COUNT"] = "1"
        isolated["GIT_CONFIG_KEY_0"] = "wegitisolation." + key
        isolated["GIT_CONFIG_VALUE_0"] = "runtime"
        let result = try execute(
            ["config", "--get-all", "wegitisolation." + key], in: root, environment: isolated)
        guard result == "system\nglobal\nruntime\n" else {
            throw NSError(
                domain: "WeGitUITests.Isolation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Git ignored the UI fixture's isolated configuration."])
        }
    }

    let root: URL
    init(prefix: String) throws {
        try Self.isolation.get()
        root = FileManager.default.temporaryDirectory.appending(path: prefix + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func git(_ arguments: [String], input: String? = nil) throws -> String {
        try Self.run(arguments, in: root, input: input)
    }

    @discardableResult
    static func run(_ arguments: [String], in root: URL, input: String? = nil) throws -> String {
        try isolation.get()
        if arguments.first == "config",
            arguments.dropFirst().prefix(while: { $0 != "--" }).contains(where: {
                ["--global", "--system"].contains($0)
            })
        {
            throw NSError(
                domain: "WeGitUITests.Isolation", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "UI fixtures may only edit repository-local configuration."
                ])
        }
        return try execute(arguments, in: root, environment: environment, input: input)
    }

    private static func execute(
        _ arguments: [String], in root: URL, environment: [String: String], input: String? = nil
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = try executable.get()
        process.arguments = ["-C", root.path] + arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        var handle: FileHandle?
        var inputFile: URL?
        if let input {
            let path = root.appending(path: ".git/ui-input-" + UUID().uuidString)
            try Data(input.utf8).write(to: path)
            handle = try FileHandle(forReadingFrom: path)
            inputFile = path
            process.standardInput = handle
        }
        defer {
            try? handle?.close()
            if let inputFile { try? FileManager.default.removeItem(at: inputFile) }
        }
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "WeGitUITests.Git", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: bytes, as: UTF8.self)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
