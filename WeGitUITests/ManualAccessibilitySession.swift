import XCTest

/// An opt-in, isolated workspace for the manual VoiceOver/system-settings audit.
/// Completing this harness does not assert accessibility acceptance.
final class ManualAccessibilitySession: XCTestCase {
    @MainActor func testInteractiveAuditWorkspace() throws {
        guard ProcessInfo.processInfo.environment["WEGIT_MANUAL_ACCESSIBILITY"] == "1" else {
            throw XCTSkip("Manual audit harness; enable explicitly in the test runner environment.")
        }
        let fixture = try UITestGit(prefix: "WeGitManualAccessibility")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try Data("let value = 1\n".utf8).write(to: fixture.root.appending(path: "file.swift"))
        try fixture.git(["add", "."])
        try fixture.git([
            "-c", "user.name=UI Test", "-c", "user.email=ui@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-m", "Accessibility fixture",
        ])
        try Data("let value = 2\n".utf8).write(to: fixture.root.appending(path: "file.swift"))
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.outlines["changes-list"].waitForExistence(timeout: 15))
        let ended = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.state == .notRunning }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [ended], timeout: 1_200), .completed,
            "Finish the manual audit by quitting the isolated app.")
    }
}
