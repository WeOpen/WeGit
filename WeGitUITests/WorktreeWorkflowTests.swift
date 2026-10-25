import XCTest

final class WorktreeWorkflowTests: XCTestCase {
    @MainActor func testLinkedWorktreesKeepDraftsPagesAndIndexesAcrossSwitchAndRelaunch() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitWorktreeUI")
        let first = f.root.appendingPathExtension("first")
        let second = f.root.appendingPathExtension("second")
        defer {
            f.remove()
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try f.git(["init", "-b", "main"])
        try f.git(["config", "user.name", "Worktree UI"])
        try f.git(["config", "user.email", "worktree@example.invalid"])
        try f.git(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: f.root.appending(path: "file.txt"))
        try f.git(["add", "."])
        try f.git(["commit", "-m", "Base"])
        let initial = try f.git(["rev-parse", "HEAD"])
        try f.git(["worktree", "add", "-b", "topic", first.path])
        try f.git(["worktree", "add", "--detach", second.path])
        try Data("first\n".utf8).write(to: first.appending(path: "file.txt"))
        try Data("second\n".utf8).write(to: second.appending(path: "second-only.txt"))
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = first.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let message = app.textFields["commit-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.click()
        message.typeText("First worktree draft")
        app.checkBoxes["stage:unstaged:file.txt"].click()
        XCTAssertTrue(app.checkBoxes["stage:staged:file.txt"].waitForExistence(timeout: 10))
        XCTAssertEqual(try UITestGit.run(["show", ":file.txt"], in: first), "first\n")
        XCTAssertEqual(try f.git(["show", ":file.txt"]), "base\n")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["history-count"].waitForExistence(timeout: 10))
        app.typeKey("o", modifierFlags: .command)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.typeKey("a", modifierFlags: .command)
        path.typeText(second.path)
        path.typeKey(.return, modifierFlags: [])
        app.buttons["OKButton"].click()
        XCTAssertTrue(app.staticTexts["second-only.txt"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(message.value as? String, "")
        message.click()
        message.typeText("Second worktree draft")
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["repository-switch-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText(first.lastPathComponent)
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["history-count"].waitForExistence(timeout: 10))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.value as? String, "First worktree draft")
        XCTAssertTrue(app.checkBoxes["stage:staged:file.txt"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows["main"].screenshot())
        screenshot.name = "Linked worktree restores its own draft and staged file"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launchArguments.append("--uitesting-keep-preferences")
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = second.path
        app.launchWeGit()
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.value as? String, "Second worktree draft")
        XCTAssertFalse(app.checkBoxes["stage:staged:file.txt"].exists)
        XCTAssertEqual(try UITestGit.run(["show", ":file.txt"], in: second), "base\n")
        XCTAssertEqual(try f.git(["rev-parse", "HEAD"]), initial)
        XCTAssertEqual(try UITestGit.run(["rev-parse", "HEAD"], in: first), initial)
        XCTAssertEqual(try UITestGit.run(["rev-parse", "HEAD"], in: second), initial)
    }
}
