import AppKit
import XCTest

final class ReadingMatrixTests: XCTestCase {
    @MainActor func testDiffControlsAcrossTypographyDensityThemeAndWindowSizes() throws {
        continueAfterFailure = false
        for disk in [false, true] {
            let fixture = try UITestGit(prefix: "WeGitReadingMatrix")
            defer { fixture.remove() }
            try fixture.git(["init", "-b", "main"])
            let file = fixture.root.appending(path: "matrix.swift")
            let padding = String(repeating: "x", count: disk ? 240 : 80)
            func text(_ changed: Bool) -> String {
                (1...(disk ? 20_000 : 40)).map { index in
                    "let \(changed && index > 4 ? "new" : "old")\(index) = \"\(padding)\"\n"
                }.joined()
            }
            try Data(text(false).utf8).write(to: file)
            try fixture.git(["add", "."])
            try fixture.git([
                "-c", "user.name=UI Test", "-c", "user.email=ui@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "-m", "Reading matrix fixture",
            ])
            try Data(text(true).utf8).write(to: file)
            for size in [11, 17, 24] {
                for density in ["comfortable", "compact"] {
                    for theme in ["light", "dark"] {
                        let app = XCUIApplication()
                        app.launchArguments = [
                            "--uitesting", "-codeSize", String(size), "-density", density,
                            "-appearance", theme,
                        ]
                        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
                        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
                        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
                        app.launchWeGit()
                        defer { app.terminate() }
                        let row = app.outlines["changes-list"].staticTexts["matrix.swift"].firstMatch
                        XCTAssertTrue(row.waitForExistence(timeout: 15))
                        row.click()
                        if disk {
                            let load = app.buttons["diff-load-large"]
                            XCTAssertTrue(load.waitForExistence(timeout: 5))
                            load.click()
                            XCTAssertTrue(app.staticTexts["disk-diff-progress"].waitForExistence(timeout: 30))
                        }
                        let window = app.windows["main"]
                        let available = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1_460, height: 900)
                        for windowSize in [
                            CGSize(width: 980, height: 692),
                            CGSize(width: min(1_360, available.width), height: min(880, available.height)),
                            CGSize(width: min(1_460, available.width), height: min(900, available.height)),
                        ] {
                            for _ in 0..<3 {
                                let initial = window.frame
                                if abs(initial.width - windowSize.width) <= 4
                                    && abs(initial.height - windowSize.height) <= 4
                                {
                                    break
                                }
                                let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                                    .withOffset(CGVector(dx: -1, dy: -1))
                                corner.click(
                                    forDuration: 0.2,
                                    thenDragTo: corner.withOffset(
                                        CGVector(
                                            dx: windowSize.width - initial.width,
                                            dy: windowSize.height - initial.height)))
                            }
                            XCTAssertEqual(window.frame.width, windowSize.width, accuracy: 4)
                            XCTAssertEqual(window.frame.height, windowSize.height, accuracy: 4)
                            for layout in ["统一", "分栏"] {
                                app.radioButtons[layout].click()
                                let copy = app.buttons["diff-hunk-copy:0"]
                                XCTAssertTrue(copy.waitForExistence(timeout: 15))
                                let content = app.scrollViews[disk ? "disk-diff-content" : "diff-content"]
                                XCTAssertTrue(
                                    content.frame.insetBy(dx: -2, dy: -2).contains(copy.frame),
                                    "\(disk) / \(size) / \(density) / \(theme) / \(windowSize) / \(layout)")
                                XCTAssertTrue(copy.isHittable)
                                let code = app.textViews.matching(
                                    NSPredicate(format: "value BEGINSWITH %@", "let old2")
                                )
                                .firstMatch
                                XCTAssertTrue(code.exists)
                                if layout == "统一" {
                                    XCTAssertEqual(
                                        code.frame.height, CGFloat(size) * 1.2, accuracy: 4,
                                        "The requested code size must affect the actual native glyph cell.")
                                }
                                XCTAssertTrue(app.buttons["commit-button"].exists)
                                XCTAssertTrue(window.frame.contains(app.buttons["commit-button"].frame))
                                let screenshot = XCTAttachment(screenshot: app.screenshot())
                                screenshot.name =
                                    "\(disk ? "disk" : "memory")-\(size)-\(density)-\(theme)-\(Int(windowSize.width))-\(layout)"
                                screenshot.lifetime = .keepAlways
                                add(screenshot)
                            }
                        }
                        app.terminate()
                    }
                }
            }
        }
    }
}
