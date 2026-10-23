import XCTest

final class FileHistoryWorkflowTests: XCTestCase {
    @MainActor func testFileContextRenameSearchAndManualDeletedPath() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitFileHistoryUI")
        defer { f.remove() }
        try f.git(["init", "-b", "main"])
        try f.git(["config", "user.name", "History Author"])
        try f.git(["config", "user.email", "history@example.invalid"])
        try f.git(["config", "commit.gpgsign", "false"])
        try Data("one\ntwo\nthree\nfour\n".utf8).write(to: f.root.appending(path: "old.txt"))
        try f.git(["add", "."])
        try f.git(["commit", "-m", "Initial [literal]"])
        let initial = try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try f.git(["mv", "old.txt", "renamed.txt"])
        try f.git(["commit", "-m", "Rename"])
        try Data("one\ntwo\nthree\nfour\nfive\n".utf8).write(to: f.root.appending(path: "renamed.txt"))
        try f.git(["commit", "-am", "Latest"])
        let latest = try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("one\ntwo\nthree\nfour\nfive\nworking\n".utf8).write(
            to: f.root.appending(path: "renamed.txt"))
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = f.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let list = app.descendants(matching: .any).matching(identifier: "changes-list").firstMatch
        let file = list.staticTexts["renamed.txt"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.rightClick()
        let show = app.menuItems["file-history:renamed.txt"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.click()
        let path = app.textFields["file-history-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        XCTAssertEqual(path.value as? String, "renamed.txt")
        let original = entry(initial, app)
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        XCTAssertTrue(entry(latest, app).exists)
        let message = app.textFields["file-history-message"]
        message.click()
        message.typeText("no-match")
        message.typeKey("a", modifierFlags: .command)
        message.typeText("[literal]")
        XCTAssertTrue(entry(latest, app).waitForNonExistence(timeout: 10))
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        original.click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "diff-content").firstMatch.waitForExistence(
                timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.windows["main"].screenshot())
        screenshot.name = "File history reaches a filtered commit before rename"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["file-history-close"].click()
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
        try f.git(["reset", "--hard", "HEAD"])
        try f.git(["rm", "renamed.txt"])
        try f.git(["commit", "-m", "Delete"])
        let deleted = try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        app.typeKey("2", modifierFlags: .command)
        let manual = app.buttons["history-file-history"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10))
        manual.click()
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.click()
        path.typeText("renamed.txt")
        XCTAssertTrue(entry(deleted, app).waitForExistence(timeout: 10))
        XCTAssertTrue(original.exists)
        app.buttons["file-history-close"].click()
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try f.git(["status", "--porcelain=v1"]), "")
        XCTAssertEqual(
            try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), deleted)
        try Data("before stage\n".utf8).write(to: f.root.appending(path: "staged-old.txt"))
        try f.git(["add", "staged-old.txt"])
        try f.git(["commit", "-m", "Before staged rename"])
        let renameHead = try f.git(["rev-parse", "HEAD"])
        try f.git(["mv", "staged-old.txt", "staged-new.txt"])
        let stagedStatus = try f.git(["status", "--porcelain=v1"])
        app.typeKey("1", modifierFlags: .command)
        let renamed = list.staticTexts["staged-new.txt"].firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 10))
        renamed.rightClick()
        app.menuItems["file-history:staged-new.txt"].click()
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        XCTAssertEqual(path.value as? String, "staged-old.txt")
        XCTAssertTrue(
            entry(renameHead.trimmingCharacters(in: .whitespacesAndNewlines), app).waitForExistence(
                timeout: 10))
        app.buttons["file-history-close"].click()
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try f.git(["status", "--porcelain=v1"]), stagedStatus)
        XCTAssertEqual(try f.git(["rev-parse", "HEAD"]), renameHead)
    }
    @MainActor private func entry(_ oid: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "file-history-commit:" + oid).firstMatch
    }
}
