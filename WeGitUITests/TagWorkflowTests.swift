import XCTest

final class TagWorkflowTests: XCTestCase {
    @MainActor func testCreateCancelInspectAndDeleteLocalTagPreservesBranch() throws {
        continueAfterFailure = false
        let f = try fixture()
        defer { f.remove() }
        let head = try f.git(["rev-parse", "HEAD"])
        let app = launch(f)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["toolbar-sidebar"].waitForExistence(timeout: 10))
        app.typeKey("5", modifierFlags: .command)
        let create = app.buttons["tag-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        waitEnabled(create)
        create.click()
        let name = app.textFields["tag-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("cancelled")
        app.windows["main"].sheets.firstMatch.buttons["取消"].click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try f.git(["tag", "--list"]), "")
        create.click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("main")
        let save = app.buttons["tag-save"]
        waitEnabled(save)
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try f.git(["rev-parse", "refs/tags/main"]), head)
        let target = app.descendants(matching: .any).matching(identifier: "tag-target").firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        XCTAssertTrue(target.label.contains(head.trimmingCharacters(in: .whitespacesAndNewlines)))
        let delete = app.buttons["tag-delete"]
        waitEnabled(delete)
        delete.click()
        let confirm = app.buttons["tag-delete-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(target.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try f.git(["tag", "--list"]), "")
        XCTAssertEqual(try f.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try f.git(["branch", "--show-current"]), "main\n")
        retain(app, "Tag workflow after confirmed local deletion")
    }

    @MainActor func testSingleTagPushRequiresEndpointConfirmationAndPreservesOtherTags() throws {
        continueAfterFailure = false
        let f = try fixture()
        defer { f.remove() }
        let bare = f.root.appending(path: ".git/remote.git")
        try f.git(["init", "--bare", bare.path])
        try f.git(["remote", "add", "origin", bare.path])
        try f.git(["tag", "-a", "chosen", "-m", "Chosen annotation"])
        try f.git(["tag", "-a", "other", "-m", "Other annotation"])
        try f.git(["config", "push.followTags", "true"])
        let object = try f.git(["rev-parse", "refs/tags/chosen"])
        let app = launch(f)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["toolbar-sidebar"].waitForExistence(timeout: 10))
        app.typeKey("5", modifierFlags: .command)
        let search = app.textFields["tag-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("chosen")
        let target = app.descendants(matching: .any).matching(identifier: "tag-target").firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        let push = app.buttons["tag-push"]
        waitEnabled(push)
        push.click()
        let next = app.buttons["tag-push-confirm"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        waitEnabled(next)
        next.click()
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "推送"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "value == %@", bare.path)).firstMatch.exists)
        retain(app, "One explicit tag and endpoint before push")
        next.click()
        XCTAssertTrue(next.waitForNonExistence(timeout: 15))
        XCTAssertEqual(
            try f.git(["--git-dir=" + bare.path, "for-each-ref", "--format=%(objectname)", "refs/tags/"]),
            object)
        XCTAssertEqual(try f.git(["tag", "--list"]), "chosen\nother\n")
    }

    private func fixture() throws -> UITestGit {
        let f = try UITestGit(prefix: "WeGitTagsUI")
        do {
            try f.git(["init", "-b", "main"])
            try f.git(["config", "user.name", "UI Fixture"])
            try f.git(["config", "user.email", "ui@example.invalid"])
            try f.git(["config", "commit.gpgsign", "false"])
            try f.git(["config", "tag.gpgsign", "false"])
            try Data("base\n".utf8).write(to: f.root.appending(path: "file.txt"))
            try f.git(["add", "."])
            try f.git(["commit", "-m", "Base"])
            return f
        } catch {
            f.remove()
            throw error
        }
    }
    @MainActor private func launch(_ f: UITestGit) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = f.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        return app
    }
    @MainActor private func waitEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
    @MainActor private func retain(_ app: XCUIApplication, _ title: String) {
        let screenshot = XCTAttachment(screenshot: app.windows["main"].screenshot())
        screenshot.name = title
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
