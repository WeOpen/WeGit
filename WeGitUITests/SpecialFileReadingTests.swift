import AppKit
import XCTest

final class SpecialFileReadingTests: XCTestCase {
    @MainActor func testBinarySymlinkUnknownLanguageAndDeletedFileReading() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitSpecialReading")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let binary = fixture.root.appending(path: "binary.dat")
        let deleted = fixture.root.appending(path: "deleted.txt")
        try Data([0, 1, 255, 42]).write(to: binary)
        try Data("deleted original\n".utf8).write(to: deleted)
        try fixture.git(["add", "."])
        try fixture.git([
            "-c", "user.name=UI Fixture", "-c", "user.email=ui@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", "Special file fixture",
        ])
        try Data([0, 2, 255, 43]).write(to: binary)
        try FileManager.default.removeItem(at: deleted)
        let unknown = fixture.root.appending(path: "unknown.weunknown")
        let source = "\tunknown 中文🙂  value\n"
        try Data(source.utf8).write(to: unknown)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.root.appending(path: "link.txt").path, withDestinationPath: "unknown.weunknown")
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let list = app.outlines["changes-list"]
        func select(_ path: String) {
            let row = list.staticTexts[path].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.click()
        }
        select("binary.dat")
        XCTAssertTrue(app.staticTexts["二进制文件已变化"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["diff-hunk-copy:0"].exists)
        select("deleted.txt")
        XCTAssertTrue(
            app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "deleted original")).firstMatch
                .waitForExistence(timeout: 5))
        select("link.txt")
        XCTAssertTrue(
            app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "unknown.weunknown")).firstMatch
                .waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "unknown 中文")).firstMatch.exists)
        select("unknown.weunknown")
        let code = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "unknown 中文🙂")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        UITestGit.preservingClipboard { clipboard in
            code.rightClick()
            app.menuItems["复制完整行"].click()
            XCTAssertEqual(Data((clipboard.string(forType: .string) ?? "").utf8), Data(source.utf8))
        }
    }
}
