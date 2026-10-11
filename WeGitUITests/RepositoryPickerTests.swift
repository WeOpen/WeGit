import XCTest

final class RepositoryPickerTests: XCTestCase {
    @MainActor func testKeyboardSelectionSearchAndCloneHandoff() throws {
        continueAfterFailure = false
        let first = try UITestGit(prefix: "WeGitPickerAlphaUI")
        let second = try UITestGit(prefix: "WeGitPickerBetaUI")
        defer {
            first.remove()
            second.remove()
        }
        try first.git(["init", "-b", "main"])
        try second.git(["init", "-b", "main"])
        try Data("first\n".utf8).write(to: first.root.appending(path: "first.txt"))
        try Data("second\n".utf8).write(to: second.root.appending(path: "second.txt"))
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = first.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["first.txt"].firstMatch.waitForExistence(timeout: 10))
        app.typeKey("o", modifierFlags: .command)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.typeKey("a", modifierFlags: .command)
        path.typeText(second.root.path)
        path.typeKey(.return, modifierFlags: [])
        app.buttons["OKButton"].click()
        XCTAssertTrue(app.staticTexts["second.txt"].firstMatch.waitForExistence(timeout: 10))

        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["repository-switch-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeKey(.downArrow, modifierFlags: [])
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["first.txt"].firstMatch.waitForExistence(timeout: 10))

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText(second.root.lastPathComponent)
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["second.txt"].firstMatch.waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.buttons["克隆仓库…"].click()
        XCTAssertTrue(app.textFields["clone-url"].waitForExistence(timeout: 5))
        app.buttons["clone-cancel"].click()
        XCTAssertTrue(app.staticTexts["second.txt"].firstMatch.exists)
    }
}
