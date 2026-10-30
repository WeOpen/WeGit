import AppKit
import XCTest

final class WorkflowRecoveryTests: XCTestCase {
    private func prepare(_ fixture: UITestGit) throws {
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Fixture"])
        try fixture.git(["config", "user.email", "fixture@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
    }
    private func write(_ text: String, fixture: UITestGit) throws {
        try Data(text.utf8).write(to: fixture.root.appending(path: "file.txt"))
    }
    @MainActor private func application(_ fixture: UITestGit) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        return app
    }
    @MainActor func testMergeConflictCanContinueOrAbort() throws {
        continueAfterFailure = false
        for abort in [false, true] {
            let fixture = try UITestGit(prefix: "WeGitMergeRecoveryUI")
            defer { fixture.remove() }
            try prepare(fixture)
            try write("base\n", fixture: fixture)
            try fixture.git(["add", "."])
            try fixture.git(["commit", "-m", "Base"])
            try fixture.git(["switch", "-c", "feature"])
            try write("incoming\n", fixture: fixture)
            try fixture.git(["commit", "-am", "Incoming"])
            let incoming = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(
                in: .whitespacesAndNewlines)
            try fixture.git(["switch", "main"])
            try write("main\n", fixture: fixture)
            try fixture.git(["commit", "-am", "Main"])
            let main = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let app = application(fixture)
            defer { app.terminate() }
            let route = app.staticTexts["route-分支"].firstMatch
            XCTAssertTrue(route.waitForExistence(timeout: 10))
            route.click()
            let merge = app.buttons["branch-merge:refs/heads/feature"]
            XCTAssertTrue(merge.waitForExistence(timeout: 10))
            merge.click()
            XCTAssertTrue(app.buttons["合并"].waitForExistence(timeout: 3))
            app.buttons["合并"].firstMatch.click()
            let next = app.buttons["sequencer-continue"]
            XCTAssertTrue(next.waitForExistence(timeout: 10))
            XCTAssertFalse(next.isEnabled)
            if abort {
                app.buttons["sequencer-abort"].click()
                XCTAssertTrue(app.buttons["中止"].waitForExistence(timeout: 3))
                app.buttons["中止"].firstMatch.click()
            } else {
                app.staticTexts["route-更改"].firstMatch.click()
                try write("resolved\n", fixture: fixture)
                let resolve = app.buttons["stage:conflict:file.txt"]
                XCTAssertTrue(resolve.waitForExistence(timeout: 10))
                resolve.click()
                XCTAssertTrue(app.buttons["标记已解决"].waitForExistence(timeout: 3))
                app.buttons["标记已解决"].firstMatch.click()
                let ready = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "enabled == true"), object: next)
                XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
                next.click()
            }
            let finished = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: next)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
            XCTAssertEqual(try fixture.git(["status", "--porcelain"]), "")
            if abort {
                XCTAssertEqual(
                    try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
                    main)
                XCTAssertEqual(
                    try String(contentsOf: fixture.root.appending(path: "file.txt"), encoding: .utf8),
                    "main\n")
            } else {
                let parents = try fixture.git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(
                    whereSeparator: { $0.isWhitespace })
                XCTAssertEqual(parents.dropFirst().map(String.init), [main, incoming])
                XCTAssertEqual(
                    try String(contentsOf: fixture.root.appending(path: "file.txt"), encoding: .utf8),
                    "resolved\n")
            }
            app.terminate()
        }
    }

    @MainActor func testConflictEditorPreservesIndexUntilResolveAndGuardsUnsavedClose() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitIndependentConflictEditorUI")
        defer { fixture.remove() }
        try prepare(fixture)
        try write("base\n", fixture: fixture)
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Base"])
        try fixture.git(["switch", "-c", "feature"])
        try write("theirs\n", fixture: fixture)
        try fixture.git(["commit", "-am", "Theirs"])
        try fixture.git(["switch", "main"])
        try write("ours\n", fixture: fixture)
        try fixture.git(["commit", "-am", "Ours"])
        try fixture.git(["switch", "feature"])
        do {
            _ = try fixture.git(["merge", "main"])
            XCTFail("The fixture merge should stop on a content conflict")
        } catch {
            XCTAssertTrue(try fixture.git(["status", "--porcelain"]).contains("UU file.txt"))
        }
        let indexBefore = try fixture.git(["ls-files", "--stage", "-z"])

        let app = application(fixture)
        defer { app.terminate() }
        app.staticTexts["route-更改"].firstMatch.click()
        let edit = app.buttons["edit-conflict:file.txt"]
        XCTAssertTrue(edit.exists || edit.waitForExistence(timeout: 10))
        edit.click()
        for side in ["base", "ours", "theirs", "result"] {
            let panel = app.descendants(matching: .any)
                .matching(identifier: "conflict-editor-" + side).firstMatch
            XCTAssertTrue(panel.exists || panel.waitForExistence(timeout: 10), side)
        }
        let result = app.textViews["conflict-editor-result"]
        XCTAssertTrue(result.exists || result.waitForExistence(timeout: 10))
        result.click()
        result.typeKey("a", modifierFlags: .command)
        result.typeText("resolved from UI\n")
        app.buttons["conflict-editor-close"].click()
        let unsaved = app.descendants(matching: .any)
            .matching(identifier: "conflict-editor-unsaved").firstMatch
        XCTAssertTrue(
            unsaved.exists || app.buttons["Continue Editing"].waitForExistence(timeout: 5),
            app.debugDescription)
        if app.buttons["Continue Editing"].exists { app.buttons["Continue Editing"].click() }
        app.buttons["conflict-editor-save"].click()
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: app.buttons["conflict-editor-mark-resolved"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        XCTAssertEqual(try fixture.git(["ls-files", "--stage", "-z"]), indexBefore)
        app.buttons["conflict-editor-close"].click()
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.click()
        let reopenedResult = app.textViews["conflict-editor-result"]
        XCTAssertTrue(reopenedResult.waitForExistence(timeout: 10))
        XCTAssertEqual(reopenedResult.value as? String, "resolved from UI\n")
        app.buttons["conflict-editor-mark-resolved"].click()
        XCTAssertTrue(
            app.buttons["edit-conflict:file.txt"].waitForNonExistence(timeout: 10),
            app.debugDescription)
        XCTAssertEqual(try fixture.git(["ls-files", "--unmerged"]), "")
        XCTAssertEqual(try fixture.git(["show", ":file.txt"]), "resolved from UI\n")
        XCTAssertEqual(
            try Data(contentsOf: fixture.root.appending(path: "file.txt")),
            Data("resolved from UI\n".utf8))

        try fixture.git(["commit", "-m", "Resolve initial merge"])
        try fixture.git(["switch", "main"])
        try write("new target\n", fixture: fixture)
        try fixture.git(["commit", "-am", "New target"])
        try fixture.git(["switch", "feature"])
        try write("new feature\n", fixture: fixture)
        try fixture.git(["commit", "-am", "New feature"])
        do {
            _ = try fixture.git(["merge", "main"])
            XCTFail("The second merge should stop on a content conflict")
        } catch {
            XCTAssertTrue(try fixture.git(["status", "--porcelain"]).contains("UU file.txt"))
        }
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.click()
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.click()
        result.typeKey("a", modifierFlags: .command)
        let draftAfterFailure = "keep my result draft after the external edit\n"
        result.typeText(draftAfterFailure)
        let indexBeforeExternalEdit = try fixture.git(["ls-files", "--stage", "-z"])
        try write("external replacement\n", fixture: fixture)
        app.buttons["conflict-editor-save"].click()
        let saveError = app.descendants(matching: .any)
            .matching(identifier: "conflict-editor-error").firstMatch
        XCTAssertTrue(saveError.waitForExistence(timeout: 10))
        XCTAssertEqual(result.value as? String, draftAfterFailure)
        XCTAssertTrue(app.buttons["conflict-editor-save"].isEnabled)
        XCTAssertEqual(
            try fixture.git(["ls-files", "--stage", "-z"]), indexBeforeExternalEdit)
        XCTAssertEqual(
            try Data(contentsOf: fixture.root.appending(path: "file.txt")),
            Data("external replacement\n".utf8))
    }

    @MainActor func testExternalGitChangesUpdateVisibleStatusWithoutManualRefresh() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitWatcherUI")
        defer { fixture.remove() }
        try prepare(fixture)
        try write("base\n", fixture: fixture)
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Base"])
        try fixture.git(["branch", "feature"])
        let app = application(fixture)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["工作区干净"].firstMatch.waitForExistence(timeout: 10))
        try write("external\n", fixture: fixture)
        XCTAssertTrue(app.checkBoxes["stage:unstaged:file.txt"].waitForExistence(timeout: 5))
        try fixture.git(["add", "file.txt"])
        XCTAssertTrue(app.checkBoxes["stage:staged:file.txt"].waitForExistence(timeout: 5))
        try fixture.git(["commit", "-m", "External commit"])
        XCTAssertTrue(app.staticTexts["工作区干净"].firstMatch.waitForExistence(timeout: 5))
        try fixture.git(["switch", "feature"])
        let switched = app.menuButtons["当前分支：feature"].firstMatch
        XCTAssertTrue(switched.waitForExistence(timeout: 5))
        XCTAssertEqual(switched.identifier, "current-branch")
        try fixture.git(["reset", "--soft", "main"])
        XCTAssertTrue(app.checkBoxes["stage:staged:file.txt"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            try String(contentsOf: fixture.root.appending(path: "file.txt"), encoding: .utf8), "base\n")
    }

    @MainActor func testPullRebaseHandlesTwoConflictRoundsAndAbort() throws {
        continueAfterFailure = false
        for abort in [false, true] {
            let fixture = try UITestGit(prefix: "WeGitPullRebaseUI")
            let remote = fixture.root.appendingPathExtension("remote.git")
            let updater = fixture.root.appendingPathExtension("updater")
            defer {
                fixture.remove()
                try? FileManager.default.removeItem(at: remote)
                try? FileManager.default.removeItem(at: updater)
            }
            try prepare(fixture)
            try write("base-a\nbase-b\n", fixture: fixture)
            try fixture.git(["add", "."])
            try fixture.git(["commit", "-m", "Base"])
            try fixture.git(["init", "--bare", "-b", "main", remote.path])
            try fixture.git(["remote", "add", "origin", remote.path])
            try fixture.git(["push", "--set-upstream", "origin", "main"])
            try fixture.git(["clone", remote.path, updater.path])
            try write("local-a\nbase-b\n", fixture: fixture)
            try fixture.git(["commit", "-am", "Local A"])
            try write("local-a\nlocal-b\n", fixture: fixture)
            try fixture.git(["commit", "-am", "Local B"])
            let localHead = try fixture.git(["rev-parse", "HEAD"])
            try fixture.git(["config", "pull.rebase", "true"])
            try Data("remote-a\nremote-b\n".utf8).write(to: updater.appending(path: "file.txt"))
            try UITestGit.run(
                [
                    "-c", "user.name=UI Fixture", "-c", "user.email=fixture@example.invalid", "-c",
                    "commit.gpgsign=false", "commit", "-am", "Remote",
                ], in: updater)
            try UITestGit.run(["push", "origin", "main"], in: updater)
            let remoteHead = try UITestGit.run(["rev-parse", "HEAD"], in: updater).trimmingCharacters(
                in: .whitespacesAndNewlines)
            let app = application(fixture)
            defer { app.terminate() }
            let pull = app.toolbarSyncAction("toolbar-pull")
            XCTAssertTrue(pull.waitForExistence(timeout: 10))
            let available = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"), object: pull)
            XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 10), .completed)
            pull.click()
            let confirm = app.buttons["sync-pull-confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            XCTAssertEqual(app.popUpButtons["sync-pull-strategy"].value as? String, "变基")
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"), object: confirm)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            confirm.click()
            let continuation = app.buttons["sequencer-continue"]
            XCTAssertTrue(continuation.waitForExistence(timeout: 10))
            app.buttons["sync-close"].click()
            if abort {
                app.buttons["sequencer-abort"].click()
                app.buttons["中止"].firstMatch.click()
            } else {
                for resolution in ["resolved-a\nremote-b\n", "resolved-a\nresolved-b\n"] {
                    XCTAssertFalse(continuation.isEnabled)
                    try write(resolution, fixture: fixture)
                    let resolve = app.buttons["stage:conflict:file.txt"]
                    XCTAssertTrue(resolve.waitForExistence(timeout: 10))
                    resolve.click()
                    app.buttons["标记已解决"].firstMatch.click()
                    let resolved = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "enabled == true"), object: continuation)
                    XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 10), .completed)
                    continuation.click()
                    if resolution.contains("remote-b") {
                        XCTAssertTrue(app.buttons["stage:conflict:file.txt"].waitForExistence(timeout: 10))
                    }
                }
            }
            let finished = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: continuation)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
            XCTAssertEqual(try fixture.git(["status", "--porcelain"]), "")
            if abort {
                XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), localHead)
                XCTAssertEqual(
                    try String(contentsOf: fixture.root.appending(path: "file.txt"), encoding: .utf8),
                    "local-a\nlocal-b\n")
            } else {
                XCTAssertEqual(
                    try fixture.git(["rev-parse", "HEAD~2"]).trimmingCharacters(in: .whitespacesAndNewlines),
                    remoteHead)
                XCTAssertEqual(
                    try String(contentsOf: fixture.root.appending(path: "file.txt"), encoding: .utf8),
                    "resolved-a\nresolved-b\n")
            }
            app.terminate()
        }
    }

    @MainActor func testActualTrashReceiptAndFeedbackIdentifyOnlyTheFixtureFile() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitActualTrashUI")
        defer { fixture.remove() }
        try prepare(fixture)
        let name = "WeGit-disposable-" + UUID().uuidString + ".txt"
        let candidate = fixture.root.appending(path: name)
        let payload = Data("Only this fixture may be recycled and restored.\n".utf8)
        try payload.write(to: candidate)
        let original = try FileManager.default.attributesOfItem(atPath: candidate.path)
        let app = application(fixture)
        defer { app.terminate() }
        let file = app.outlines["changes-list"].staticTexts[name].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.rightClick()
        app.menuItems["移到废纸篓…"].click()
        XCTAssertTrue(app.buttons["移到废纸篓"].waitForExistence(timeout: 3))
        app.buttons["移到废纸篓"].firstMatch.click()
        let feedback = app.buttons["show-trashed-file"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 10))
        let path = try XCTUnwrap(feedback.value as? String)
        let moved = URL(fileURLWithPath: path)
        XCTAssertEqual(moved.lastPathComponent, name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertFalse(file.exists)
        app.menuBars.menuBarItems["工作区"].click()
        app.menuItems["核对并恢复回收夹具"].click()
        XCTAssertTrue(app.staticTexts["回收夹具已核对并恢复"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: candidate), payload)
        let after = try FileManager.default.attributesOfItem(atPath: candidate.path)
        XCTAssertEqual(after[.systemFileNumber] as? NSNumber, original[.systemFileNumber] as? NSNumber)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))
    }
}
