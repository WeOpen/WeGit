import AppKit
import XCTest

final class SceneControlUITests: XCTestCase {
    @MainActor func testFirstWindowIsPresented() throws {
        continueAfterFailure = false
        let display = CGMainDisplayID()
        let modes =
            CGDisplayCopyAllDisplayModes(
                display, [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary)
            as? [CGDisplayMode] ?? []
        func mode(_ value: CGDisplayMode) -> [String: Int] {
            [
                "width": value.width, "height": value.height,
                "pixelWidth": value.pixelWidth, "pixelHeight": value.pixelHeight,
            ]
        }
        let displayReport: [String: Any] = [
            "readOnly": true,
            "currentMode": CGDisplayCopyDisplayMode(display).map(mode) ?? [:],
            "availableModes": modes.map(mode),
            "screens": NSScreen.screens.map {
                ["frame": NSStringFromRect($0.frame), "visibleFrame": NSStringFromRect($0.visibleFrame)]
            },
        ]
        let receipt = XCTAttachment(
            data: try JSONSerialization.data(
                withJSONObject: displayReport, options: [.prettyPrinted, .sortedKeys]),
            uniformTypeIdentifier: "public.json")
        receipt.name = "Read-only display modes"
        receipt.lifetime = .keepAlways
        add(receipt)
        let app = XCUIApplication()
        defer { app.terminate() }
        #if DEFAULT_CONTROL_ARGUMENTS
            // Keep XCTest's default launch arguments for the baseline.
        #elseif MARKER_CONTROL_ARGUMENTS
            app.launchArguments = ["--uitesting"]
        #elseif LANGUAGE_CONTROL_ARGUMENTS
            app.launchArguments = ["-language", "zh-Hans"]
        #elseif REORDERED_CONTROL_ARGUMENTS
            app.launchArguments = ["-language", "zh-Hans", "--uitesting"]
        #elseif APPLE_LANGUAGE_CONTROL_ARGUMENTS
            app.launchArguments = ["--uitesting", "-AppleLanguages", "(zh-Hans)"]
        #else
            app.launchArguments = ["--uitesting", "-language", "zh-Hans"]
        #endif
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launch()
        app.activate()
        let ready = app.staticTexts["control-ready"].waitForExistence(timeout: 10)
        if !ready {
            XCTContext.runActivity(named: "Minimal scene startup evidence") { activity in
                let identifier =
                    Bundle(for: Self.self).object(
                        forInfoDictionaryKey: "ControlAppBundleIdentifier") as? String ?? ""
                let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                let state = applications.map {
                    "pid=\($0.processIdentifier) active=\($0.isActive) hidden=\($0.isHidden) "
                        + "finishedLaunching=\($0.isFinishedLaunching) policy=\($0.activationPolicy.rawValue)"
                }.joined(separator: "\n")
                let hierarchy = XCTAttachment(string: state + "\n" + app.debugDescription)
                hierarchy.name = "Scene startup state"
                hierarchy.lifetime = .keepAlways
                activity.add(hierarchy)
                let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screenshot.name = "Scene startup desktop"
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)
            }
        }
        XCTAssertTrue(ready, "The control must present its content after launch.")
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(app.windows.firstMatch.isHittable)
        XCTContext.runActivity(named: "Visible control window") { activity in
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Visible control window"
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
        }
    }
}
