import XCTest

final class GitConfigurationInterfaceTests: XCTestCase {
    @MainActor func testGlobalAndLocalEditsUseOnlyTheirExplicitScope() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitConfigurationUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let global = fixture.root.appendingPathExtension("global-config")
        try Data("[user]\n name = Inherited Fixture Name\n".utf8).write(to: global)
        defer { try? FileManager.default.removeItem(at: global) }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = global.path
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        app.menuBars.menuBarItems["WeGit"].click()
        app.menuItems["Settings…"].click()
        let tab = app.buttons["Git"].firstMatch
        if tab.waitForExistence(timeout: 3) { tab.click() } else { app.radioButtons["Git"].click() }
        let scope = app.popUpButtons["git-setting-scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.click()
        app.menuItems["全局"].click()
        func edit(_ value: String) throws {
            app.buttons["edit-setting:user.name"].click()
            let field = app.textFields["git-setting-value"]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeText(value)
            app.buttons["git-setting-save"].click()
            let closed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: field)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        }
        try edit("Global Fixture Name")
        XCTAssertEqual(
            try fixture.git(["config", "--file", global.path, "--get", "user.name"]), "Global Fixture Name\n")
        XCTAssertFalse(try fixture.git(["config", "--local", "--list"]).contains("user.name="))
        scope.click()
        app.menuItems["当前仓库"].click()
        try edit("Local Fixture Name")
        XCTAssertEqual(try fixture.git(["config", "--local", "--get", "user.name"]), "Local Fixture Name\n")
        XCTAssertEqual(
            try fixture.git(["config", "--file", global.path, "--get", "user.name"]), "Global Fixture Name\n")
        app.buttons["edit-setting:user.name"].click()
        app.buttons["移除此作用域的设置"].click()
        let inherited = app.staticTexts["Global Fixture Name"].firstMatch
        XCTAssertTrue(inherited.waitForExistence(timeout: 5))
        let local = try fixture.git(["config", "--local", "--list"])
        XCTAssertFalse(local.contains("user.name="))
        XCTAssertEqual(
            try fixture.git(["config", "--file", global.path, "--get", "user.name"]), "Global Fixture Name\n")
    }
}
