import AppKit
import XCTest

final class StashWorkflowTests: XCTestCase {
    @MainActor func testSaveInspectApplyAndDeletePreserveWorkingAndStagingState() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitStashUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Fixture"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        let file = fixture.root.appending(path: "file.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Stash fixture"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        try Data("let value = 2\n".utf8).write(to: file)
        try fixture.git(["add", "file.swift"])
        try Data("let value = 3\n".utf8).write(to: file)
        let untracked = fixture.root.appending(path: "New [1].txt")
        try Data("untracked bytes\n".utf8).write(to: untracked)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["toolbar-sidebar"].waitForExistence(timeout: 10))
        app.typeKey("4", modifierFlags: .command)
        let save = app.buttons["stash-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        save.click()
        let name = app.textFields["stash-message"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Stash UI Fixture")
        app.checkBoxes["stash-include-untracked"].click()
        app.buttons["stash-create-confirm"].click()
        let apply = app.buttons["stash-apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: apply)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertTrue(app.outlines["stash-list"].exists)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), "")
        XCTAssertTrue(try fixture.git(["stash", "list"]).contains("Stash UI Fixture"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: untracked.path))
        app.radioButtons["原暂存区内容"].click()
        XCTAssertTrue(app.outlines["commit-files"].waitForExistence(timeout: 5))
        apply.click()
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 3\n")
        XCTAssertEqual(try fixture.git(["show", ":file.swift"]), "let value = 2\n")
        XCTAssertEqual(try String(contentsOf: untracked, encoding: .utf8), "untracked bytes\n")
        XCTAssertFalse(apply.isEnabled)
        app.buttons["stash-delete"].click()
        let confirm = app.buttons["stash-confirm-action"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(app.staticTexts["没有暂存记录"].waitForExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["stash", "list"]), "")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 3\n")
        XCTAssertEqual(try fixture.git(["show", ":file.swift"]), "let value = 2\n")
    }
}
