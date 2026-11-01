import XCTest

final class RebaseWorkflowTests: XCTestCase {
    @MainActor func testFixedTargetReplayAndRecoverAcrossRelaunch() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitIndependentRebaseUI")
        defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        let repo = fixture.root.appending(path: "repo").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: false)
        @discardableResult func git(_ args: [String]) throws -> String { try UITestGit.run(args, in: repo) }
        func write(_ path: String, _ value: String) throws {
            try Data(value.utf8).write(to: repo.appending(path: path))
        }
        func head() throws -> String { try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines) }
        try git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Rebase UI"), ("user.email", "fixture@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", fixture.root.appending(path: "no-hooks").path),
        ] { try git(["config", key, value]) }
        try write("file.txt", "base\n")
        try write("second.txt", "base second\n")
        try git(["add", "."])
        try git(["commit", "-m", "Base"])
        let base = try head()
        try git(["switch", "-c", "feature"])
        let longName = "保留原始内容的很长中文文件名称与变基范围.txt"
        try write(longName, "feature bytes\n")
        try git(["add", "."])
        try git(["commit", "-m", "中文提交与固定重放范围"])
        let original = try head()
        try git(["branch", "other-reference", original])
        let bare = fixture.root.appending(path: "remote.git")
        try git(["init", "--bare", bare.path])
        try git(["remote", "add", "origin", bare.path])
        try git(["push", "origin", "feature"])
        try git(["switch", "main"])
        try write("target.txt", "target bytes\n")
        try git(["add", "."])
        try git(["commit", "-m", "Target"])
        let target = try head()
        try git(["switch", "feature"])
        let initialIndex = try Data(contentsOf: repo.appending(path: ".git/index"))

        let app = XCUIApplication()
        let windowNamespace = UUID().uuidString
        let windowArguments = [
            "-NSWindow Frame WeGit.UITests." + windowNamespace,
            "70 70 980 692 0 0 1920 1080 ", "--uitesting-window-state", windowNamespace,
        ]
        app.launchArguments =
            [
                "-appearance", "light", "-language", "zh-Hans", "-confirmRepositorySwitch", "NO",
                "--uitesting",
            ] + windowArguments
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = repo.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertLessThanOrEqual(app.windows["main"].frame.width, 1000)
        XCTAssertGreaterThanOrEqual(app.windows["main"].frame.width, 980)
        let draft = app.textFields["commit-message"]
        XCTAssertTrue(draft.exists || draft.waitForExistence(timeout: 10))
        draft.click()
        draft.typeText("Keep rebase draft 中文")
        route(app, "分支")
        let filter = app.textFields["branches-filter"]
        replace(filter, text: "main")
        preview(app)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "rebase-head").firstMatch.label.contains(
                original))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "rebase-target-oid").firstMatch.label
                .contains(target))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "rebase-base").firstMatch.label.contains(
                base))
        let published = app.checkBoxes["rebase-published-confirm"]
        XCTAssertTrue(published.exists)
        XCTAssertFalse(app.buttons["rebase-execute"].isEnabled)
        published.click()
        waitEnabled(app.buttons["rebase-execute"])
        app.typeKey(.tab, modifierFlags: [])
        capture(app, "Chinese light immutable rebase preview and published confirmation")
        app.typeKey(.escape, modifierFlags: [])
        waitGone(app.buttons["rebase-execute"])
        app.typeText("X")
        expectValue(filter, "mainX")
        XCTAssertEqual(try head(), original)
        XCTAssertEqual(try Data(contentsOf: repo.appending(path: ".git/index")), initialIndex)
        replace(filter, text: "main")

        preview(app)
        if app.checkBoxes["rebase-published-confirm"].exists {
            app.checkBoxes["rebase-published-confirm"].click()
        }
        waitEnabled(app.buttons["rebase-execute"])
        try git(["update-ref", "refs/heads/main", base, target])
        app.buttons["rebase-execute"].click()
        waitEnabled(app.buttons["rebase-refresh"])
        let feedback = app.windows["main"].sheets.firstMatch.descendants(matching: .any)
            .matching(identifier: "operation-feedback").firstMatch
        let failed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "失败: "), object: feedback)
        let failureState = XCTWaiter.wait(for: [failed], timeout: 10)
        capture(app, "Moved target refuses the old rebase confirmation")
        XCTAssertEqual(failureState, .completed, feedback.debugDescription)
        XCTAssertTrue(feedback.label.hasPrefix("失败: "))
        XCTAssertEqual(try head(), original)
        XCTAssertEqual(try Data(contentsOf: repo.appending(path: ".git/index")), initialIndex)
        app.buttons["rebase-cancel"].click()
        waitGone(app.buttons["rebase-refresh"])
        try git(["update-ref", "refs/heads/main", target, base])
        preview(app)
        if app.checkBoxes["rebase-published-confirm"].exists {
            app.checkBoxes["rebase-published-confirm"].click()
        }
        waitEnabled(app.buttons["rebase-execute"])
        app.typeKey(.return, modifierFlags: [])
        waitGone(app.buttons["rebase-cancel"])
        XCTAssertEqual(try git(["rev-parse", "HEAD^"]).trimmingCharacters(in: .newlines), target)
        XCTAssertEqual(
            try git(["symbolic-ref", "HEAD"]).trimmingCharacters(in: .newlines), "refs/heads/feature")
        XCTAssertEqual(try Data(contentsOf: repo.appending(path: longName)), Data("feature bytes\n".utf8))
        XCTAssertEqual(
            try git(["rev-parse", "refs/heads/other-reference"]).trimmingCharacters(in: .newlines), original)
        route(app, "更改")
        expectValue(draft, "Keep rebase draft 中文")

        try write("file.txt", "local first\n")
        try git(["commit", "-am", "First local"])
        try write("second.txt", "local second\n")
        try git(["commit", "-am", "Second local"])
        try git(["switch", "main"])
        try write("file.txt", "remote first\n")
        try write("second.txt", "remote second\n")
        try git(["commit", "-am", "Conflicting target"])
        let conflictTarget = try head()
        try git(["switch", "feature"])
        route(app, "分支")
        preview(app)
        acknowledgePublished(app)
        app.buttons["rebase-execute"].click()
        waitEnabled(app.buttons["rebase-show-changes"])
        app.buttons["rebase-show-changes"].click()
        let next = app.buttons["sequencer-continue"]
        XCTAssertTrue(next.exists || next.waitForExistence(timeout: 10))
        XCTAssertFalse(next.isEnabled)
        try write("file.txt", "resolved first\n")
        resolve(app, "file.txt", english: false)
        waitEnabled(next)
        next.click()
        XCTAssertTrue(
            app.buttons["stage:conflict:second.txt"].exists
                || app.buttons["stage:conflict:second.txt"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments =
            [
                "-appearance", "dark", "-language", "en", "-confirmRepositorySwitch", "NO", "--uitesting",
                "--uitesting-keep-preferences",
            ] + windowArguments
        app.launchWeGit()
        XCTAssertTrue(next.exists || next.waitForExistence(timeout: 10))
        XCTAssertFalse(next.isEnabled)
        expectValue(draft, "Keep rebase draft 中文")
        capture(app, "English dark second conflict restored after relaunch")
        try write("second.txt", "resolved second\n")
        resolve(app, "second.txt", english: true)
        waitEnabled(next)
        next.click()
        waitGone(next)
        try git(["merge-base", "--is-ancestor", conflictTarget, "HEAD"])
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
        XCTAssertEqual(try Data(contentsOf: repo.appending(path: "file.txt")), Data("resolved first\n".utf8))
        XCTAssertEqual(
            try Data(contentsOf: repo.appending(path: "second.txt")), Data("resolved second\n".utf8))

        try write("file.txt", "abort local\n")
        try git(["commit", "-am", "Local before abort"])
        let beforeAbort = try head()
        let abortBytes = try Data(contentsOf: repo.appending(path: "file.txt"))
        try git(["switch", "main"])
        try write("file.txt", "abort target\n")
        try git(["commit", "-am", "New conflicting target"])
        try git(["switch", "feature"])
        route(app, "分支")
        preview(app)
        acknowledgePublished(app)
        app.buttons["rebase-execute"].click()
        waitEnabled(app.buttons["rebase-show-changes"])
        app.buttons["rebase-show-changes"].click()
        waitEnabled(app.buttons["sequencer-abort"])
        app.buttons["sequencer-abort"].click()
        let abort = app.buttons["Abort"].firstMatch
        waitEnabled(abort)
        abort.click()
        waitGone(next)
        XCTAssertEqual(try head(), beforeAbort)
        XCTAssertEqual(try Data(contentsOf: repo.appending(path: "file.txt")), abortBytes)
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
        XCTAssertEqual(
            try git(["symbolic-ref", "HEAD"]).trimmingCharacters(in: .newlines), "refs/heads/feature")
        expectValue(draft, "Keep rebase draft 中文")
        capture(app, "Confirmed abort restores the original branch and preserves the draft")
    }

    @MainActor private func route(_ app: XCUIApplication, _ name: String) {
        let element = app.staticTexts["route-" + name].firstMatch
        XCTAssertTrue(element.exists || element.waitForExistence(timeout: 10))
        element.click()
    }
    @MainActor private func preview(_ app: XCUIApplication) {
        waitEnabled(app.buttons["branches-rebase"])
        app.buttons["branches-rebase"].click()
        let target = app.popUpButtons["rebase-target-picker"]
        waitEnabled(target)
        target.click()
        let main = app.menuItems["main"].firstMatch
        XCTAssertTrue(main.exists || main.waitForExistence(timeout: 5))
        main.click()
        let head = app.descendants(matching: .any).matching(identifier: "rebase-head").firstMatch
        XCTAssertTrue(head.exists || head.waitForExistence(timeout: 10))
    }
    @MainActor private func acknowledgePublished(_ app: XCUIApplication) {
        let checkbox = app.checkBoxes["rebase-published-confirm"]
        if checkbox.exists { checkbox.click() }
        waitEnabled(app.buttons["rebase-execute"])
    }
    @MainActor private func resolve(_ app: XCUIApplication, _ path: String, english: Bool) {
        let stage = app.buttons["stage:conflict:" + path]
        waitEnabled(stage)
        stage.click()
        let confirm = app.buttons[english ? "Mark as resolved" : "标记已解决"].firstMatch
        waitEnabled(confirm)
        confirm.click()
    }
    @MainActor private func replace(_ element: XCUIElement, text: String) {
        waitEnabled(element)
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeKey(.delete, modifierFlags: [])
        element.typeText(text)
    }
    @MainActor private func waitEnabled(_ element: XCUIElement) {
        let predicate = NSPredicate(format: "exists == true AND enabled == true")
        if !predicate.evaluate(with: element) {
            let ready = XCTNSPredicateExpectation(
                predicate: predicate, object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, element.debugDescription)
        }
    }
    @MainActor private func waitGone(_ element: XCUIElement) {
        if element.exists { XCTAssertTrue(element.waitForNonExistence(timeout: 10)) }
    }
    @MainActor private func expectValue(_ element: XCUIElement, _ value: String) {
        if !element.exists || element.value as? String != value {
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in element.exists && element.value as? String == value },
                object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        }
        XCTAssertEqual(element.value as? String, value)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows["main"].screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let state = XCTAttachment(string: app.windows["main"].debugDescription)
        state.name = name + " AX"
        state.lifetime = .keepAlways
        add(state)
    }
}
