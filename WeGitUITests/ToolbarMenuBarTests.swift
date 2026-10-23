import AppKit
import XCTest

final class ToolbarMenuBarTests: XCTestCase {
    @MainActor func testToolbarHeightsAndUpstreamCountsRefreshTogether() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitSyncCountsUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Fixture"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        try fixture.git(["commit", "--allow-empty", "-m", "Base"])
        let base = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["remote", "add", "origin", fixture.root.path])
        for index in 1...3 {
            try fixture.git(["commit", "--allow-empty", "-m", "Remote \(index)"])
        }
        try fixture.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try fixture.git(["branch", "--set-upstream-to=origin/main", "main"])
        try fixture.git(["reset", "--hard", base])
        for index in 1...2 {
            try fixture.git(["commit", "--allow-empty", "-m", "Local \(index)"])
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["工作区干净"].firstMatch.waitForExistence(timeout: 10))
        let window = app.windows["main"]
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -1, dy: -1))
        corner.click(
            forDuration: 0.2,
            thenDragTo: corner.withOffset(
                CGVector(dx: 1400 - window.frame.width, dy: 760 - window.frame.height)))
        let pull = app.buttons["toolbar-pull"]
        let push = app.buttons["toolbar-push"]
        XCTAssertTrue(pull.waitForExistence(timeout: 5))
        XCTAssertEqual(pull.value as? String, "3")
        XCTAssertEqual(push.value as? String, "2")
        let sidebar = app.buttons["toolbar-sidebar"]
        let screenshot = window.screenshot()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
        let reference = toolbarSurface(bitmap, window: window.frame, control: sidebar.frame)
        XCTAssertGreaterThan(reference.contrast, 0.025)
        XCTAssertEqual(reference.height, 36, accuracy: 3)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Visible toolbar surfaces before compact layout"
        attachment.lifetime = .keepAlways
        add(attachment)
        for identifier in [
            "toolbar-repository", "toolbar-fetch", "toolbar-pull", "toolbar-push", "toolbar-search",
            "toolbar-inspector", "toolbar-more",
        ] {
            // Native toolbar AX buttons can span the entire 52pt titlebar even
            // when their material is 36pt. Compare rendered edges, retaining AX
            // hit testing and vertical alignment as separate assertions.
            let buttons = app.buttons.matching(identifier: identifier)
            let popups = app.popUpButtons.matching(identifier: identifier)
            let control =
                buttons.firstMatch.exists
                ? buttons.firstMatch
                : popups.firstMatch.exists
                    ? popups.firstMatch
                    : app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(control.isHittable, identifier)
            let surface = toolbarSurface(bitmap, window: window.frame, control: control.frame)
            print(
                "Toolbar \(identifier): AX \(control.frame), visible height \(surface.height), edge contrast \(surface.contrast)"
            )
            XCTAssertGreaterThan(surface.contrast, 0.025, identifier)
            XCTAssertEqual(surface.height, reference.height, accuracy: 2, identifier)
            XCTAssertEqual(control.frame.midY, sidebar.frame.midY, accuracy: 1, identifier)
        }
        let compactCorner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -1, dy: -1))
        compactCorner.click(
            forDuration: 0.2,
            thenDragTo: compactCorner.withOffset(CGVector(dx: 980 - window.frame.width, dy: 0)))
        let compactPull = app.toolbarSyncAction("toolbar-pull")
        let compactScreenshot = XCTAttachment(screenshot: window.screenshot())
        compactScreenshot.name = "Compact sync menu and counts"
        compactScreenshot.lifetime = .keepAlways
        add(compactScreenshot)
        XCTAssertEqual(compactPull.title, "拉取 3")
        XCTAssertEqual(window.menuItems.matching(identifier: "toolbar-push").firstMatch.title, "推送 2")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let expandCorner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -1, dy: -1))
        expandCorner.click(
            forDuration: 0.2,
            thenDragTo: expandCorner.withOffset(CGVector(dx: 1400 - window.frame.width, dy: 0)))
        XCTAssertTrue(push.waitForExistence(timeout: 5))
        try fixture.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        app.buttons["刷新"].click()
        let synchronized = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "0"), object: push)
        XCTAssertEqual(XCTWaiter.wait(for: [synchronized], timeout: 10), .completed)
        XCTAssertEqual(pull.value as? String, "0")
        try fixture.git(["branch", "--unset-upstream"])
        app.buttons["刷新"].click()
        let unknown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "待核对"), object: push)
        XCTAssertEqual(XCTWaiter.wait(for: [unknown], timeout: 10), .completed)
        XCTAssertEqual(pull.value as? String, "待核对")
    }

    @MainActor private func toolbarSurface(_ image: NSBitmapImageRep, window: CGRect, control: CGRect)
        -> (height: CGFloat, contrast: Double)
    {
        let center = CGPoint(x: control.midX - window.minX, y: control.midY - window.minY)
        let scaleX = CGFloat(image.pixelsWide) / window.width
        let scaleY = CGFloat(image.pixelsHigh) / window.height
        func tone(_ dx: CGFloat, _ dy: CGFloat) -> Double? {
            let point = CGPoint(x: center.x + dx, y: center.y + dy)
            // Do not mistake the black desktop above a full-height AX cell for
            // a material edge. PNG rows use the screenshot's top-left origin.
            guard point.x >= 3, point.y >= 3, point.x < window.width - 3, point.y < window.height - 3,
                let color = image.colorAt(x: Int(point.x * scaleX), y: Int(point.y * scaleY))?
                    .usingColorSpace(.sRGB)
            else { return nil }
            return Double((color.redComponent + color.greenComponent + color.blueComponent) / 3)
        }
        let corners = [tone(-20, -20), tone(20, -20), tone(-20, 20), tone(20, 20)].compactMap { $0 }
        guard corners.count == 4 else { return (0, 0) }
        let background = corners.reduce(0, +) / 4
        var best: (height: CGFloat, contrast: Double) = (0, 0)
        for radius in stride(from: CGFloat(12), through: min(30, max(20, control.height / 2 + 2)), by: 0.5) {
            for sign in [CGFloat(-1), 1] {
                let row = (-2...2).compactMap { tone(CGFloat($0), sign * radius) }
                guard row.count == 5 else { continue }
                let contrast = abs(row.reduce(0, +) / 5 - background)
                if contrast > best.contrast { best = (radius * 2, contrast) }
            }
        }
        return best
    }

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

    /// Include the material's edge: a native glass interior can be completely
    /// transparent on a uniform toolbar while the circular rim remains visible.
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
        return [CGFloat(14), 16.5, 17, 17.5].map { radius in
            let annulus = (0..<32).map { index in
                let angle = CGFloat(index) * .pi / 16
                return tone(cos(angle) * radius, sin(angle) * radius)
            }
            return abs(annulus.reduce(0, +) / Double(annulus.count) - outside)
        }.max() ?? 0
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
