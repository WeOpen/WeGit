import XCTest

final class AccessibilityControlUITests: XCTestCase {
    @MainActor func testNativeControlsAndAuditInBothAppearances() throws {
        for appearance in ["light", "dark"] {
            continueAfterFailure = false
            let app = XCUIApplication()
            app.launchEnvironment["CONTROL_APPEARANCE"] = appearance
            app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
            app.launch()
            app.activate()
            defer { app.terminate() }
            XCTAssertTrue(app.staticTexts["control-ready"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.windows.count, 1)
            XCTAssertTrue(app.windows.firstMatch.isHittable)
            let scope = app.descendants(matching: .any).matching(identifier: "control-scope").firstMatch
            XCTAssertTrue(scope.isHittable)
            scope.click()
            let branch = app.menuItems["Current branch"]
            XCTAssertTrue(branch.waitForExistence(timeout: 5))
            branch.click()
            app.buttons["control-button"].click()
            XCTAssertTrue(app.staticTexts["Activated"].waitForExistence(timeout: 5))
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Independent control hierarchy - " + appearance
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Independent control screenshot - " + appearance
            screenshot.lifetime = .keepAlways
            add(screenshot)
            continueAfterFailure = true
            try app.performAccessibilityAudit(for: [
                .sufficientElementDescription, .action, .parentChild, .contrast,
            ]) { issue in
                let detail = XCTAttachment(
                    string: issue.detailedDescription + "\n"
                        + (issue.element?.debugDescription ?? "No associated element"))
                detail.name = "Independent accessibility issue - " + appearance
                detail.lifetime = .keepAlways
                self.add(detail)
                return false
            }
            app.terminate()
        }
    }
}
