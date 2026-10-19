import XCTest

final class SettingsReadingTests: XCTestCase {
    @MainActor func testSixSettingsTabsAndLiveTextMeasurementChanges() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitSettingsReading")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let file = fixture.root.appending(path: "settings.swift")
        try Data("let before = 1\n".utf8).write(to: file)
        try fixture.git(["add", "."])
        try fixture.git([
            "-c", "user.name=UI Fixture", "-c", "user.email=ui@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", "Settings fixture",
        ])
        try Data("let after = 2\n".utf8).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-codeSize", "11"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let row = app.outlines["changes-list"].staticTexts["settings.swift"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let code = app.textViews.matching(NSPredicate(format: "value == %@", "let after = 2")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        let initialHeight = code.frame.height
        XCTAssertEqual(initialHeight, 11 * 1.2, accuracy: 4)
        app.menuBars.menuBarItems["WeGit"].click()
        app.menuItems["native-command-settings"].click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        func tab(_ title: String) {
            let button = settings.radioButtons[title].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        tab("通用")
        XCTAssertTrue(app.switches["settings-restore-repository"].waitForExistence(timeout: 5))
        tab("Git")
        XCTAssertTrue(app.popUpButtons["git-setting-scope"].waitForExistence(timeout: 5))
        tab("差异")
        let whitespace = app.switches["settings-whitespace"]
        XCTAssertTrue(whitespace.exists)
        whitespace.click()
        tab("提交")
        let drafts = app.switches["settings-save-drafts"]
        XCTAssertTrue(drafts.exists)
        drafts.click()
        XCTAssertEqual(drafts.value as? Int, 0)
        drafts.click()
        tab("高级")
        app.buttons["清空活动记录"].click()
        XCTAssertTrue(app.staticTexts["已清空活动记录"].waitForExistence(timeout: 5))
        tab("外观")
        let slider = app.sliders["settings-code-size"]
        XCTAssertTrue(slider.exists)
        for _ in 0..<6 {
            if slider.isHittable && settings.frame.contains(slider.frame) { break }
            settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -240)
        }
        XCTAssertTrue(settings.frame.contains(slider.frame))
        XCTAssertTrue(slider.isHittable)
        slider.adjust(toNormalizedSliderPosition: 1)
        let sizeState = XCTAttachment(
            string: "value=\(String(describing: slider.value)) label=\(slider.label) frame=\(slider.frame)")
        sizeState.name = "Visible code size slider after adjustment"
        sizeState.lifetime = .keepAlways
        add(sizeState)
        let font = app.popUpButtons["settings-code-font"]
        XCTAssertEqual(font.label, "代码字体")
        font.click()
        app.menuItems["Menlo"].click()
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let changed = app.textViews.matching(NSPredicate(format: "value == %@", "let·after·=·2")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(changed.frame.height, initialHeight + 8)
        XCTAssertEqual(changed.frame.height, 24 * 1.2, accuracy: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Live code size after Settings change"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
