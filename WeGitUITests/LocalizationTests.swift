import AppKit
import XCTest

final class LocalizationUITests: XCTestCase {
    @MainActor func testLanguageSwitchKeepsDraftAndGitDataAndCommitButtonsMatch() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitLocalizationUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let filename = "源代码🙂.swift"
        let file = fixture.root.appending(path: filename)
        try Data("let value = \"中文 %1$@\"\n".utf8).write(to: file)
        try fixture.git(["add", "."])
        try fixture.git([
            "-c", "user.name=UI Fixture", "-c", "user.email=ui@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", "原始提交 English %1$@",
        ])
        try Data("let value = \"中文 %1$@ changed\"\n".utf8).write(to: file)
        let status = try fixture.git(["status", "--porcelain=v1"])
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitesting", "-language", "en", "-AppleLanguages", "(en)",
        ]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let processIDs = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.willxue.wegit.development"
        ).map(\.processIdentifier).sorted()
        let message = app.textFields["commit-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        let draft = "提交 draft 中文🙂 100% %1$@"
        message.click()
        message.typeText(draft)
        let commit = app.buttons["commit-button"]
        let push = app.buttons["commit-push-button"]
        XCTAssertEqual(commit.label, "Commit (0 files)")
        XCTAssertEqual(push.label, "Commit and Push…")
        XCTAssertEqual(commit.frame.height, push.frame.height, accuracy: 1)
        let workspaceLeft = app.outlines["changes-list"].frame.minX
        XCTAssertGreaterThanOrEqual(message.frame.minX, workspaceLeft)
        XCTAssertGreaterThanOrEqual(
            app.descendants(matching: .any).matching(identifier: "commit-staged-count").firstMatch.frame.minX,
            workspaceLeft)
        XCTAssertTrue(app.outlines["changes-list"].staticTexts[filename].firstMatch.exists)
        for (choice, expected) in [
            ("简体中文", "提交（0 个文件）"), ("English", "Commit (0 files)"), ("简体中文", "提交（0 个文件）"),
            ("English", "Commit (0 files)"),
        ] {
            app.typeKey(",", modifierFlags: .command)
            let general = app.radioButtons.matching(NSPredicate(format: "label IN %@", ["General", "通用"]))
                .firstMatch
            XCTAssertTrue(general.waitForExistence(timeout: 5))
            general.click()
            let language = app.popUpButtons["settings-language"]
            XCTAssertTrue(language.waitForExistence(timeout: 5))
            language.click()
            app.menuItems[choice].click()
            XCTAssertFalse(app.buttons["settings-language-restart"].exists)
            let fileMenu = app.menuBars.menuBarItems["native-menu-file"]
            XCTAssertEqual(fileMenu.label, choice == "English" ? "File" : "文件")
            fileMenu.click()
            XCTAssertEqual(app.menuItems["native-command-close"].label, choice == "English" ? "Close" : "关闭")
            app.typeKey(.escape, modifierFlags: [])
            app.menuBars.menuBarItems["native-menu-edit"].click()
            XCTAssertEqual(app.menuItems["native-command-copy"].label, choice == "English" ? "Copy" : "拷贝")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertEqual(
                NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.willxue.wegit.development"
                ).map(\.processIdentifier).sorted(), processIDs)
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            XCTAssertEqual(commit.label, expected)
            XCTAssertEqual(message.value as? String, draft)
            XCTAssertTrue(app.outlines["changes-list"].staticTexts[filename].firstMatch.exists)
        }
        app.typeKey("2", modifierFlags: .command)
        let search = app.textFields["history-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(search.frame.width, 150)
        XCTAssertTrue(app.popUpButtons["history-scope"].isHittable)
        XCTAssertTrue(app.popUpButtons["history-search-field"].isHittable)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), status)
        XCTAssertEqual(try fixture.git(["log", "-1", "--format=%s"]), "原始提交 English %1$@\n")
    }
}
