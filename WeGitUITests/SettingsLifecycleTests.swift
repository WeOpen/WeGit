import AppKit
import Vision
import XCTest

final class SettingsLifecycleTests: XCTestCase {
    @MainActor func testConfigurationSaveBlocksQuitAndCancellationPreservesValue() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitSettingsLifecycleUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "Original Fixture Name"])
        let marker = fixture.root.appending(path: "config-write-started")
        let wrapper = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "WeGitTestGit", withExtension: nil))
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-gitExecutable", wrapper.path]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchEnvironment["WEGIT_CONFIG_WRITE_DELAY_MARKER"] = marker.path
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 10))
        app.activate()
        app.menuBars.menuBarItems["WeGit"].click()
        app.menuItems["native-command-settings"].click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.radioButtons["Git"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let edit = app.buttons["edit-setting:user.name"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        // Git requirements moved to native help when the settings surface was
        // simplified. Check the same information at its current disclosure point.
        let automatic = settings.buttons["恢复自动检测"]
        XCTAssertTrue(automatic.isHittable)
        XCTAssertTrue(settings.frame.contains(automatic.frame))
        automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        let requirement = app.helpTags.firstMatch
        XCTAssertTrue(
            requirement.waitForExistence(timeout: 5), settings.debugDescription)
        // Native HelpTag exposes its frame but not its rendered text as an AX
        // label/value. Read the real tooltip pixels rather than adding UI copy.
        let captured = requirement.screenshot()
        let pixels = try XCTUnwrap(
            captured.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: pixels.width * 4, height: pixels.height * 4,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width * 4, height: pixels.height * 4))
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["zh-Hans", "en-US"]
        recognition.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: XCTUnwrap(context.makeImage())).perform([recognition])
        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        XCTAssertTrue(text.filter { !$0.isWhitespace }.contains("Git2.46+"), text)
        let tooltip = XCTAttachment(screenshot: captured)
        tooltip.name = "Actual native Git requirement tooltip"
        tooltip.lifetime = .keepAlways
        add(tooltip)
        let recognized = XCTAttachment(string: text + "\n" + requirement.debugDescription)
        recognized.name = "Native Git help rendered text and HelpTag"
        recognized.lifetime = .keepAlways
        add(recognized)
        let help = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        help.name = "Git minimum-version native help"
        help.lifetime = .keepAlways
        add(help)
        edit.click()
        let value = app.textFields["git-setting-value"]
        XCTAssertTrue(value.waitForExistence(timeout: 3))
        value.click()
        value.typeKey("a", modifierFlags: .command)
        value.typeText("Cancelled Fixture Name")
        app.buttons["git-setting-save"].click()
        let started = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: marker.path) },
            object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 5), .completed)
        app.menuBars.menuBarItems["WeGit"].click()
        app.menuItems["native-command-quit"].click()
        let returnToApp = app.buttons["返回应用"]
        if returnToApp.waitForExistence(timeout: 2) { returnToApp.click() }
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertFalse(app.buttons["git-setting-save"].isEnabled)
        app.buttons["取消操作"].click()
        XCTAssertTrue(app.buttons["git-setting-save"].waitForExistence(timeout: 5))
        let cancelled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: app.buttons["git-setting-save"])
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        XCTAssertEqual(try fixture.git(["config", "--get", "user.name"]), "Original Fixture Name\n")
        settings.sheets.firstMatch.buttons["取消"].firstMatch.click()
    }
}
