import XCTest

final class RemoteManagementWorkflowTests: XCTestCase {
    @MainActor func testAddEditCancelAndRemoveRepositoryRemote() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitRemoteUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let a = fixture.root.appending(path: ".git/ui-remote-a.git")
        let b = fixture.root.appending(path: ".git/ui-remote-b.git")
        try fixture.git(["init", "--bare", a.path])
        try fixture.git(["init", "--bare", b.path])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["toolbar-more"].waitForExistence(timeout: 10))
        app.buttons["toolbar-more"].click()
        app.menuItems["remote-management"].click()
        let addRemote = app.buttons["remote-add"]
        XCTAssertTrue(addRemote.waitForExistence(timeout: 5))
        waitEnabled(addRemote)
        addRemote.click()
        let name = app.textFields["remote-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("origin")
        let fetch = app.textFields["remote-fetch-url"]
        fetch.click()
        fetch.typeText(a.path)
        let save = app.buttons["remote-save"]
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["config", "--get", "remote.origin.url"]), a.path + "\n")
        let edit = app.buttons["remote-edit"]
        waitEnabled(edit)
        edit.click()
        XCTAssertTrue(fetch.waitForExistence(timeout: 5))
        fetch.click()
        fetch.typeKey("a", modifierFlags: .command)
        fetch.typeText(b.path)
        app.windows["main"].sheets.firstMatch.buttons["取消"].click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try fixture.git(["config", "--get", "remote.origin.url"]), a.path + "\n")
        edit.click()
        XCTAssertTrue(fetch.waitForExistence(timeout: 5))
        fetch.click()
        fetch.typeKey("a", modifierFlags: .command)
        fetch.typeText(b.path)
        app.checkBoxes["remote-separate-push"].click()
        let push = app.textFields["remote-push-url"]
        XCTAssertTrue(push.waitForExistence(timeout: 5))
        push.click()
        push.typeText(a.path)
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["config", "--get", "remote.origin.url"]), b.path + "\n")
        XCTAssertEqual(try fixture.git(["config", "--get", "remote.origin.pushurl"]), a.path + "\n")
        let displayed = app.staticTexts["remote-fetch-value"]
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", b.path), object: displayed)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed)
        app.buttons["remote-delete"].click()
        let confirm = app.buttons["remote-delete-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.windows["main"].sheets.firstMatch.buttons["取消"].click()
        XCTAssertEqual(try fixture.git(["remote"]), "origin\n")
        app.buttons["remote-delete"].click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == false"), object: edit)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertEqual(try fixture.git(["remote"]), "")
        let shot = XCTAttachment(screenshot: app.windows["main"].screenshot())
        shot.name = "Remote management after confirmed removal"
        shot.lifetime = .keepAlways
        add(shot)
    }
    @MainActor private func waitEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
}
