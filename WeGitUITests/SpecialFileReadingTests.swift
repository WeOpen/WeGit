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
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "二进制")).firstMatch
                .waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["encoded-content-reader"].exists)
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

    @MainActor func testRasterRenderingAndEncodingSelectionPreserveFilesAndIndex() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitRasterReading")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        func png(width: Int, height: Int, color: NSColor) throws -> Data {
            let bitmap = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            for y in 0..<height {
                for x in 0..<width {
                    bitmap.setColor(
                        x >= 8 && x < width - 8 && y >= 8 && y < height - 8 ? color : .clear,
                        atX: x, y: y)
                }
            }
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let image = fixture.root.appending(path: "transparent.png")
        let encoded = fixture.root.appending(path: "encoded.txt")
        try png(width: 64, height: 48, color: .blue).write(to: image)
        try XCTUnwrap("旧文本\n".data(using: .utf16LittleEndian)).write(to: encoded)
        try fixture.git(["add", "."])
        try fixture.git([
            "-c", "user.name=UI Fixture", "-c", "user.email=ui@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-m", "Raster and encoding fixture",
        ])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let index = try Data(contentsOf: fixture.root.appending(path: ".git/index"))
        let changedImage = try png(width: 96, height: 64, color: .red)
        let changedText = try XCTUnwrap("新文本\n".data(using: .utf16LittleEndian))
        try changedImage.write(to: image)
        try changedText.write(to: encoded)
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
        select("transparent.png")
        XCTAssertTrue(app.images["起点"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["目标"].waitForExistence(timeout: 10))
        let metadata = app.staticTexts["raster-metadata"].label
        XCTAssertTrue(metadata.contains("64 × 48"))
        XCTAssertTrue(metadata.contains("96 × 64"))
        app.radioButtons["滑杆"].click()
        XCTAssertTrue(app.images["图片滑杆比较"].waitForExistence(timeout: 5))
        app.sliders["比较位置"].adjust(toNormalizedSliderPosition: 0.25)
        app.buttons["放大图片"].click()
        let metadataBeforePan = app.staticTexts["raster-metadata"].screenshot().pngRepresentation
        app.images["图片滑杆比较"].click()
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        XCTAssertEqual(app.staticTexts["raster-metadata"].screenshot().pngRepresentation, metadataBeforePan)
        app.buttons["适合窗口"].click()
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Transparent image render queue and wipe comparison"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        select("encoded.txt")
        let picker = app.popUpButtons["content-encoding"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        app.menuItems["UTF-16 LE"].click()
        XCTAssertTrue(app.staticTexts["新文本"].waitForExistence(timeout: 5))
        select("transparent.png")
        XCTAssertTrue(app.images["起点"].waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: image), changedImage)
        XCTAssertEqual(try Data(contentsOf: encoded), changedText)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: ".git/index")), index)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
    }
}
