import AppKit
import XCTest

final class ToolbarMenuBarTests: XCTestCase {
    @MainActor func testSidebarButtonRetainsItsSurfaceAfterRepeatedToggles() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitSidebarSurfaceUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-appearance", "dark"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["工作区干净"].firstMatch.waitForExistence(timeout: 10))
        let window = app.windows["main"]
        for closed in [true, false, true, false] {
            let toggle = app.buttons["toolbar-sidebar"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.click()
            let value = closed ? "已关闭" : "已打开"
            let state = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", value), object: toggle)
            XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 5), .completed)
            let surface = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    self.sidebarSurfaceDifference(window: window, button: toggle) > 0.025
                }, object: nil)
            let rendered = XCTWaiter.wait(for: [surface], timeout: 5)
            let image = XCTAttachment(screenshot: window.screenshot())
            image.name = "Sidebar surface - " + value
            image.lifetime = .keepAlways
            add(image)
            XCTAssertEqual(rendered, .completed, "Sidebar button lost its circular background")
        }
    }

    /// Compare an icon-free annulus of the 36pt control with its outside corners.
    /// A bare sidebar glyph has no material in this annulus.
    @MainActor private func sidebarSurfaceDifference(window: XCUIElement, button: XCUIElement) -> Double {
        guard let image = NSBitmapImageRep(data: window.screenshot().pngRepresentation),
            window.frame.width > 0, window.frame.height > 0
        else { return 0 }
        let xScale = CGFloat(image.pixelsWide) / window.frame.width
        let yScale = CGFloat(image.pixelsHigh) / window.frame.height
        let center = CGPoint(
            x: button.frame.midX - window.frame.minX, y: button.frame.midY - window.frame.minY)
        func tone(_ dx: CGFloat, _ dy: CGFloat) -> Double {
            let x = Int((center.x + dx) * xScale)
            let y = Int((center.y + dy) * yScale)
            guard x >= 0, y >= 0, x < image.pixelsWide, y < image.pixelsHigh,
                let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            else { return 0 }
            return Double((color.redComponent + color.greenComponent + color.blueComponent) / 3)
        }
        let corners = [tone(-17, -17), tone(17, -17), tone(-17, 17), tone(17, 17)]
        let outside = corners.reduce(0, +) / Double(corners.count)
        let annulus = (0..<32).map { index in
            let angle = CGFloat(index) * .pi / 16
            return tone(cos(angle) * 14, sin(angle) * 14)
        }
        return abs(annulus.reduce(0, +) / Double(annulus.count) - outside)
    }

    @MainActor func testMenuBarReopensClosedWindowWithoutLosingDraftAndRefreshesExternalChanges() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitMenuBarUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Fixture"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        let file = fixture.root.appending(path: "MenuBar.swift")
        try Data("let state = 1\n".utf8).write(to: file)
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Menu bar fixture"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-menu-bar"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let message = app.textFields["commit-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.click()
        message.typeText("Keep this draft across menu bar navigation")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.outlines["history-list"].waitForExistence(timeout: 10))
        app.windows["main"].typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.windows["main"].exists)
        try Data("let state = 2\n".utf8).write(to: file)
        app.typeKey("m", modifierFlags: [.command, .shift])
        // AppKit can combine adjacent static text in the popover; assert its actual
        // announced state rather than assuming that each Text keeps a separate node.
        let state = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "1 个文件有改动", "1 个文件有改动")
        ).firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        app.buttons["menu-bar-open-main"].click()
        XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.outlines["history-list"].exists)
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.value as? String, "Keep this draft across menu bar navigation")
        XCTAssertEqual(try fixture.git(["log", "-1", "--format=%s"]), "Menu bar fixture\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let state = 2\n")
    }

    @MainActor func testCompactToolbarKeepsSyncAndMoreActionsReachable() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitCompactToolbarUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let window = app.windows["main"]
        XCTAssertTrue(app.staticTexts["工作区干净"].firstMatch.waitForExistence(timeout: 10))
        let initial = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -1, dy: -1))
        corner.click(
            forDuration: 0.2,
            thenDragTo: corner.withOffset(CGVector(dx: 980 - initial.width, dy: 693 - initial.height)))
        let sync = app.descendants(matching: .any).matching(identifier: "toolbar-sync").firstMatch
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        XCTAssertTrue(sync.isHittable)
        let pull = app.toolbarSyncAction("toolbar-pull")
        XCTAssertTrue(pull.waitForExistence(timeout: 3))
        XCTAssertFalse(pull.isEnabled)
        XCTAssertFalse(app.menuItems["推送"].isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let more = app.descendants(matching: .any).matching(identifier: "toolbar-more").firstMatch
        XCTAssertTrue(more.isHittable)
        more.click()
        let activity = app.windows["main"].menuItems["活动记录"]
        XCTAssertTrue(activity.waitForExistence(timeout: 3))
        activity.click()
        let activitySheet = window.sheets.firstMatch
        XCTAssertTrue(activitySheet.staticTexts["Git 活动"].waitForExistence(timeout: 5))
        XCTAssertTrue(activitySheet.buttons["关闭"].isHittable)
    }
}
