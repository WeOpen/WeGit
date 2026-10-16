import AppKit
import XCTest

final class InspectorRestorationTests: XCTestCase {
    @MainActor func testBranchesStayInsideWorkspaceWithSidebarAndInspectorChanges() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitBranchesLayout")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let file = fixture.root.appending(path: "Layout.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        try fixture.git(["add", "."])
        try fixture.git([
            "-c", "user.name=UI Fixture", "-c", "user.email=ui@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", "Branch layout fixture",
        ])
        try fixture.git(["branch", "feature/" + String(repeating: "long-name-", count: 8) + "end"])
        try Data("let value = 2\n".utf8).write(to: file)
        let before = try fixture.git(["status", "--porcelain=v1"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let filter = app.textFields["branches-filter"]
        let changes = app.outlines["changes-list"]
        for inspectorShown in [false, true] {
            if inspectorShown { app.buttons["toolbar-inspector"].click() }
            for sidebarShown in [true, false] {
                if !sidebarShown { app.buttons["toolbar-sidebar"].click() }
                app.typeKey("1", modifierFlags: .command)
                XCTAssertTrue(changes.waitForExistence(timeout: 10))
                let workspaceLeft = changes.frame.minX
                app.typeKey("3", modifierFlags: .command)
                XCTAssertTrue(filter.waitForExistence(timeout: 5))
                XCTAssertGreaterThanOrEqual(filter.frame.minX, workspaceLeft + 8)
                let right =
                    inspectorShown
                    ? app.scrollViews["repository-inspector"].frame.minX : app.windows["main"].frame.maxX
                XCTAssertLessThanOrEqual(filter.frame.maxX, right)
                // The formerly covered leading edge must accept input, not only
                // expose an accessibility field behind the sidebar.
                filter.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
                filter.typeText("main")
                XCTAssertEqual(filter.value as? String, "main")
                filter.typeKey("a", modifierFlags: .command)
                filter.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
                if !sidebarShown { app.buttons["toolbar-sidebar"].click() }
            }
        }
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), before)
    }

    @MainActor func testDiffFillsInspectorBoundaryAndSplitHeadersHaveInsets() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitDiffPanelLayout")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let small = fixture.root.appending(path: "small.swift")
        let disk = fixture.root.appending(path: "disk.swift")
        let padding = String(repeating: "x", count: 240) + "\t中文🙂"
        func large(_ prefix: String) -> Data {
            Data((1...20_000).map { "let \(prefix)\($0) = \"\(padding)\"\n" }.joined().utf8)
        }
        try Data("let small = 1\n".utf8).write(to: small)
        try large("old").write(to: disk)
        try fixture.git(["add", "."])
        try fixture.git([
            "-c", "user.name=UI Fixture", "-c", "user.email=ui@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", "Diff layout fixture",
        ])
        try Data("let small = 2\n".utf8).write(to: small)
        try large("new").write(to: disk)
        let status = try fixture.git(["status", "--porcelain=v1"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-appearance", "light"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let list = app.outlines["changes-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        app.buttons["toolbar-inspector"].click()
        let inspector = app.scrollViews["repository-inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        for (path, identifier) in [("small.swift", "diff-content"), ("disk.swift", "disk-diff-content")] {
            list.staticTexts[path].firstMatch.click()
            if path == "disk.swift" {
                XCTAssertTrue(app.buttons["diff-load-large"].waitForExistence(timeout: 5))
                app.buttons["diff-load-large"].click()
            }
            let content = app.scrollViews[identifier]
            XCTAssertTrue(content.waitForExistence(timeout: 20))
            for split in [true, false] {
                app.radioButtons[split ? "分栏" : "统一"].coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).click()
                XCTAssertTrue(content.waitForExistence(timeout: 10))
                XCTAssertEqual(content.frame.maxX, inspector.frame.minX - 1, accuracy: 2)
                if split {
                    let headers = app.descendants(matching: .any)["diff-column-headers"]
                    XCTAssertTrue(headers.waitForExistence(timeout: 5))
                    for column in 0...1 {
                        XCTAssertGreaterThanOrEqual(
                            try firstHeaderInkInset(in: headers.frame, column: column), 10)
                    }
                }
            }
            app.buttons["toolbar-inspector"].click()
            XCTAssertFalse(inspector.exists)
            app.buttons["toolbar-inspector"].click()
            XCTAssertTrue(inspector.waitForExistence(timeout: 5))
            XCTAssertEqual(content.frame.maxX, inspector.frame.minX - 1, accuracy: 2)
        }
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), status)
    }

    @MainActor private func firstHeaderInkInset(in rect: CGRect, column: Int) throws -> CGFloat {
        let shot = XCUIScreen.main.screenshot()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: shot.pngRepresentation))
        let sx = CGFloat(bitmap.pixelsWide) / shot.image.size.width
        let sy = CGFloat(bitmap.pixelsHigh) / shot.image.size.height
        let start = rect.minX + CGFloat(column) * (rect.width + 1) / 2
        let right = start + (rect.width - 1) / 2
        for x in Int((start + 1) * sx)..<min(bitmap.pixelsWide, Int(right * sx)) {
            for y in max(0, Int((rect.minY + 2) * sy))..<min(bitmap.pixelsHigh, Int((rect.maxY - 2) * sy)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
                    < 0.7
                {
                    return CGFloat(x) / sx - start
                }
            }
        }
        XCTFail("No readable title found in column \(column)")
        return -1
    }

    @MainActor func testOpenInspectorRestoresAcrossBothSplitWorkspaces() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitInspectorRestoration")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Fixture"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        let file = fixture.root.appending(path: "Inspector.swift")
        try Data("let inspector = 1\n".utf8).write(to: file)
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Inspector fixture"])
        try Data("let inspector = 2\n".utf8).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-window-state", UUID().uuidString]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.outlines["changes-list"].waitForExistence(timeout: 10))
        let inspector = app.scrollViews["repository-inspector"]
        let toggle = app.toolbars.buttons["检查器"]
        toggle.click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "已打开")
        app.launchArguments.append("--uitesting-keep-preferences")

        for route in ["提交历史", "更改"] {
            let shortcut = route == "提交历史" ? "2" : "1"
            app.typeKey(shortcut, modifierFlags: .command)
            let mainContent = app.outlines[route == "提交历史" ? "history-list" : "changes-list"]
            XCTAssertTrue(mainContent.waitForExistence(timeout: 10))
            app.typeKey("q", modifierFlags: .command)
            let quit = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue),
                object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [quit], timeout: 5), .completed)
            app.launchWeGit()
            // The previous Inspector host crashed while restoring either nested split workspace.
            XCTAssertTrue(mainContent.waitForExistence(timeout: 10))
            XCTAssertTrue(inspector.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "已打开")
            XCTAssertTrue(app.buttons["在 Finder 中显示"].isHittable)
            let window = app.windows["main"]
            let initial = window.frame
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -1, dy: -1))
            corner.click(
                forDuration: 0.2,
                thenDragTo: corner.withOffset(CGVector(dx: 980 - initial.width, dy: 693 - initial.height)))
            XCTAssertGreaterThanOrEqual(window.frame.width, 1292)
            XCTAssertTrue(window.frame.contains(mainContent.frame))
            XCTAssertTrue(window.frame.contains(inspector.frame))
            XCTAssertLessThanOrEqual(mainContent.frame.maxX, inspector.frame.minX)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Restored inspector - \(route)"
            attachment.lifetime = .keepAlways
            add(attachment)
            toggle.click()
            XCTAssertFalse(inspector.exists)
            XCTAssertEqual(toggle.value as? String, "已关闭")
            XCTAssertTrue(mainContent.isHittable)
            toggle.click()
            XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        }
        XCTAssertEqual(try fixture.git(["log", "-1", "--format=%s"]), "Inspector fixture\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let inspector = 2\n")
    }
}
