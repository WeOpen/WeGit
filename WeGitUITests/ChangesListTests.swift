import XCTest

final class ChangesListTests: XCTestCase {
    @MainActor func testCollapsibleGroupsAndFilteredStageCheckboxes() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitChangesListUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        for path in ["src/api/client.swift", "src/api/session.swift", "root.txt"] {
            let url = fixture.root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("before\n".utf8).write(to: url)
        }
        try fixture.git(["add", "."])
        try fixture.git([
            "-c", "user.name=UI Test", "-c", "user.email=ui@example.invalid", "-c", "commit.gpgSign=false",
            "commit", "-m", "List fixture",
        ])
        for path in ["src/api/client.swift", "src/api/session.swift", "root.txt"] {
            try Data("after\n".utf8).write(to: fixture.root.appending(path: path))
        }
        try Data("new\n".utf8).write(to: fixture.root.appending(path: "new.txt"))
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let checkbox = app.checkBoxes["stage:unstaged:src/api/client.swift"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 10))
        let list = app.descendants(matching: .any).matching(identifier: "changes-list").firstMatch
        list.staticTexts["client.swift"].firstMatch.click()
        XCTAssertEqual(try fixture.git(["diff", "--cached", "--name-only"]), "")
        let message = app.descendants(matching: .any).matching(identifier: "commit-message").firstMatch
        message.click()
        message.typeText("Preserve this draft")
        let group = list.outlineRows.containing(.checkBox, identifier: "stage-group:unstaged").firstMatch
        group.click()
        XCTAssertFalse(list.staticTexts["client.swift"].exists)
        XCTAssertEqual(message.value as? String, "Preserve this draft")
        group.click()
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        let filter = app.textFields["changes-filter"]
        filter.click()
        filter.typeText("client.swift")
        XCTAssertFalse(app.checkBoxes["stage:unstaged:src/api/session.swift"].exists)
        app.checkBoxes["stage-group:unstaged"].click()
        XCTAssertTrue(app.checkBoxes["stage:staged:src/api/client.swift"].waitForExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["diff", "--cached", "--name-only"]), "src/api/client.swift\n")
        XCTAssertEqual(
            try String(contentsOf: fixture.root.appending(path: "src/api/client.swift"), encoding: .utf8),
            "after\n")
        filter.click()
        filter.typeKey("a", modifierFlags: .command)
        filter.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        app.descendants(matching: .any).matching(identifier: "changes-display-mode").firstMatch.click()
        app.menuItems["按文件夹显示"].click()
        let folder = list.outlineRows.containing(.checkBox, identifier: "stage-folder:unstaged|src")
            .firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.click()
        XCTAssertFalse(app.checkBoxes["stage:unstaged:src/api/session.swift"].exists)
        folder.click()
        XCTAssertTrue(app.checkBoxes["stage:unstaged:src/api/session.swift"].waitForExistence(timeout: 5))
        app.checkBoxes["stage:staged:src/api/client.swift"].click()
        XCTAssertTrue(app.checkBoxes["stage:unstaged:src/api/client.swift"].waitForExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["diff", "--cached", "--name-only"]), "")
        XCTAssertEqual(message.value as? String, "Preserve this draft")
    }
}
