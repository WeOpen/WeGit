import AppKit
import XCTest

final class DiffReaderTests: XCTestCase {
    @MainActor func testHunkNavigationAndNativeSelectionCopyOriginalText() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitDiffReaderUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        let file = fixture.root.appending(path: "navigation.swift")
        let original = (1...80).map { "\tlet value\($0) = \"中文🙂 a b\"\r\n" }.joined()
        let modified = original.replacingOccurrences(of: "value5 =", with: "changed5 =")
            .replacingOccurrences(of: "value70 =", with: "changed70 =")
        try Data(original.utf8).write(to: file)
        try fixture.git(["add", "."])
        try fixture.git([
            "-c", "user.name=UI Test", "-c", "user.email=ui@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", "Diff reader fixture",
        ])
        try Data(modified.utf8).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-showWhitespace", "YES"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        app.activate()
        defer { app.terminate() }
        let fileRow = app.outlines["changes-list"].staticTexts["navigation.swift"].firstMatch
        XCTAssertTrue(fileRow.waitForExistence(timeout: 10))
        fileRow.click()
        let next = app.buttons["diff-hunk-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["diff-hunk-previous"].isEnabled)
        let clipboard = NSPasteboard.general
        let saved =
            clipboard.pasteboardItems?.map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            } ?? []
        defer {
            clipboard.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            clipboard.writeObjects(items)
        }
        for layout in ["统一", "分栏"] {
            app.radioButtons[layout].click()
            let code = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "changed5"))
                .firstMatch
            XCTAssertTrue(code.waitForExistence(timeout: 10))
            XCTAssertTrue((code.value as? String)?.contains("⇥let·changed5") == true)
            code.click()
            code.typeKey("a", modifierFlags: .command)
            clipboard.clearContents()
            clipboard.setString("fixture copy has not run", forType: .string)
            app.menuBars.menuBarItems["仓库"].click()
            app.menuItems["刷新"].click()
            let refreshed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"), object: next)
            XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 5), .completed)
            code.typeKey("c", modifierFlags: .command)
            let expected = "\tlet changed5 = \"中文🙂 a b\"\r"
            let copied = clipboard.string(forType: .string) ?? ""
            if copied.contains("changed5") && copied != expected {
                let attachment = XCTAttachment(string: copied.debugDescription)
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertEqual(Data(copied.utf8), Data(expected.utf8))
            code.rightClick()
            app.menuItems["复制完整行"].click()
            XCTAssertEqual(
                Data((clipboard.string(forType: .string) ?? "").utf8),
                Data((expected + "\n").utf8))
            let first = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "value2"))
                .firstMatch
            let second = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "value3"))
                .firstMatch
            XCTAssertTrue(first.exists && second.exists)
            let start = first.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(
                CGVector(dx: 1, dy: 1))
            let end = second.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(
                CGVector(dx: -1, dy: -1))
            start.click(forDuration: 0.2, thenDragTo: end)
            clipboard.clearContents()
            clipboard.setString("fixture range has not copied", forType: .string)
            first.typeKey("c", modifierFlags: .command)
            let rangeText = "\tlet value2 = \"中文🙂 a b\"\r\n\tlet value3 = \"中文🙂 a b\"\r"
            XCTAssertEqual(Data((clipboard.string(forType: .string) ?? "").utf8), Data(rangeText.utf8))
            first.typeKey("a", modifierFlags: .command)
            first.typeKey("c", modifierFlags: .command)
            XCTAssertEqual(
                Data((clipboard.string(forType: .string) ?? "").utf8),
                Data("\tlet value2 = \"中文🙂 a b\"\r".utf8))
            next.click()
            XCTAssertTrue(app.staticTexts["diff-hunk-position"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.staticTexts["diff-hunk-position"].value as? String, "差异块 2 / 2")
            let copy = app.buttons["diff-hunk-copy:1"]
            XCTAssertTrue(copy.waitForExistence(timeout: 5))
            XCTAssertTrue(copy.isHittable)
            copy.click()
            let patch = clipboard.string(forType: .string) ?? ""
            XCTAssertTrue(patch.hasPrefix("diff --git a/navigation.swift b/navigation.swift\n"))
            XCTAssertTrue(patch.contains("+\tlet changed70 = \"中文🙂 a b\"\r\n"))
            XCTAssertFalse(patch.contains("changed5"))
            XCTAssertFalse(next.isEnabled)
            app.buttons["diff-hunk-previous"].click()
            XCTAssertEqual(app.staticTexts["diff-hunk-position"].value as? String, "差异块 1 / 2")
        }
    }
}
