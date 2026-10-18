import AppKit
import XCTest

final class AsyncSceneControlUITests: XCTestCase {
    @MainActor func testFirstWindowIsPresented() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["--uitesting", "-language", "zh-Hans"]
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let bundle = Bundle(for: Self.self)
        let identifier = try XCTUnwrap(
            bundle.object(forInfoDictionaryKey: "ControlAppBundleIdentifier") as? String)
        #if WORKSPACE_LAUNCH
            let path = try XCTUnwrap(
                bundle.object(forInfoDictionaryKey: "ControlAppProductURL") as? String)
            let applicationURL = URL(fileURLWithPath: path)
            XCTAssertEqual(Bundle(url: applicationURL)?.bundleIdentifier, identifier)
            XCTAssertTrue(identifier.hasPrefix("com.willxue.wegit.scenecontrol."))
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = app.launchArguments
            configuration.environment = app.launchEnvironment
            configuration.activates = true
            configuration.addsToRecentItems = false
            configuration.allowsRunningApplicationSubstitution = false
            let running = try await NSWorkspace.shared.openApplication(
                at: applicationURL, configuration: configuration)
            XCTAssertEqual(running.bundleIdentifier, identifier)
        #else
            app.launch()
        #endif
        app.activate()
        let argumentsReceived = expectedArgumentsReceived(identifier: identifier)
        let ready = app.staticTexts["control-ready"].waitForExistence(timeout: 10)
        if !ready {
            XCTContext.runActivity(named: "Async scene startup evidence") { activity in
                let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                let metadata = applications.map {
                    "pid=\($0.processIdentifier) active=\($0.isActive) hidden=\($0.isHidden) "
                        + "finishedLaunching=\($0.isFinishedLaunching) policy=\($0.activationPolicy.rawValue)"
                }.joined(separator: "\n")
                let state = XCTAttachment(
                    string: metadata + "\nargumentsReceived=\(argumentsReceived)\n" + app.debugDescription)
                state.name = "Async scene startup state"
                state.lifetime = .keepAlways
                activity.add(state)
                let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screen.name = "Async scene startup desktop"
                screen.lifetime = .keepAlways
                activity.add(screen)
            }
        }
        XCTAssertTrue(ready, "The plain scene must appear after the selected launch route.")
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(argumentsReceived, "The launch route must preserve the requested isolation arguments.")
    }

    @MainActor private func expectedArgumentsReceived(identifier: String) -> Bool {
        let targets = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        guard targets.count == 1, let target = targets.first else { return false }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-p", String(target.processIdentifier), "-o", "args="]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return process.terminationStatus == 0 && text.contains("--uitesting")
                && text.contains("-language zh-Hans")
        } catch { return false }
    }
}
