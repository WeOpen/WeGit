import XCTest

final class WindowLifecycleTests: XCTestCase {
    @MainActor func testSharedDraftMutationOwnershipAndTemplateSnapshot() throws {
        continueAfterFailure = false
        let fixture = try windowFixture()
        defer { fixture.remove() }
        let app = launchWindowFixture(fixture)
        defer { app.terminate() }
        let first = app.windows["main"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let firstDraft = first.textFields["commit-message"]
        XCTAssertTrue(firstDraft.waitForExistence(timeout: 10))
        replace(firstDraft, "first owned draft")
        app.menuBars.menuBarItems["native-menu-file"].click()
        app.menuItems["native-command-openInNewWindow"].click()
        let secondaryWindows = app.windows.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "workspace-window-"))
        let candidate = secondaryWindows.firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 15))
        XCTAssertEqual(secondaryWindows.count, 1)
        let secondaryID = candidate.identifier
        let second = app.windows[secondaryID]
        let secondDraft = second.textFields["commit-message"]
        XCTAssertTrue(secondDraft.waitForExistence(timeout: 15))
        XCTAssertEqual(secondDraft.value as? String, "first owned draft")
        XCTAssertFalse(secondDraft.isEnabled)
        XCTAssertFalse(second.checkBoxes["commit-amend"].isEnabled)
        let secondSources = second.descendants(matching: .any).matching(identifier: "commit-message-sources")
            .firstMatch
        XCTAssertFalse(secondSources.isEnabled)
        second.buttons["commit-draft-claim"].click()
        replace(secondDraft, "second owned draft")
        XCTAssertFalse(firstDraft.isEnabled)
        secondSources.click()
        app.menuItems["使用模板…"].click()
        let use = second.sheets.firstMatch.buttons["message-source-use"]
        XCTAssertTrue(use.waitForExistence(timeout: 10))
        first.buttons["commit-draft-claim"].click()
        replace(firstDraft, "first typed after template opened")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: use)
                ], timeout: 5),
            .completed)
        second.sheets.firstMatch.buttons["取消"].click()
        XCTAssertEqual(firstDraft.value as? String, "first typed after template opened")
        second.buttons["commit-draft-claim"].click()
        secondSources.click()
        app.menuItems["使用模板…"].click()
        let freshUse = second.sheets.firstMatch.buttons["message-source-use"]
        XCTAssertTrue(freshUse.waitForExistence(timeout: 10))
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "enabled == true"), object: freshUse)
                ], timeout: 10),
            .completed)
        freshUse.click()
        XCTAssertEqual(secondDraft.value as? String, "Template message\nsecond line\n")
        second.buttons["message-source-undo"].click()
        XCTAssertEqual(secondDraft.value as? String, "first typed after template opened")
        XCTAssertFalse(first.checkBoxes["commit-amend"].isEnabled)
        XCTAssertEqual(try fixture.git(["status", "--porcelain"]), "")
    }

    @MainActor func testSelectedCommitAndDraftRestoreAfterApplicationReopen() throws {
        continueAfterFailure = false
        let fixture = try windowFixture()
        defer { fixture.remove() }
        let original = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("later\n".utf8).write(to: fixture.root.appending(path: "tracked.txt"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Later"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let index = try Data(contentsOf: fixture.root.appending(path: ".git/index"))
        let app = launchWindowFixture(fixture)
        defer { app.terminate() }
        let draft = app.textFields["commit-message"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        replace(draft, "draft survives selected commit restoration")
        app.menuBars.menuBarItems["native-menu-workspace"].click()
        app.menuItems["native-command-history"].click()
        let rows = app.outlines["history-list"].outlineRows.containing(
            NSPredicate(format: "value CONTAINS %@", "提交 " + original.prefix(12))
        )
        let row = rows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertEqual(rows.count, 1)
        row.click()
        XCTAssertTrue(app.staticTexts[original].firstMatch.waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments += ["--uitesting-keep-preferences"]
        app.launchWeGit()
        XCTAssertTrue(app.staticTexts[original].firstMatch.waitForExistence(timeout: 15))
        app.menuBars.menuBarItems["native-menu-workspace"].click()
        app.menuItems["native-command-changes"].click()
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertEqual(draft.value as? String, "draft survives selected commit restoration")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: ".git/index")), index)
    }

    @MainActor func testWindowFrameRestoresAndClosedWorkspaceCanReopen() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitWindowLifecycleUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let app = XCUIApplication()
        let namespace = UUID().uuidString
        app.launchArguments = ["--uitesting", "--uitesting-window-state", namespace]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let window = app.windows["main"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let initial = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -1, dy: -1))
        corner.click(
            forDuration: 0.2,
            thenDragTo: corner.withOffset(CGVector(dx: 1120 - initial.width, dy: 780 - initial.height)))
        XCTAssertEqual(window.frame.width, 1120, accuracy: 4)
        XCTAssertEqual(window.frame.height, 780, accuracy: 4)
        app.terminate()
        app.launchArguments += ["--uitesting-keep-preferences"]
        app.launchWeGit()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertEqual(window.frame.width, 1120, accuracy: 4)
        XCTAssertEqual(window.frame.height, 780, accuracy: 4)
        window.typeKey("w", modifierFlags: .command)
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: window)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        app.menuBars.menuBarItems["native-menu-window"].click()
        app.menuItems["native-command-showMainWindow"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertEqual(window.frame.width, 1120, accuracy: 4)
        XCTAssertTrue(app.staticTexts["工作区干净"].firstMatch.waitForExistence(timeout: 10))
    }

    private func windowFixture() throws -> UITestGit {
        let fixture = try UITestGit(prefix: "WeGitWindowOwnershipUI")
        do {
            try fixture.git(["init", "-b", "main"])
            try fixture.git(["config", "user.name", "Window UI"])
            try fixture.git(["config", "user.email", "window@example.invalid"])
            try fixture.git(["config", "commit.gpgsign", "false"])
            try Data("original\n".utf8).write(to: fixture.root.appending(path: "tracked.txt"))
            try Data("Template message\nsecond line\n".utf8).write(
                to: fixture.root.appending(path: "template.txt"))
            try fixture.git(["config", "commit.template", fixture.root.appending(path: "template.txt").path])
            try fixture.git(["add", "."])
            try fixture.git(["commit", "-m", "Initial"])
            return fixture
        } catch {
            fixture.remove()
            throw error
        }
    }

    @MainActor private func launchWindowFixture(_ fixture: UITestGit) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-window-state", UUID().uuidString]
        app.launchEnvironment["WEGIT_UI_TEST_PREFERENCE_DOMAIN"] =
            "com.willxue.wegit.UITests." + UUID().uuidString
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        return app
    }

    @MainActor private func replace(_ field: XCUIElement, _ text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }
}
