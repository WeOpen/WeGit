import XCTest

/// Hosted execution only. Fixtures and preferences belong to this test run.
final class WorkspaceDeliveryWorkflowTests: XCTestCase {
    @MainActor func testShortcutChangeClearReopenAndRestoreUseNativeMenu() throws {
        continueAfterFailure = false
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let app = launch(fixture)
        defer { app.terminate() }
        openShortcutSettings(app)
        let edit = app.buttons["shortcut-edit-search"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        let recorder = app.descendants(matching: .any).matching(identifier: "shortcut-recorder").firstMatch
        XCTAssertTrue(recorder.waitForExistence(timeout: 5))
        recorder.click()
        app.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["此快捷键由 macOS 或系统编辑操作使用。"].waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .option])
        XCTAssertTrue(recorder.waitForNonExistence(timeout: 5))
        closeShortcutSettings(app)
        app.windows["main"].typeKey("g", modifierFlags: [.command, .option])
        let search = app.textFields["repository-search-query"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.windows["main"].sheets.firstMatch.buttons["关闭"].click()
        openShortcutSettings(app)
        edit.click()
        app.buttons["shortcut-clear"].click()
        closeShortcutSettings(app)
        app.terminate()
        app.launchArguments += ["--uitesting-keep-preferences"]
        app.launchWeGit()
        openShortcutSettings(app)
        XCTAssertEqual(app.buttons["shortcut-edit-search"].value as? String, "未设置")
        app.buttons["shortcut-restore-all"].click()
        closeShortcutSettings(app)
        app.windows["main"].typeKey("f", modifierFlags: [.command, .shift])
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        retain(app, "Restored native repository search shortcut")
    }

    @MainActor func testUnifiedSearchOpensExactPathTagStashAndCommand() throws {
        continueAfterFailure = false
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try fixture.git(["tag", "chosen"])
        try fixture.git(["tag", "chosen-other"])
        try Data("stash bytes\n".utf8).write(to: fixture.root.appending(path: "plain.txt"))
        try fixture.git(["stash", "push", "-m", "Chosen stash"])
        let chosenStash = try fixture.git(["rev-parse", "stash@{0}"]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        try Data("other stash bytes\n".utf8).write(to: fixture.root.appending(path: "plain.txt"))
        try fixture.git(["stash", "push", "-m", "Other stash"])
        let otherStash = try fixture.git(["rev-parse", "stash@{0}"]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        let index = try Data(contentsOf: fixture.root.appending(path: ".git/index"))
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = launch(fixture)
        defer { app.terminate() }
        openSearch(app, scope: "已跟踪路径", query: "plain.txt")
        app.buttons["打开结果"].click()
        let path = app.textFields["file-history-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 10))
        XCTAssertEqual(path.value as? String, "plain.txt")
        app.buttons["file-history-close"].click()
        openSearch(app, scope: "标签", query: "chosen")
        app.buttons["打开结果"].click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "tag-row:chosen").firstMatch
                .waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "tag-target").firstMatch.waitForExistence(
                timeout: 10))
        let tag = app.staticTexts["tag-selected-reference"]
        waitLabel(tag, "refs/tags/chosen")
        openSearch(app, scope: "标签", query: "chosen-other")
        app.buttons["打开结果"].click()
        waitLabel(tag, "refs/tags/chosen-other")
        openSearch(app, scope: "储藏", query: "Chosen stash")
        app.buttons["打开结果"].click()
        waitSelectedStash(app, reference: "stash@{1}", objectID: chosenStash)
        let stash = app.staticTexts["stash-selected-object"]
        waitLabel(stash, chosenStash)
        openSearch(app, scope: "储藏", query: "Other stash")
        app.buttons["打开结果"].click()
        waitSelectedStash(app, reference: "stash@{0}", objectID: otherStash)
        waitLabel(stash, otherStash)
        openSearch(app, scope: "命令", query: "活动记录")
        app.buttons["打开结果"].click()
        XCTAssertTrue(
            app.windows["main"].sheets.firstMatch.staticTexts["活动记录"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: ".git/index")), index)
        retain(app, "Unified search navigated existing objects without Git writes")
    }

    @MainActor func testUnconfiguredUpdatesKeepDraftAndUseOneWindow() throws {
        continueAfterFailure = false
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let head = try fixture.git(["rev-parse", "HEAD"])
        let index = try Data(contentsOf: fixture.root.appending(path: ".git/index"))
        let app = launch(fixture)
        defer { app.terminate() }
        let draft = app.textFields["commit-message"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.click()
        draft.typeText("更新前草稿 🧪")
        app.menuBars.menuBarItems["native-menu-app"].click()
        app.menuItems["native-command-updates"].click()
        let updates = app.windows["update-window"]
        XCTAssertTrue(updates.waitForExistence(timeout: 5))
        XCTAssertTrue(updates.staticTexts["更新验证公钥尚未配置，请使用官网下载。"].waitForExistence(timeout: 5))
        XCTAssertFalse(updates.buttons["update-check"].isEnabled)
        updates.buttons["update-close"].click()
        XCTAssertTrue(updates.waitForNonExistence(timeout: 5))
        app.menuBars.menuBarItems["native-menu-app"].click()
        app.menuItems["native-command-updates"].click()
        XCTAssertTrue(updates.waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.matching(identifier: "update-window").count, 1)
        updates.buttons["update-close"].click()
        XCTAssertEqual(draft.value as? String, "更新前草稿 🧪")
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: ".git/index")), index)
        retain(app, "Update configuration boundary preserved the commit draft")
    }

    private func makeFixture() throws -> UITestGit {
        let fixture = try UITestGit(prefix: "WeGitWorkspaceDelivery")
        do {
            try fixture.git(["init", "-b", "main"])
            try fixture.git(["config", "user.name", "UI Fixture"])
            try fixture.git(["config", "user.email", "ui@example.invalid"])
            try fixture.git(["config", "commit.gpgsign", "false"])
            try Data("original\r\n".utf8).write(to: fixture.root.appending(path: "plain.txt"))
            try fixture.git(["add", "."])
            try fixture.git(["commit", "-m", "Initial"])
            return fixture
        } catch {
            fixture.remove()
            throw error
        }
    }

    @MainActor private func launch(_ fixture: UITestGit) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-window-state", UUID().uuidString]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        return app
    }

    @MainActor private func openShortcutSettings(_ app: XCUIApplication) {
        app.menuBars.menuBarItems["native-menu-app"].click()
        app.menuItems["native-command-settings"].click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.radioButtons["高级"].firstMatch.click()
        let button = app.buttons["settings-shortcuts"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        let search = settings.sheets.firstMatch.textFields["shortcut-command-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("搜索")
    }

    @MainActor private func closeShortcutSettings(_ app: XCUIApplication) {
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        settings.sheets.firstMatch.buttons["关闭"].click()
        settings.buttons[XCUIIdentifierCloseWindow].click()
    }

    @MainActor private func openSearch(_ app: XCUIApplication, scope: String, query: String) {
        app.menuBars.menuBarItems["native-menu-repository"].click()
        app.menuItems["native-command-search"].click()
        let field = app.textFields["repository-search-query"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let picker = app.popUpButtons["repository-search-scope"]
        picker.click()
        picker.menuItems[scope].click()
        field.click()
        field.typeText(query)
        let open = app.buttons["打开结果"]
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
                ], timeout: 10), .completed)
    }

    @MainActor private func retain(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func waitLabel(_ element: XCUIElement, _ label: String) {
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "label == %@", label), object: element)
                ], timeout: 10), .completed)
    }

    @MainActor private func waitSelectedStash(_ app: XCUIApplication, reference: String, objectID: String) {
        let rows = app.outlines["stash-list"].outlineRows.containing(
            .staticText, identifier: "stash-record:" + reference + "|" + objectID)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "selected == true"), object: rows.element)
                ],
                timeout: 10), .completed)
    }
}
