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
        let theme = settings.popUpButtons["settings-appearance"]
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        XCTAssertEqual(theme.label, "主题")
        XCTAssertEqual(settings.popUpButtons["settings-density"].label, "列表密度")
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
            let selectedRoute = app.staticTexts.matching(
                NSPredicate(format: "identifier == %@ AND value == %@", "route-更改", "更改")
            ).firstMatch
            XCTAssertGreaterThanOrEqual(try textContrast(in: selectedRoute.frame), 4.5)
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
        app.typeKey("2", modifierFlags: .command)
        let commit = app.outlines["history-list"].staticTexts["Theme fixture"].firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 5))
        commit.click()
        for title in ["浅色", "深色"] {
            app.typeKey(",", modifierFlags: .command)
            theme.click()
            app.menuItems[title].click()
            settings.buttons[XCUIIdentifierCloseWindow].click()
            let author = app.staticTexts.matching(
                NSPredicate(format: "value BEGINSWITH %@", "作者：")
            ).firstMatch
            XCTAssertTrue(author.waitForExistence(timeout: 5))
            XCTAssertTrue(app.windows["main"].frame.contains(author.frame))
            XCTAssertGreaterThanOrEqual(try textContrast(in: author.frame), 4.5)
            for identifier in ["history-scope", "history-search-field", "history-operations"] {
                let menu = app.windows["main"].descendants(matching: .any)
                    .matching(identifier: identifier).firstMatch
                XCTAssertTrue(menu.exists)
                let ready = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "enabled == true"), object: menu)
                XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
                XCTAssertGreaterThanOrEqual(
                    try textContrast(in: menu.frame.insetBy(dx: 8, dy: 6)), 4.5)
            }
            let reading = app.windows["main"].descendants(matching: .menuButton).matching(
                NSPredicate(format: "title == %@", "阅读选项")
            ).firstMatch
            XCTAssertTrue(reading.exists)
            XCTAssertGreaterThanOrEqual(try textContrast(in: reading.frame.insetBy(dx: 8, dy: 6)), 4.5)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Readable native colors - " + title
            screenshot.lifetime = .keepAlways
            self.add(screenshot)
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

    @MainActor private func textContrast(in frame: CGRect) throws -> Double {
        let (bitmap, sx, sy) = try capture()
        // A selected SwiftUI row can expose its full rounded background as the
        // text frame. Exclude its corners, which belong to the surrounding view.
        let rect = frame.width > 80 && frame.height > 30 ? frame.insetBy(dx: 5, dy: 5) : frame
        let xStart = max(0, Int(rect.minX * sx))
        let xEnd = min(bitmap.pixelsWide, Int(rect.maxX * sx))
        let yStart = max(0, Int(rect.minY * sy))
        let yEnd = min(bitmap.pixelsHigh, Int(rect.maxY * sy))
        guard xStart < xEnd, yStart < yEnd else {
            XCTFail("Text frame is outside the screen: \(frame)")
            return 0
        }
        var pixels: [UInt32: Int] = [:]
        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let red = UInt32((color.redComponent * 255).rounded())
                let green = UInt32((color.greenComponent * 255).rounded())
                let blue = UInt32((color.blueComponent * 255).rounded())
                pixels[red << 16 | green << 8 | blue, default: 0] += 1
            }
        }
        func luminance(_ rgb: UInt32) -> Double {
            let values = [rgb >> 16 & 255, rgb >> 8 & 255, rgb & 255].map { value in
                let channel = Double(value) / 255
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        let background = try XCTUnwrap(pixels.max(by: { $0.value < $1.value })?.key)
        let back = luminance(background)
        let ink = pixels.filter { $0.value >= 3 }.map { luminance($0.key) }
        let front = try XCTUnwrap(back < 0.5 ? ink.max() : ink.min())
        let ratio = (max(front, back) + 0.05) / (min(front, back) + 0.05)
        let measurement = XCTAttachment(
            string:
                "frame=\(frame) backgroundRGB=\(String(background, radix: 16)) inkLuminance=\(front) contrast=\(ratio)"
        )
        measurement.name = "Rendered native text contrast"
        measurement.lifetime = .keepAlways
        add(measurement)
        return ratio
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
