import Foundation
import XCTest

final class LargeReadingPerformanceTests: XCTestCase {
    @MainActor func testDiskDiffFixedScrollTrajectory() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try XCTUnwrap(environment["WEGIT_PERFORMANCE_FIXTURE"]))
        let manifest =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: source.appending(path: ".git/wegit-benchmark.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["label"] as? String, "large")
        XCTAssertEqual(manifest?["commits"] as? Int, 100_000)
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitLargeScroll-" + UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let warmup = Process()
        warmup.executableURL = URL(fileURLWithPath: try XCTUnwrap(environment["WEGIT_PERFORMANCE_GIT"]))
        warmup.arguments = ["-C", root.path, "update-index", "--refresh"]
        var isolated = environment.filter { !$0.key.hasPrefix("GIT_") }
        isolated["GIT_CONFIG_GLOBAL"] = "/dev/null"
        isolated["GIT_CONFIG_SYSTEM"] = "/dev/null"
        warmup.environment = isolated
        let output = Pipe()
        warmup.standardOutput = output
        warmup.standardError = output
        try warmup.run()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        warmup.waitUntilExit()
        XCTAssertTrue([0, 1].contains(warmup.terminationStatus))
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-appearance", "light", "-language", "zh-Hans"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launch()
        app.activate()
        defer { app.terminate() }
        if !app.windows["main"].waitForExistence(timeout: 2) {
            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["显示 WeGit 主窗口"].click()
        }
        let file = app.outlines["changes-list"].staticTexts["large.swift"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30))
        file.click()
        let load = app.buttons["diff-load-large"]
        XCTAssertTrue(load.waitForExistence(timeout: 10))
        load.click()
        let content = app.scrollViews["disk-diff-content"]
        XCTAssertTrue(content.waitForExistence(timeout: 30))
        let options = XCTMeasureOptions()
        options.iterationCount = 30
        measure(
            metrics: [
                XCTOSSignpostMetric.scrollingAndDecelerationMetric,
                XCTMemoryMetric(application: app), XCTCPUMetric(application: app),
            ], options: options
        ) {
            for _ in 0..<4 { content.scroll(byDeltaX: 0, deltaY: -400) }
            for _ in 0..<4 { content.scroll(byDeltaX: 0, deltaY: 400) }
        }
        XCTAssertTrue(content.exists)
        XCTAssertTrue(app.buttons["diff-hunk-copy:0"].exists)
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Large disk diff after 30 fixed scroll trajectories"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}
