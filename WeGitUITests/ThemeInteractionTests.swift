import AppKit
import XCTest

final class ThemeInteractionTests: XCTestCase {
    @MainActor func testThemesUpdateOpenWindowsAndTabsKeepNeutralKeyboardFocus() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitThemeInteraction")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Fixture"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        let file = fixture.root.appending(path: "Theme.swift")
        try Data("let theme = 1\n".utf8).write(to: file)
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Theme fixture"])
        try Data("let theme = 2\n".utf8).write(to: file)
        let head = try fixture.git(["rev-parse", "HEAD"])
        let status = try fixture.git(["status", "--porcelain=v1"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-appearance", "system"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let row = app.outlines["changes-list"].staticTexts["Theme.swift"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let code = app.scrollViews["diff-content"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        let sidebar = app.buttons["toolbar-sidebar"]
        let inspector = app.buttons["toolbar-inspector"]
        // The native sidebar host exposes its glyph bounds; the regular toolbar
        // button includes padding. Their visible centers must remain aligned.
        XCTAssertTrue(sidebar.isHittable)
        XCTAssertTrue(inspector.isHittable)
        XCTAssertEqual(sidebar.frame.midY, inspector.frame.midY, accuracy: 2)
        let changes = app.scrollViews.containing(.outline, identifier: "changes-list").firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: 5))
        XCTAssertLessThan(sidebar.frame.maxX, changes.frame.minX + 2)
        let brand = app.staticTexts["sidebar-brand"]
        XCTAssertGreaterThan(brand.frame.midY, app.windows["main"].frame.midY)
        let add = app.buttons["sidebar-add-repository"]
        XCTAssertTrue(add.isHittable)
        XCTAssertTrue(app.windows["main"].frame.contains(add.frame))
        XCTAssertLessThan(add.frame.maxX, changes.frame.minX - 12)
        XCTAssertLessThan(add.frame.maxY, app.windows["main"].frame.maxY - 12)
        XCTAssertFalse(app.staticTexts["sidebar-repository-state"].exists)
        add.click()
        let openPanel = app.dialogs["open-panel"]
        XCTAssertTrue(openPanel.waitForExistence(timeout: 5))
        openPanel.buttons["CancelButton"].click()
        XCTAssertTrue(row.exists)
        sidebar.click()
        XCTAssertEqual(sidebar.value as? String, "已关闭")
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertEqual(sidebar.value as? String, "已打开")
        let systemLuminance = try luminance(at: backgroundPoint(code.frame))
        let draft = app.textFields["commit-message"]
        draft.click()
        draft.typeText("Preserve draft through theme changes")
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.radioButtons["外观"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let theme = settings.popUpButtons.matching(
            NSPredicate(format: "value IN %@", ["跟随系统", "浅色", "深色", "自定义"])
        ).firstMatch
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        let systemSettingsLuminance = try luminance(
            at: CGPoint(x: settings.frame.midX, y: settings.frame.maxY - 18))
        for (title, dark) in [("浅色", false), ("深色", true), ("浅色", false), ("深色", true)] {
            theme.click()
            app.menuItems[title].click()
            // Inspect both existing windows while Settings remains open. Activating
            // or reopening the workspace must not be required to update its theme.
            let main = try luminance(at: backgroundPoint(code.frame))
            let panel = try luminance(at: CGPoint(x: settings.frame.midX, y: settings.frame.maxY - 18))
            if dark {
                XCTAssertLessThan(main, 0.45)
                XCTAssertLessThan(panel, 0.45)
            } else {
                XCTAssertGreaterThan(main, 0.75)
                XCTAssertGreaterThan(panel, 0.75)
            }
            theme.click()
            app.menuItems["跟随系统"].click()
            XCTAssertEqual(try luminance(at: backgroundPoint(code.frame)), systemLuminance, accuracy: 0.08)
            XCTAssertEqual(
                try luminance(at: CGPoint(x: settings.frame.midX, y: settings.frame.maxY - 18)),
                systemSettingsLuminance, accuracy: 0.08)
        }
        theme.click()
        app.menuItems["跟随系统"].click()
        XCTAssertEqual(try luminance(at: backgroundPoint(code.frame)), systemLuminance, accuracy: 0.08)
        let git = settings.radioButtons["Git"]
        git.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertEqual(String(describing: git.value ?? ""), "1")
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertEqual(String(describing: settings.radioButtons["外观"].value ?? ""), "1")
        let tabs = settings.descendants(matching: .any)["settings-tabs"]
        XCTAssertLessThan(try bluePixelCount(in: tabs.frame), 20)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertEqual(draft.value as? String, "Preserve draft through theme changes")
        inspector.click()
        let pane = app.scrollViews["repository-inspector"]
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        theme.click()
        app.menuItems["浅色"].click()
        settings.buttons[XCUIIdentifierCloseWindow].click()
        // The native split stays draggable, with a semantic divider background
        // rather than a transparent gap revealing black in the Light appearance.
        for fraction in [0.3, 0.5, 0.7] {
            XCTAssertGreaterThan(
                try luminance(
                    at: CGPoint(x: pane.frame.minX - 0.5, y: pane.frame.minY + pane.frame.height * fraction)),
                0.5)
        }
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), status)
    }

    private func backgroundPoint(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.maxX - 12, y: rect.maxY - 12)
    }

    @MainActor private func capture() throws -> (NSBitmapImageRep, CGFloat, CGFloat) {
        let shot = XCUIScreen.main.screenshot()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: shot.pngRepresentation))
        return (
            bitmap, CGFloat(bitmap.pixelsWide) / shot.image.size.width,
            CGFloat(bitmap.pixelsHigh) / shot.image.size.height
        )
    }

    @MainActor private func luminance(at point: CGPoint) throws -> CGFloat {
        let (bitmap, sx, sy) = try capture()
        let color = try XCTUnwrap(
            bitmap.colorAt(x: Int(point.x * sx), y: Int(point.y * sy))?.usingColorSpace(.sRGB))
        return color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
    }

    @MainActor private func bluePixelCount(in rect: CGRect) throws -> Int {
        let (bitmap, sx, sy) = try capture()
        var count = 0
        for y in max(0, Int(rect.minY * sy))..<min(bitmap.pixelsHigh, Int(rect.maxY * sy)) {
            for x in max(0, Int(rect.minX * sx))..<min(bitmap.pixelsWide, Int(rect.maxX * sx)) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.blueComponent > c.redComponent + 0.25,
                    c.blueComponent > c.greenComponent + 0.12
                {
                    count += 1
                }
            }
        }
        return count
    }
}
