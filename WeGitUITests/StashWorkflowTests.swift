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
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "stash-list").firstMatch.exists)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), "")
        XCTAssertTrue(try fixture.git(["stash", "list"]).contains("Stash UI Fixture"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: untracked.path))
        app.radioButtons["原暂存区内容"].click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "commit-files").firstMatch.waitForExistence(
                timeout: 5))
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
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "stash-empty").firstMatch.waitForExistence(
                timeout: 10))
        XCTAssertEqual(try fixture.git(["stash", "list"]), "")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 3\n")
        XCTAssertEqual(try fixture.git(["show", ":file.swift"]), "let value = 2\n")
    }

    @MainActor func testPopCancelSuccessConflictAndExternalListRefresh() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitStashRecoveryUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Fixture"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        let file = fixture.root.appending(path: "file.txt")
        try Data("base\n".utf8).write(to: file)
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Base"])
        try Data("saved\n".utf8).write(to: file)
        try fixture.git(["stash", "push", "-m", "Recovery record"])
        let saved = try fixture.git(["rev-parse", "refs/stash"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["toolbar-sidebar"].waitForExistence(timeout: 10))
        app.typeKey("4", modifierFlags: .command)
        let pop = app.buttons["stash-pop"]
        XCTAssertTrue(pop.waitForExistence(timeout: 10))
        waitEnabled(pop)
        pop.click()
        let confirm = app.buttons["stash-confirm-action"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.windows["main"].sheets.firstMatch.buttons["取消"].click()
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/stash"]), saved)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), "")
        pop.click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        let empty = app.descendants(matching: .any).matching(identifier: "stash-empty").firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "saved\n")
        XCTAssertEqual(try fixture.git(["stash", "list"]), "")

        try fixture.git(["reset", "--hard", "HEAD"])
        try Data("conflicting saved\n".utf8).write(to: file)
        try fixture.git(["stash", "push", "-m", "Conflict record"])
        let conflictStash = try fixture.git(["rev-parse", "refs/stash"])
        try Data("different base\n".utf8).write(to: file)
        try fixture.git(["add", "file.txt"])
        try fixture.git(["commit", "-m", "Different base"])
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(pop.waitForExistence(timeout: 10))
        waitEnabled(pop)
        let restoreIndex = app.checkBoxes["stash-restore-index"]
        if restoreIndex.value as? String == "1" { restoreIndex.click() }
        pop.click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        let conflicts = app.buttons["stash-show-conflicts"]
        XCTAssertTrue(conflicts.waitForExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", "refs/stash"]), conflictStash)
        XCTAssertFalse(try fixture.git(["ls-files", "--unmerged"]).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.root.appending(path: ".git/MERGE_HEAD").path))
        XCTAssertFalse(pop.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.windows["main"].screenshot())
        screenshot.name = "Stash Pop conflict retains original record"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        conflicts.click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "changes-list").firstMatch.waitForExistence(
                timeout: 5))
        try Data("resolved\n".utf8).write(to: file)
        try fixture.git(["add", "file.txt"])
        try fixture.git(["commit", "-m", "Resolve stash conflict"])
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(pop.waitForExistence(timeout: 5))
        waitEnabled(pop)
        try fixture.git(["stash", "drop", "stash@{0}"])
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "resolved\n")
    }

    @MainActor private func waitEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
}
