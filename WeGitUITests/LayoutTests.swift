import XCTest

final class LayoutTests: XCTestCase {
    @MainActor func testContextControlsStayVisibleInMinimumWindow() throws {
        continueAfterFailure = false
        for diskBacked in [false, true] {
            let fixture = try UITestGit(prefix: "WeGitContextLayoutUI")
            defer { fixture.remove() }
            try fixture.git(["init", "-b", "main"])
            let file = fixture.root.appending(path: "context.swift")
            let padding = String(repeating: "x", count: diskBacked ? 240 : 400)
            func text(modified: Bool) -> String {
                (1...(diskBacked ? 20_000 : 40)).map { line in
                    let changed = modified && (diskBacked ? line > 4 : [5, 25].contains(line))
                    return "let \(changed ? "new" : "old")\(line) = \"\(padding)\"\n"
                }.joined()
            }
            try Data(text(modified: false).utf8).write(to: file)
            try fixture.git(["add", "."])
            try fixture.git([
                "-c", "user.name=UI Test", "-c", "user.email=ui@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "-m", "Context layout fixture",
            ])
            try Data(text(modified: true).utf8).write(to: file)
            for appearance in ["light", "dark"] {
                for layout in ["分栏", "统一"] {
                    let app = XCUIApplication()
                    app.launchArguments = [
                        "--uitesting", "-appearance", appearance,
                        "-defaultSplitDiff", layout == "分栏" ? "YES" : "NO",
                    ]
                    app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
                    app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
                    app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
                    app.launchWeGit()
                    app.activate()
                    defer { app.terminate() }
                    XCTAssertTrue(app.staticTexts["context.swift"].firstMatch.waitForExistence(timeout: 10))
                    let window = app.windows["main"]
                    let initial = window.frame
                    if abs(initial.width - 980) > 4 || abs(initial.height - 692) > 4 {
                        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                            .withOffset(CGVector(dx: -1, dy: -1))
                        corner.click(
                            forDuration: 0.2,
                            thenDragTo: corner.withOffset(
                                CGVector(dx: 980 - initial.width, dy: 692 - initial.height))
                        )
                    }
                    XCTAssertEqual(window.frame.width, 980, accuracy: 4)
                    XCTAssertEqual(window.frame.height, 692, accuracy: 4)
                    app.outlines["changes-list"].staticTexts["context.swift"].firstMatch.click()
                    if diskBacked {
                        let load = app.buttons["diff-load-large"]
                        XCTAssertTrue(load.waitForExistence(timeout: 5))
                        load.click()
                        XCTAssertTrue(app.staticTexts["disk-diff-progress"].waitForExistence(timeout: 20))
                    }
                    let layoutButton = app.radioButtons[layout]
                    let loaded = layoutButton.waitForExistence(timeout: 10)
                    if !loaded {
                        let screenshot = XCTAttachment(screenshot: app.screenshot())
                        screenshot.name = "Missing diff layout"
                        screenshot.lifetime = .keepAlways
                        add(screenshot)
                        let tree = XCTAttachment(string: app.debugDescription)
                        tree.lifetime = .keepAlways
                        add(tree)
                    }
                    XCTAssertTrue(loaded)
                    let row = app.descendants(matching: .any).matching(
                        identifier: layout == "统一" ? "unified-diff-row" : "split-diff-row"
                    ).firstMatch
                    XCTAssertTrue(row.waitForExistence(timeout: 10))
                    let content = app.scrollViews[diskBacked ? "disk-diff-content" : "diff-content"]
                    XCTAssertTrue(content.waitForExistence(timeout: 5))
                    func visible(_ control: XCUIElement) {
                        XCTAssertTrue(control.exists)
                        let viewport = content.frame.intersection(window.frame)
                        if !viewport.insetBy(dx: -2, dy: -2).contains(control.frame) {
                            let screenshot = XCTAttachment(screenshot: app.screenshot())
                            screenshot.name = "Context control outside viewport"
                            screenshot.lifetime = .keepAlways
                            add(screenshot)
                            let tree = XCTAttachment(string: app.debugDescription)
                            tree.lifetime = .keepAlways
                            add(tree)
                        }
                        XCTAssertTrue(
                            viewport.insetBy(dx: -2, dy: -2).contains(control.frame),
                            "Context control \(control.frame) outside viewport \(viewport): \(control)")
                        XCTAssertTrue(control.isHittable)
                    }
                    let expand = app.buttons["diff-context-expand-0"]
                    XCTAssertTrue(expand.waitForExistence(timeout: 5))
                    visible(expand)
                    expand.click()
                    let collapse = app.buttons["diff-context-collapse-0"]
                    XCTAssertTrue(collapse.waitForExistence(timeout: 5))
                    visible(collapse)
                    if layout == "统一" {
                        content.scroll(byDeltaX: 400, deltaY: 0)
                        visible(collapse)
                    }
                    let screenshot = XCTAttachment(screenshot: app.screenshot())
                    screenshot.name =
                        "Context controls - \(diskBacked ? "disk" : "memory") - \(appearance) - \(layout)"
                    screenshot.lifetime = .keepAlways
                    add(screenshot)
                    collapse.click()
                    XCTAssertTrue(expand.waitForExistence(timeout: 5))
                    visible(expand)
                    app.terminate()
                }
            }
        }
    }

    @MainActor func testMinimumWindowPreservesNavigationAndPrimaryControls() throws {
        try checkMinimumWindow(audit: false)
    }

    @MainActor func testAccessibilityAuditInBothThemes() throws {
        try checkMinimumWindow(audit: true)
    }

    @MainActor private func checkMinimumWindow(audit: Bool) throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitLayoutUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Test"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        let before =
            audit ? "let value = 1\n" : "let longValue = \"" + String(repeating: "a", count: 400) + "\"\n"
        let after =
            audit ? "let value = 2\n" : "let longValue = \"" + String(repeating: "b", count: 400) + "\"\n"
        try Data(before.utf8).write(to: fixture.root.appending(path: "file.swift"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Layout fixture"])
        try Data(after.utf8).write(to: fixture.root.appending(path: "file.swift"))
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--uitesting", "-appearance", appearance]
            app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
            app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
            app.launchWeGit()
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["file.swift"].firstMatch.waitForExistence(timeout: 10))
            let window = app.windows["main"]
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Minimum workspace hierarchy - " + appearance
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let navigation = app.staticTexts.matching(
                NSPredicate(format: "identifier == %@ AND value == %@", "route-更改", "更改")
            ).firstMatch
            func visible(_ element: XCUIElement) {
                XCTAssertTrue(element.exists)
                XCTAssertGreaterThan(element.frame.width, 0)
                XCTAssertTrue(
                    window.frame.insetBy(dx: -2, dy: -2).contains(element.frame),
                    "Control outside window: \(element)")
            }
            visible(navigation)
            visible(app.buttons["commit-button"])
            let initial = window.frame
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -1, dy: -1))
            let target = corner.withOffset(CGVector(dx: 980 - initial.width, dy: 692 - initial.height))
            corner.click(forDuration: 0.2, thenDragTo: target)
            XCTAssertEqual(window.frame.width, 980, accuracy: 4)
            XCTAssertEqual(window.frame.height, 692, accuracy: 4)
            visible(navigation)
            visible(app.buttons["commit-button"])
            let sidebar = app.windows["main"].outlines.containing(
                .staticText, identifier: "route-更改"
            ).firstMatch
            XCTAssertTrue(sidebar.waitForExistence(timeout: 3))
            XCTAssertGreaterThanOrEqual(
                app.textFields["changes-filter"].frame.minX, sidebar.frame.maxX - 2)
            app.staticTexts["file.swift"].firstMatch.click()
            XCTAssertTrue(app.buttons["暂存此块"].firstMatch.waitForExistence(timeout: 5))
            visible(app.buttons["暂存此块"].firstMatch)
            visible(app.buttons["丢弃此块…"].firstMatch)
            if !audit {
                let code = app.textViews.matching(
                    NSPredicate(format: "value BEGINSWITH %@", "let longValue")
                ).firstMatch
                let beforeScroll = code.frame.minX
                app.scrollViews["diff-content"].scroll(byDeltaX: 400, deltaY: 0)
                XCTAssertLessThan(code.frame.minX, beforeScroll - 50)
                visible(app.buttons["暂存此块"].firstMatch)
                visible(app.buttons["丢弃此块…"].firstMatch)
            }
            app.typeKey("2", modifierFlags: .command)
            XCTAssertTrue(app.staticTexts["Layout fixture"].firstMatch.waitForExistence(timeout: 5))
            app.staticTexts["Layout fixture"].firstMatch.click()
            visible(app.descendants(matching: .any).matching(identifier: "history-search").firstMatch)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Minimum window - " + appearance
            screenshot.lifetime = .keepAlways
            add(screenshot)
            if audit {
                continueAfterFailure = true
                try app.performAccessibilityAudit(for: [
                    .sufficientElementDescription, .action, .parentChild, .contrast,
                ]) { issue in
                    let detail = XCTAttachment(
                        string: issue.detailedDescription + "\n"
                            + (issue.element?.debugDescription ?? "No associated element"))
                    detail.name = "Accessibility issue - " + appearance
                    detail.lifetime = .keepAlways
                    self.add(detail)
                    return false
                }
                continueAfterFailure = false
            }
        }
    }
}
