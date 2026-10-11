import XCTest

final class WindowLifecycleTests: XCTestCase {
    @MainActor func testWindowFrameRestoresAndClosedWorkspaceCanReopen() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitWindowLifecycleUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let app = XCUIApplication()
        let namespace = UUID().uuidString
        app.launchArguments = ["--uitesting", "--uitesting-window-state", namespace]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let window = app.windows["main"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let initial = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -1, dy: -1))
        corner.click(
            forDuration: 0.2,
            thenDragTo: corner.withOffset(CGVector(dx: 1120 - initial.width, dy: 780 - initial.height)))
        XCTAssertEqual(window.frame.width, 1120, accuracy: 4)
        XCTAssertEqual(window.frame.height, 780, accuracy: 4)
        app.terminate()
        app.launchArguments += ["--uitesting-keep-preferences"]
        app.launchWeGit()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertEqual(window.frame.width, 1120, accuracy: 4)
        XCTAssertEqual(window.frame.height, 780, accuracy: 4)
        window.typeKey("w", modifierFlags: .command)
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: window)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["显示 WeGit 主窗口"].click()
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertEqual(window.frame.width, 1120, accuracy: 4)
        XCTAssertTrue(app.staticTexts["工作区干净"].firstMatch.waitForExistence(timeout: 10))
    }
}
