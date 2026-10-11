import Foundation
import XCTest

final class WorkbenchPerformanceTests: XCTestCase {
    private struct Sample: Codable {
        let name: String
        let milliseconds: Double
        let peakRSSBytes: Int
        let endedAtNanoseconds: UInt64
    }

    @MainActor func testActualWorkspaceFirstScreens() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let sourceRoot = URL(fileURLWithPath: try XCTUnwrap(environment["WEGIT_PERFORMANCE_FIXTURE"]))
        let manifest =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: sourceRoot.appending(path: ".git/wegit-benchmark.json")))
            as? [String: Any]
        XCTAssertEqual(manifest?["generator"] as? String, "WeGit benchmark fixture")
        let run = URL(fileURLWithPath: try XCTUnwrap(environment["WEGIT_PERFORMANCE_RESULTS"]))
        let output = FileManager.default.temporaryDirectory.appending(
            path: "WeGitWorkbench-" + run.lastPathComponent)
        let count = Int(environment["WEGIT_PERFORMANCE_SAMPLES"] ?? "30") ?? 30
        XCTAssertTrue(count == 1 || count == 30)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // The runner's sandbox can read the retained benchmark but cannot mutate
        // the project checkout. Copy once, before timing, into its private domain.
        let root = output.appending(path: "fixture")
        try FileManager.default.copyItem(at: sourceRoot, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-appearance", "light"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        defer { app.terminate() }
        var all: [Sample] = []
        for index in 0..<count {
            let report = output.appending(path: "sample-\(index).json")
            app.launchEnvironment["WEGIT_PERFORMANCE_REPORT"] = report.path
            app.launch()
            app.activate()
            if !app.windows["main"].waitForExistence(timeout: 2) {
                app.menuBars.menuBarItems["Window"].click()
                app.menuItems["显示 WeGit 主窗口"].click()
            }
            let file = app.outlines["changes-list"].staticTexts["file-000000.swift"].firstMatch
            XCTAssertTrue(file.waitForExistence(timeout: 15))
            file.click()
            XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
            app.staticTexts["route-提交历史"].firstMatch.click()
            XCTAssertTrue(app.outlines["history-list"].waitForExistence(timeout: 10))
            func records() -> [Sample] {
                (try? JSONDecoder().decode([Sample].self, from: Data(contentsOf: report))) ?? []
            }
            let rendered = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    Set(records().map(\.name)).isSuperset(of: ["shell", "status", "diff", "history"])
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 10), .completed)
            let measured = records()
            let first = ["shell", "status", "diff", "history"].compactMap { name in
                measured.first { $0.name == name }
            }
            XCTAssertEqual(first.count, 4)
            all += first
            app.typeKey("1", modifierFlags: .command)
            let eventFile = root.appending(path: "wegit-event-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: eventFile) }
            let stableWriteBegan = DispatchTime.now().uptimeNanoseconds
            try Data("External stable event fixture\n".utf8).write(to: eventFile, options: .atomic)
            XCTAssertTrue(
                app.outlines["changes-list"].staticTexts[eventFile.lastPathComponent]
                    .firstMatch.waitForExistence(timeout: 10))
            let paintedEvent = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    records().contains { $0.name == "watcher" && $0.endedAtNanoseconds > stableWriteBegan }
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [paintedEvent], timeout: 5), .completed)
            let event = try XCTUnwrap(
                records().last { $0.name == "watcher" && $0.endedAtNanoseconds > stableWriteBegan })
            all.append(
                Sample(
                    name: "external-update",
                    milliseconds: Double(event.endedAtNanoseconds - stableWriteBegan) / 1_000_000,
                    peakRSSBytes: event.peakRSSBytes, endedAtNanoseconds: event.endedAtNanoseconds))
            app.terminate()
            try FileManager.default.removeItem(at: eventFile)
        }
        let data = try JSONEncoder().encode(all)
        try data.write(to: output.appending(path: "samples.json"), options: .atomic)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "workbench-samples.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        if count == 30 {
            let budgets: [String: Double] =
                manifest?["label"] as? String == "normal"
                ? ["shell": 500, "status": 300, "diff": 150, "history": 300, "external-update": 1_000] : [:]
            for (name, budget) in budgets {
                let values = all.filter { $0.name == name }.map(\.milliseconds).sorted()
                XCTAssertEqual(values.count, 30)
                XCTAssertLessThan(values[28], budget, "P95 \(name) is \(values[28]) ms")
            }
        }
    }
}
