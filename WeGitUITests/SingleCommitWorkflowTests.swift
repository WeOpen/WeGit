import XCTest

final class SingleCommitWorkflowTests: XCTestCase {
    @MainActor func testPreviewApplyRevertAndRecoverAfterRelaunch() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitSingleCommitUI")
        defer { f.remove() }
        try f.git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Single Commit UI"), ("user.email", "ui@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", f.root.appending(path: "no-hooks").path),
        ] { try f.git(["config", key, value]) }
        try write("base\n", to: "file.txt", in: f)
        try f.git(["add", "."])
        try f.git(["commit", "-m", "Base"])
        try f.git(["switch", "-c", "source"])
        try write("selected feature\n", to: "feature.txt", in: f)
        try f.git(["add", "."])
        try f.git(["commit", "-m", "Selected feature"])
        let feature = try oid(f, ["rev-parse", "HEAD"])
        try write("selected conflict\n", to: "file.txt", in: f)
        try f.git(["commit", "-am", "Conflicting change"])
        let conflict = try oid(f, ["rev-parse", "HEAD"])
        try f.git(["switch", "main"])
        try write("local change\n", to: "file.txt", in: f)
        try f.git(["commit", "-am", "Local change"])
        let initial = try oid(f, ["rev-parse", "HEAD"])
        let initialTree = try oid(f, ["rev-parse", "HEAD^{tree}"])
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", "light", "--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = f.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        resizeToMinimum(app.windows["main"])
        let draft = app.textFields["commit-message"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.click()
        draft.typeText("Keep my single-commit draft")
        let sheet = app.windows["main"].sheets.firstMatch

        showPreview(app, target: feature, operation: "Cherry-pick")
        let displayedTarget = sheet.descendants(matching: .any).matching(identifier: "single-commit-target")
            .firstMatch
        XCTAssertTrue(displayedTarget.waitForExistence(timeout: 10))
        XCTAssertEqual(displayedTarget.label, "选中提交: " + feature)
        let displayedHead = sheet.descendants(matching: .any).matching(identifier: "single-commit-head")
            .firstMatch
        XCTAssertEqual(displayedHead.label, "HEAD: " + initial)
        capture(sheet, name: "Cherry-pick preview pins target and current HEAD")
        sheet.buttons["single-commit-cancel"].click()
        waitUntilGone(sheet)
        XCTAssertEqual(try oid(f, ["rev-parse", "HEAD"]), initial)
        XCTAssertEqual(try f.git(["status", "--porcelain"]), "")
        showPreview(app, target: feature, operation: "Cherry-pick")
        execute(sheet)
        waitUntilGone(sheet)
        let picked = try oid(f, ["rev-parse", "HEAD"])
        XCTAssertNotEqual(picked, initial)
        XCTAssertEqual(try oid(f, ["rev-parse", "HEAD^"]), initial)
        XCTAssertEqual(
            try Data(contentsOf: f.root.appending(path: "feature.txt")), Data("selected feature\n".utf8))
        checkDraft(app)
        showPreview(app, target: feature, operation: "Revert")
        capture(sheet, name: "Revert preview preserves original commit")
        execute(sheet)
        waitUntilGone(sheet)
        let reverted = try oid(f, ["rev-parse", "HEAD"])
        XCTAssertNotEqual(reverted, picked)
        XCTAssertEqual(try oid(f, ["rev-parse", "HEAD^"]), picked)
        XCTAssertEqual(try oid(f, ["rev-parse", "HEAD^{tree}"]), initialTree)
        XCTAssertEqual(try oid(f, ["cat-file", "-t", feature]), "commit")
        checkDraft(app)

        showPreview(app, target: conflict, operation: "Cherry-pick")
        let warning = sheet.descendants(matching: .any).matching(identifier: "single-commit-conflicts")
            .firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        execute(sheet)
        let showChanges = sheet.buttons["single-commit-show-changes"]
        XCTAssertTrue(showChanges.waitForExistence(timeout: 15))
        showChanges.click()
        waitUntilGone(sheet)
        let continuation = app.buttons["sequencer-continue"]
        XCTAssertTrue(continuation.waitForExistence(timeout: 10))
        XCTAssertFalse(continuation.isEnabled)
        XCTAssertEqual(try oid(f, ["rev-parse", "CHERRY_PICK_HEAD"]), conflict)
        capture(app.windows["main"], name: "Cherry-pick exposes conflict recovery")
        app.terminate()
        app.launchArguments.append("--uitesting-keep-preferences")
        app.launchWeGit()
        XCTAssertTrue(continuation.waitForExistence(timeout: 10))
        checkDraft(app)
        app.buttons["sequencer-abort"].click()
        let abort = sheet.buttons["中止"]
        XCTAssertTrue(abort.waitForExistence(timeout: 5))
        abort.click()
        waitUntilGone(continuation)
        XCTAssertEqual(try oid(f, ["rev-parse", "HEAD"]), reverted)
        XCTAssertEqual(try Data(contentsOf: f.root.appending(path: "file.txt")), Data("local change\n".utf8))
        checkDraft(app)

        showPreview(app, target: conflict, operation: "Cherry-pick")
        execute(sheet)
        XCTAssertTrue(showChanges.waitForExistence(timeout: 15))
        showChanges.click()
        waitUntilGone(sheet)
        try write("resolved in editor\n", to: "file.txt", in: f)
        let resolve = app.buttons["stage:conflict:file.txt"]
        XCTAssertTrue(resolve.waitForExistence(timeout: 10))
        resolve.click()
        let confirmation = sheet.buttons["标记已解决"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.click()
        waitUntilEnabled(continuation)
        continuation.click()
        waitUntilGone(continuation)
        let completed = try oid(f, ["rev-parse", "HEAD"])
        XCTAssertNotEqual(completed, reverted)
        XCTAssertEqual(try oid(f, ["rev-parse", "HEAD^"]), reverted)
        XCTAssertEqual(try f.git(["show", ":file.txt"]), "resolved in editor\n")
        XCTAssertEqual(try f.git(["status", "--porcelain"]), "")
        checkDraft(app)
        capture(app.windows["main"], name: "Resolved cherry-pick preserves draft and clean index")
        app.terminate()
        app.launchArguments = [
            "-language", "en", "-appearance", "dark", "--uitesting", "--uitesting-keep-preferences",
        ]
        app.launchWeGit()
        resizeToMinimum(app.windows["main"])
        showPreview(app, target: completed, operation: "Revert")
        XCTAssertEqual(displayedTarget.label, "Selected commit: " + completed)
        XCTAssertTrue(sheet.buttons["single-commit-execute"].isHittable)
        XCTAssertLessThanOrEqual(sheet.frame.width, app.windows["main"].frame.width)
        capture(sheet, name: "English dark preview in the minimum window")
        app.typeKey(.escape, modifierFlags: [])
        waitUntilGone(sheet)
        XCTAssertEqual(try oid(f, ["rev-parse", "HEAD"]), completed)
    }

    private func write(_ text: String, to path: String, in fixture: UITestGit) throws {
        try Data(text.utf8).write(to: fixture.root.appending(path: path))
    }
    private func oid(_ fixture: UITestGit, _ arguments: [String]) throws -> String {
        try fixture.git(arguments).trimmingCharacters(in: .newlines)
    }
    @MainActor private func showPreview(_ app: XCUIApplication, target: String, operation: String) {
        app.typeKey("2", modifierFlags: .command)
        let history = app.descendants(matching: .any).matching(identifier: "history-list").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        let row = history.descendants(matching: .any).matching(
            NSPredicate(format: "value CONTAINS %@", String(target.prefix(12)))
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let operations = app.menuButtons["history-operations"]
        XCTAssertTrue(operations.waitForExistence(timeout: 5))
        operations.click()
        let action = app.menuItems[operation + "…"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()
        XCTAssertTrue(app.windows["main"].sheets.firstMatch.waitForExistence(timeout: 10))
    }
    @MainActor private func execute(_ sheet: XCUIElement) {
        let button = sheet.buttons["single-commit-execute"]
        waitUntilEnabled(button)
        XCTAssertTrue(button.isHittable)
        sheet.typeKey(.return, modifierFlags: [])
    }
    @MainActor private func resizeToMinimum(_ window: XCUIElement) {
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let frame = window.frame
        if abs(frame.width - 980) > 4 || abs(frame.height - 692) > 4 {
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -1, dy: -1))
            corner.click(
                forDuration: 0.2,
                thenDragTo: corner.withOffset(CGVector(dx: 980 - frame.width, dy: 692 - frame.height)))
        }
        XCTAssertEqual(window.frame.width, 980, accuracy: 4)
        XCTAssertEqual(window.frame.height, 692, accuracy: 4)
    }
    @MainActor private func checkDraft(_ app: XCUIApplication) {
        app.typeKey("1", modifierFlags: .command)
        let message = app.textFields["commit-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertEqual(message.value as? String, "Keep my single-commit draft")
    }
    @MainActor private func waitUntilEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }
    @MainActor private func waitUntilGone(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 15), .completed)
    }
    @MainActor private func capture(_ element: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
