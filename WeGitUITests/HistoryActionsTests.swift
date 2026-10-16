import AppKit
import XCTest

final class HistoryActionsTests: XCTestCase {
    @MainActor func testCopyCheckoutAndBranchUseTheSelectedHistoricalCommit() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitHistoryActions")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "History Fixture"])
        try fixture.git(["config", "user.email", "history@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        let file = fixture.root.appending(path: "history.txt")
        try Data("first\n".utf8).write(to: file)
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Selected historical commit"])
        let selected = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("second\n".utf8).write(to: file)
        try fixture.git(["commit", "-am", "Current newer commit"])
        let main = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        app.typeKey("2", modifierFlags: .command)
        let row = app.outlines["history-list"].staticTexts["Selected historical commit"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let copy = app.buttons["history-copy-sha"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        UITestGit.preservingClipboard { clipboard in
            copy.click()
            XCTAssertEqual(clipboard.string(forType: .string), selected)
        }
        app.menuButtons["history-operations"].click()
        app.menuItems["检出此提交…"].click()
        app.buttons["检出提交"].firstMatch.click()
        let detached = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (try? fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines))
                    == selected
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [detached], timeout: 10), .completed)
        XCTAssertEqual(try fixture.git(["branch", "--show-current"]), "")
        XCTAssertEqual(
            try fixture.git(["rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines), main)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first\n")
        app.typeKey("2", modifierFlags: .command)
        row.click()
        let operations = app.menuButtons["history-operations"]
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: operations)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        operations.click()
        app.menuItems["从此提交新建分支…"].click()
        let name = app.textFields["branch-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("from-selected-history")
        name.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(name.value as? String, "from-selected-history")
        app.buttons["创建并切换"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let switched = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (try? fixture.git(["branch", "--show-current"])) == "from-selected-history\n"
            }, object: nil)
        let result = XCTWaiter.wait(for: [switched], timeout: 10)
        if result != .completed {
            let evidence = XCTAttachment(string: app.debugDescription)
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(
            try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), selected)
        XCTAssertEqual(
            try fixture.git(["rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines), main)
    }
}
