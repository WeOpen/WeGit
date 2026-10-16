import XCTest

final class ToolbarMenuBarTests: XCTestCase {
    @MainActor func testMenuBarReopensClosedWindowWithoutLosingDraftAndRefreshesExternalChanges() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitMenuBarUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Fixture"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        let file = fixture.root.appending(path: "MenuBar.swift")
        try Data("let state = 1\n".utf8).write(to: file)
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Menu bar fixture"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-menu-bar"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let message = app.textFields["commit-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.click()
        message.typeText("Keep this draft across menu bar navigation")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.outlines["history-list"].waitForExistence(timeout: 10))
        app.windows["main"].typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.windows["main"].exists)
        try Data("let state = 2\n".utf8).write(to: file)
        app.typeKey("m", modifierFlags: [.command, .shift])
        // AppKit can combine adjacent static text in the popover; assert its actual
        // announced state rather than assuming that each Text keeps a separate node.
        let state = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "1 个文件有改动", "1 个文件有改动")
        ).firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        app.buttons["menu-bar-open-main"].click()
        XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.outlines["history-list"].exists)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.value as? String, "Keep this draft across menu bar navigation")
        XCTAssertEqual(try fixture.git(["log", "-1", "--format=%s"]), "Menu bar fixture\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let state = 2\n")
    }

    @MainActor func testCompactToolbarKeepsSyncAndMoreActionsReachable() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitCompactToolbarUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let window = app.windows["main"]
        XCTAssertTrue(app.staticTexts["工作区干净"].firstMatch.waitForExistence(timeout: 10))
        let initial = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -1, dy: -1))
        corner.click(
            forDuration: 0.2,
            thenDragTo: corner.withOffset(CGVector(dx: 980 - initial.width, dy: 693 - initial.height)))
        let sync = app.descendants(matching: .any).matching(identifier: "toolbar-sync").firstMatch
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        XCTAssertTrue(sync.isHittable)
        sync.click()
        XCTAssertTrue(app.menuItems["拉取"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["拉取"].isEnabled)
        XCTAssertFalse(app.menuItems["推送"].isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let more = app.descendants(matching: .any).matching(identifier: "toolbar-more").firstMatch
        XCTAssertTrue(more.isHittable)
        more.click()
        XCTAssertTrue(app.menuItems["活动记录"].waitForExistence(timeout: 3))
        app.menuItems["活动记录"].click()
        XCTAssertTrue(app.staticTexts["活动记录"].firstMatch.waitForExistence(timeout: 5))
    }
}
