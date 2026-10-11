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
        app.menuItems["Settings…"].click()
        let gitTab = app.buttons["Git"].firstMatch
        if gitTab.waitForExistence(timeout: 3) { gitTab.click() } else { app.radioButtons["Git"].click() }
        let edit = app.buttons["edit-setting:user.name"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Git 2.46+")).firstMatch
                .exists)
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
        app.menuItems["Quit WeGit"].click()
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
        app.buttons["取消"].firstMatch.click()
    }
}
