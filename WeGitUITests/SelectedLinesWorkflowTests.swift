import XCTest

final class SelectedLinesWorkflowTests: XCTestCase {
    @MainActor func testPreviewCancelStageUnstageAndStaleConfirmation() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitSelectedLinesUI")
        defer { f.remove() }
        try f.git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Tester"), ("user.email", "test@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", f.root.appending(path: "no-hooks").path),
        ] { try f.git(["config", key, value]) }
        let path = "selected.txt"
        let base = Data("a\nb\nc\nd\n".utf8)
        let work = Data("a\nB\nC\nd\n".utf8)
        try base.write(to: f.root.appending(path: path))
        try Data("original\n".utf8).write(to: f.root.appending(path: "other"))
        try f.git(["add", "."])
        try f.git(["commit", "-m", "Base"])
        let head = try f.git(["rev-parse", "HEAD"])
        try Data("already staged\n".utf8).write(to: f.root.appending(path: "other"))
        try f.git(["add", "other"])
        try work.write(to: f.root.appending(path: path))
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
        draft.typeText("Preserve selected-line draft")
        openFile(app, layer: "unstaged", path: path)
        select(app, id: "3:unified")
        app.buttons["diff-selected-lines-preview"].click()
        XCTAssertTrue(app.buttons["selected-lines-execute"].waitForExistence(timeout: 10))
        capture(app, "Unified selected addition preview")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["selected-lines-execute"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: f.root.appending(path: ".git/index")), index)
        app.buttons["diff-selected-lines-preview"].click()
        execute(app)
        XCTAssertEqual(try f.git(["show", ":" + path]), "a\nB\nb\nc\nd\n")
        XCTAssertEqual(try Data(contentsOf: f.root.appending(path: path)), work)

        openFile(app, layer: "staged", path: path)
        XCTAssertEqual(app.checkBoxes["stage:staged:" + path].value as? String, "1")
        XCTAssertEqual(app.checkBoxes["stage:unstaged:" + path].value as? String, "0")
        let layout = app.segmentedControls["diff-layout"]
        layout.radioButtons.element(boundBy: 1).click()
        select(app, id: "1:new")
        app.buttons["diff-selected-lines-preview"].click()
        XCTAssertTrue(app.buttons["selected-lines-execute"].waitForExistence(timeout: 10))
        capture(app, "Split unstage preview keeps separate staged and unstaged rows")
        execute(app)
        XCTAssertEqual(try f.git(["show", ":" + path]), String(decoding: base, as: UTF8.self))
        XCTAssertEqual(try f.git(["show", ":other"]), "already staged\n")
        XCTAssertEqual(try Data(contentsOf: f.root.appending(path: path)), work)

        openFile(app, layer: "unstaged", path: path)
        layout.radioButtons.element(boundBy: 0).click()
        selectRange(app, from: 1, through: 4)
        app.buttons["diff-selected-lines-preview"].click()
        execute(app)
        XCTAssertEqual(try f.git(["show", ":" + path]), String(decoding: work, as: UTF8.self))
        openFile(app, layer: "staged", path: path)
        selectRange(app, from: 1, through: 4)
        app.buttons["diff-selected-lines-preview"].click()
        execute(app)
        XCTAssertEqual(try f.git(["show", ":" + path]), String(decoding: base, as: UTF8.self))

        app.terminate()
        app.launchArguments = [
            "-language", "en", "-appearance", "dark", "--uitesting", "--uitesting-keep-preferences",
        ]
        app.launchWeGit()
        openFile(app, layer: "unstaged", path: path)
        layout.radioButtons.element(boundBy: 0).click()
        select(app, id: "3:unified")
        app.buttons["diff-selected-lines-preview"].click()
        XCTAssertTrue(app.buttons["selected-lines-execute"].waitForExistence(timeout: 10))
        let staleIndex = try Data(contentsOf: f.root.appending(path: ".git/index"))
        let external = Data("external edit\n".utf8)
        try external.write(to: f.root.appending(path: path))
        app.buttons["selected-lines-execute"].click()
        let close = app.buttons["selected-lines-cancel"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let closed = NSPredicate(format: "label == %@", "Close")
        expectation(for: closed, evaluatedWith: close)
        waitForExpectations(timeout: 10)
        capture(app, "English dark stale confirmation preserves external bytes")
        close.click()
        XCTAssertEqual(try Data(contentsOf: f.root.appending(path: ".git/index")), staleIndex)
        XCTAssertEqual(try Data(contentsOf: f.root.appending(path: path)), external)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appending(path: ".git/index.lock").path))
        XCTAssertEqual(draft.value as? String, "Preserve selected-line draft")
        XCTAssertEqual(try f.git(["rev-parse", "HEAD"]), head)
    }

    @MainActor private func openFile(_ app: XCUIApplication, layer: String, path: String) {
        let checkbox = app.checkBoxes["stage:" + layer + ":" + path]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 10))
        let row = app.outlineRows.containing(.checkBox, identifier: "stage:" + layer + ":" + path).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.staticTexts[path].firstMatch.click()
        XCTAssertTrue(app.scrollViews["diff-content"].waitForExistence(timeout: 10))
    }
    @MainActor private func select(_ app: XCUIApplication, id: String) {
        let button = app.buttons["diff-select-line:" + id]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        XCTAssertTrue(app.buttons["diff-selected-lines-preview"].waitForExistence(timeout: 5))
    }
    @MainActor private func selectRange(_ app: XCUIApplication, from first: Int, through last: Int) {
        let start = app.textViews["diff-code:\(first)"].coordinate(
            withNormalizedOffset: CGVector(dx: 0, dy: 0)
        )
        .withOffset(CGVector(dx: 1, dy: 1))
        let end = app.textViews["diff-code:\(last)"].coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -1, dy: -1))
        start.click(forDuration: 0.2, thenDragTo: end)
        XCTAssertTrue(app.buttons["diff-selected-lines-preview"].isEnabled)
    }
    @MainActor private func resizeToMinimum(_ window: XCUIElement) {
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let frame = window.frame
        if abs(frame.width - 980) > 4 || abs(frame.height - 692) > 4 {
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -1, dy: -1))
            corner.click(
                forDuration: 0.2,
                thenDragTo: corner.withOffset(
                    CGVector(dx: 980 - frame.width, dy: 692 - frame.height)))
        }
    }
    @MainActor private func execute(_ app: XCUIApplication) {
        let button = app.buttons["selected-lines-execute"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        XCTAssertTrue(button.waitForNonExistence(timeout: 10))
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows["main"].screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
