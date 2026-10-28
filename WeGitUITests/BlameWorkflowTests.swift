import XCTest

final class BlameWorkflowTests: XCTestCase {
    @MainActor func testCommittedAttributionPagingAndHistoricalNavigation() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitBlameUI")
        defer { f.remove() }
        try f.git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "First Author"), ("user.email", "first@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", f.root.appending(path: "no-hooks").path),
        ] { try f.git(["config", key, value]) }
        let original = "原始 [file].txt"
        let path = "renamed.txt"
        let source = "first\r\nsecond\r\n" + (3...205).map { "line \($0)\r\n" }.joined() + "last"
        try Data(source.utf8).write(to: f.root.appending(path: original))
        try f.git(["add", "."])
        try f.git(["commit", "-m", "Original lines"])
        let first = try oid(f)
        try f.git(["config", "user.name", "Second Author"])
        try Data(source.replacingOccurrences(of: "second\r\n", with: "changed\r\n").utf8).write(
            to: f.root.appending(path: original))
        try f.git(["commit", "-am", "Change second line"])
        let second = try oid(f)
        try f.git(["mv", original, path])
        try f.git(["commit", "-m", "Rename source"])
        let tip = try oid(f)
        let working = Data("uncommitted must survive\n".utf8)
        try working.write(to: f.root.appending(path: path))
        let index = try Data(contentsOf: f.root.appending(path: ".git/index"))
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
        draft.typeText("Keep my Blame draft")
        openWorkingFile(app, path: path)
        XCTAssertEqual(element("blame-target", app).label, path + " · " + tip)
        XCTAssertEqual(code(1, app).value as? String, "first ")
        XCTAssertEqual(code(2, app).value as? String, "changed ")
        XCTAssertTrue(code(1, app).label.contains("First Author"))
        XCTAssertTrue(code(2, app).label.contains("Second Author"))
        XCTAssertEqual(app.buttons["blame-commit:1"].label, String(first.prefix(7)))
        XCTAssertEqual(app.buttons["blame-commit:2"].label, String(second.prefix(7)))
        UITestGit.preservingClipboard { clipboard in
            let start = code(1, app).coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: 1, dy: 1))
            let end = code(2, app).coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -1, dy: -1))
            start.click(forDuration: 0.2, thenDragTo: end)
            code(1, app).typeKey("c", modifierFlags: .command)
            XCTAssertEqual(
                Data((clipboard.string(forType: .string) ?? "").utf8), Data("first\r\nchanged\r".utf8))
        }
        capture(app, "Blame pins authors and committed bytes in minimum Chinese light window")
        app.buttons["blame-commit:2"].click()
        let inspected = element("blame-inspected-commit", app)
        XCTAssertTrue(inspected.waitForExistence(timeout: 10))
        XCTAssertEqual(inspected.value as? String, second)
        XCTAssertTrue(element("diff-content", app).waitForExistence(timeout: 10))
        app.buttons["blame-commit-close"].click()
        XCTAssertTrue(inspected.waitForNonExistence(timeout: 5))
        app.buttons["blame-file-history:2"].click()
        let historicalPath = app.textFields["file-history-path"]
        XCTAssertTrue(historicalPath.waitForExistence(timeout: 10))
        XCTAssertEqual(historicalPath.value as? String, original)
        XCTAssertTrue(element("file-history-commit:" + first, app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("file-history-commit:" + second, app).exists)
        XCTAssertFalse(element("file-history-commit:" + tip, app).exists)
        capture(app, "Blame history uses the original path and source revision")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(historicalPath.waitForNonExistence(timeout: 5))
        app.buttons["blame-next"].click()
        XCTAssertTrue(code(201, app).waitForExistence(timeout: 10))
        XCTAssertEqual(element("blame-range", app).value as? String, "201–206 / 206 行")
        XCTAssertEqual(code(206, app).value as? String, "last")
        XCTAssertFalse(app.buttons["blame-next"].isEnabled)
        app.buttons["blame-previous"].click()
        XCTAssertTrue(code(1, app).waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("blame-target", app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "Keep my Blame draft")
        XCTAssertEqual(try oid(f), tip)
        XCTAssertEqual(try Data(contentsOf: f.root.appending(path: ".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: f.root.appending(path: path)), working)

        app.terminate()
        app.launchArguments = [
            "-language", "en", "-appearance", "dark", "--uitesting", "--uitesting-keep-preferences",
        ]
        app.launchWeGit()
        resizeToMinimum(app.windows["main"])
        openWorkingFile(app, path: path)
        XCTAssertEqual(element("blame-target", app).label, path + " · " + tip)
        XCTAssertTrue(app.buttons["blame-close"].isHittable)
        capture(app, "Blame English dark retains native controls and attribution")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("blame-target", app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "Keep my Blame draft")

        try f.git(["rm", "-f", path])
        try f.git(["commit", "-m", "Delete attributed file"])
        let deleted = try oid(f)
        app.typeKey("2", modifierFlags: .command)
        let history = element("history-list", app)
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        let row = history.descendants(matching: .any).matching(
            NSPredicate(format: "value CONTAINS %@", String(deleted.prefix(12)))
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let committedBlame = app.buttons["commit-blame"]
        XCTAssertTrue(committedBlame.waitForExistence(timeout: 10))
        committedBlame.click()
        XCTAssertTrue(code(1, app).waitForExistence(timeout: 10))
        XCTAssertEqual(element("blame-target", app).label, path + " · " + tip)
        XCTAssertEqual(code(2, app).value as? String, "changed ")
        capture(app, "Deleted-file attribution reads the compared parent snapshot")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("blame-target", app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(try oid(f), deleted)
        XCTAssertEqual(try f.git(["status", "--porcelain=v1"]), "")
    }

    @MainActor private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor private func code(_ line: Int, _ app: XCUIApplication) -> XCUIElement {
        app.textViews["blame-code:\(line)"]
    }
    @MainActor private func openWorkingFile(_ app: XCUIApplication, path: String) {
        let file = element("changes-list", app).staticTexts[path].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.rightClick()
        let action = app.menuItems["file-blame:" + path]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.click()
        XCTAssertTrue(code(1, app).waitForExistence(timeout: 10))
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
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows["main"].screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func oid(_ f: UITestGit) throws -> String {
        try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
    }
}
