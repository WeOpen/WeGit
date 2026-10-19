import XCTest

final class InterfacePolishTests: XCTestCase {
    @MainActor func testSearchClearKeepsInputFocusAndKeyboardCommitInBothThemes() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let fixture = try UITestGit(prefix: "WeGitInterfacePolish")
            defer { fixture.remove() }
            try fixture.git(["init", "-b", "main"])
            try fixture.git(["config", "user.name", "UI Fixture"])
            try fixture.git(["config", "user.email", "ui@example.invalid"])
            try fixture.git(["config", "commit.gpgsign", "false"])
            let file = fixture.root.appending(path: "Interface.swift")
            try Data("let interface = 1\n".utf8).write(to: file)
            try fixture.git(["add", "."])
            try fixture.git(["commit", "-m", "Interface fixture"])
            try Data("let interface = 2\n".utf8).write(to: file)
            let app = XCUIApplication()
            app.launchArguments = [
                "--uitesting", "-appearance", appearance,
                "-density", appearance == "dark" ? "compact" : "comfortable",
            ]
            app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
            app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
            app.launchWeGit()
            defer { app.terminate() }
            if appearance == "dark" {
                app.menuBars.menuBarItems["WeGit"].click()
                app.menuItems["native-command-settings"].click()
                let settings = app.windows["com_apple_SwiftUI_Settings_window"]
                let tab = settings.radioButtons["外观"]
                XCTAssertTrue(tab.waitForExistence(timeout: 5))
                tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
                let motion = app.switches["settings-interface-motion"]
                XCTAssertTrue(motion.waitForExistence(timeout: 5))
                XCTAssertEqual(motion.value as? Int, 1)
                motion.click()
                XCTAssertEqual(motion.value as? Int, 0)
                settings.buttons[XCUIIdentifierCloseWindow].click()
            }
            let search = app.textFields["changes-filter"]
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            let stagedCount = app.descendants(matching: .any).matching(identifier: "commit-staged-count")
                .firstMatch
            XCTAssertEqual(stagedCount.label, "已暂存 0 个文件")
            search.click()
            search.typeText("missing")
            XCTAssertTrue(app.staticTexts["没有匹配文件"].waitForExistence(timeout: 5))
            let clear = app.buttons["changes-filter-clear"]
            XCTAssertTrue(clear.isHittable)
            clear.click()
            XCTAssertEqual(search.value as? String, "")
            // Typing at the application level proves that clearing returns focus to the field.
            app.typeText("Interface")
            XCTAssertEqual(search.value as? String, "Interface")
            let row = app.outlines["changes-list"].staticTexts["Interface.swift"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            clear.click()
            row.click()
            XCTAssertTrue(app.scrollViews["diff-content"].waitForExistence(timeout: 5))
            let headBeforeReading = try fixture.git(["rev-parse", "HEAD"])
            let statusBeforeReading = try fixture.git(["--no-optional-locks", "status", "--porcelain=v1"])
            // git status must not refresh the index and trigger the app's watcher
            // while XCTest is moving the pointer to the diff header.
            XCTAssertTrue(app.staticTexts["正在核对差异…"].waitForNonExistence(timeout: 5))
            let unified = app.radioButtons["统一"]
            let split = app.radioButtons["分栏"]
            XCTAssertTrue(unified.isHittable)
            unified.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertEqual(String(describing: unified.value ?? ""), "1")
            let beforeArrow = XCTAttachment(string: app.debugDescription)
            beforeArrow.name = "Diff tabs focus before arrow - " + appearance
            beforeArrow.lifetime = .keepAlways
            add(beforeArrow)
            app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
            let afterArrow = XCTAttachment(string: app.debugDescription)
            afterArrow.name = "Diff tabs focus after arrow - " + appearance
            afterArrow.lifetime = .keepAlways
            add(afterArrow)
            XCTAssertEqual(String(describing: split.value ?? ""), "1")
            XCTAssertTrue(app.descendants(matching: .any)["diff-column-headers"].exists)
            app.typeKey(XCUIKeyboardKey.leftArrow, modifierFlags: [])
            XCTAssertEqual(String(describing: unified.value ?? ""), "1")
            XCTAssertFalse(app.descendants(matching: .any)["diff-column-headers"].exists)
            XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), headBeforeReading)
            XCTAssertEqual(
                try fixture.git(["--no-optional-locks", "status", "--porcelain=v1"]), statusBeforeReading)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Polished workspace - \(appearance)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.checkBoxes["stage:unstaged:Interface.swift"].click()
            XCTAssertTrue(app.checkBoxes["stage:staged:Interface.swift"].waitForExistence(timeout: 5))
            XCTAssertEqual(stagedCount.label, "已暂存 1 个文件")
            let message = app.textFields["commit-message"]
            message.click()
            let subject = "Keyboard commit in \(appearance) appearance"
            let body = "Keep the native editor focus and preserve the detailed message."
            message.typeText(subject)
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: .option)
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: .option)
            app.typeText(body)
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: .command)
            XCTAssertTrue(app.staticTexts["工作区干净"].waitForExistence(timeout: 10))
            XCTAssertEqual(try fixture.git(["log", "-1", "--format=%s"]), subject + "\n")
            XCTAssertEqual(
                try fixture.git(["log", "-1", "--format=%B"]).trimmingCharacters(in: .newlines),
                subject + "\n\n" + body)
            XCTAssertEqual(stagedCount.label, "已暂存 0 个文件")
            app.terminate()
        }
    }
}
