import XCTest

final class RecoveryWorkflowTests: XCTestCase {
    @MainActor func testResetPreviewCancelAndRestoreAfterRelaunchPreserveDraftAndRawLayers() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitRecoveryUI")
        defer { f.remove() }
        try f.git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Recovery UI"), ("user.email", "ui@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", f.root.appending(path: "no-hooks").path),
            ("core.autocrlf", "false"),
        ] { try f.git(["config", key, value]) }
        let file = f.root.appending(path: "恢复 [file].txt")
        try Data("base\r\nlast".utf8).write(to: file)
        try f.git(["add", "."])
        try f.git(["commit", "-m", "Base"])
        let target = try oid(f, "HEAD")
        try Data("committed\r\nlast".utf8).write(to: file)
        try f.git(["commit", "-am", "Current"])
        let originalHead = try oid(f, "HEAD")
        try Data("staged\r\nlast".utf8).write(to: file)
        try f.git(["add", "."])
        try Data("working\r\nlast".utf8).write(to: file)
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let work = try Data(contentsOf: file)
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", "light", "--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = f.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let draft = app.textFields["commit-message"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.click()
        draft.typeText("Keep recovery draft")
        showReset(app, target: target)
        let sheet = app.windows["main"].sheets.firstMatch
        let source = sheet.descendants(matching: .any).matching(identifier: "reset-target").firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        XCTAssertEqual(source.label, "目标提交: " + target)
        capture(sheet, "Soft Reset preview preserves layers")
        sheet.buttons["reset-cancel"].click()
        gone(sheet)
        XCTAssertEqual(try oid(f, "HEAD"), originalHead)
        XCTAssertEqual(try Data(contentsOf: file), work)
        XCTAssertEqual(try Data(contentsOf: f.root.appending(path: ".git/index")), index)

        showReset(app, target: target)
        choose(app, "Hard")
        let approval = app.checkBoxes["reset-hard-confirm"]
        XCTAssertTrue(approval.waitForExistence(timeout: 15))
        let execute = app.buttons["reset-execute"]
        XCTAssertFalse(execute.isEnabled)
        approval.click()
        enabled(execute)
        capture(sheet, "Hard Reset requires backup and explicit approval")
        execute.click()
        let showRecovery = app.buttons["reset-show-recovery"]
        XCTAssertTrue(showRecovery.waitForExistence(timeout: 20))
        sheet.buttons["reset-cancel"].click()
        gone(sheet)
        XCTAssertEqual(try oid(f, "HEAD"), target)
        XCTAssertEqual(try Data(contentsOf: file), Data("base\r\nlast".utf8))
        app.terminate()
        app.launchArguments.append("--uitesting-keep-preferences")
        app.launchWeGit()
        app.typeKey("2", modifierFlags: .command)
        let browser = app.buttons["history-recovery"]
        XCTAssertTrue(browser.waitForExistence(timeout: 15))
        browser.click()
        choose(app, "内容备份")
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recovery-record:'"))
            .firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        record.click()
        let restore = app.buttons["recovery-restore"]
        enabled(restore)
        restore.click()
        choose(app, "工作文件与暂存区")
        let restoreExecute = app.buttons["recovery-execute"]
        enabled(restoreExecute)
        capture(app.windows["main"], "Persistent backup restores exact working and staged bytes")
        restoreExecute.click()
        gone(restoreExecute)
        XCTAssertEqual(try oid(f, "HEAD"), target)
        XCTAssertEqual(try Data(contentsOf: file), work)
        XCTAssertEqual(try Data(contentsOf: f.root.appending(path: ".git/index")), index)
        app.buttons["recovery-close"].click()
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertEqual(draft.value as? String, "Keep recovery draft")
    }

    @MainActor func testReflogCreatesRecoveryBranchAndEnglishDarkControlsRemainReachable() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitReflogUI")
        defer { f.remove() }
        try f.git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Reflog UI"), ("user.email", "ui@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", f.root.appending(path: "no-hooks").path),
        ] { try f.git(["config", key, value]) }
        try Data("base\n".utf8).write(to: f.root.appending(path: "file"))
        try f.git(["add", "."])
        try f.git(["commit", "-m", "Base"])
        let head = try oid(f, "HEAD")
        let app = XCUIApplication()
        app.launchArguments = ["-language", "en", "-appearance", "dark", "--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = f.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        app.typeKey("2", modifierFlags: .command)
        let opener = app.buttons["history-recovery"]
        XCTAssertTrue(opener.waitForExistence(timeout: 15))
        opener.click()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'reflog:'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.click()
        let create = app.buttons["recovery-create-branch"]
        enabled(create)
        create.click()
        enabled(create)
        let branches = try f.git(["for-each-ref", "--format=%(objectname)", "refs/heads/recovery-*"])
        XCTAssertEqual(branches.trimmingCharacters(in: .newlines), head)
        XCTAssertEqual(try oid(f, "HEAD"), head)
        XCTAssertTrue(app.buttons["recovery-close"].isHittable)
        capture(app.windows["main"], "English dark recovery branch flow")
        app.typeKey(.escape, modifierFlags: [])
        gone(app.buttons["recovery-close"])
    }
    private func oid(_ f: UITestGit, _ ref: String) throws -> String {
        try f.git(["rev-parse", ref]).trimmingCharacters(in: .newlines)
    }
    @MainActor private func showReset(_ app: XCUIApplication, target: String) {
        app.typeKey("2", modifierFlags: .command)
        let history = app.descendants(matching: .any).matching(identifier: "history-list").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        let row = history.descendants(matching: .any).matching(
            NSPredicate(format: "value CONTAINS %@", String(target.prefix(12)))
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.click()
        let menu = app.menuButtons["history-operations"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        app.menuItems["Reset…"].click()
    }
    @MainActor private func choose(_ app: XCUIApplication, _ label: String) {
        let radio = app.radioButtons[label]
        if radio.waitForExistence(timeout: 5) {
            radio.click()
        } else {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.click()
        }
    }
    @MainActor private func enabled(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed)
    }
    @MainActor private func gone(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed)
    }
    @MainActor private func capture(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
