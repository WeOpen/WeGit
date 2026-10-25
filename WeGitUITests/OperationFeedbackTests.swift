import AppKit
import XCTest

/// Run only in the hosted native suite. Every write is confined to UITestGit's
/// private repository and its local bare remote; faults use the existing Git helper.
final class OperationFeedbackTests: XCTestCase {
    @MainActor func testCommitFailureAndCancellationReplaceStagingSuccessAndPreserveDraft() throws {
        continueAfterFailure = false
        for (appearance, motion) in [("light", true), ("dark", false)] {
            let f = try fixture()
            defer { f.remove() }
            let head = try f.git(["rev-parse", "HEAD"])
            try Data("changed bytes\n".utf8).write(to: f.root.appending(path: "file.txt"))
            let hook = f.root.appending(path: ".git/hooks/pre-commit")
            try Data("#!/bin/sh\necho 'Feedback fixture rejects this commit' >&2\nexit 1\n".utf8)
                .write(to: hook)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
            let marker = f.root.appending(path: ".git/feedback-commit-delay")
            // The first attempt reaches the real rejecting hook. Removing this
            // private marker arms the next attempt for cancellation before Git runs.
            try Data("first attempt uses the hook\n".utf8).write(to: marker)
            let app = try application(
                f, appearance: appearance, motion: motion,
                environment: ["WEGIT_COMMIT_DELAY_MARKER": marker.path])
            defer { app.terminate() }
            app.launchWeGit()
            let draft = "Keep my draft in " + appearance
            let message = app.textFields["commit-message"]
            XCTAssertTrue(message.waitForExistence(timeout: 10))
            message.click()
            message.typeText(draft)
            let stage = app.checkBoxes["stage:unstaged:file.txt"]
            XCTAssertTrue(stage.waitForExistence(timeout: 10))
            waitEnabled(stage)
            stage.click()
            let staged = app.checkBoxes["stage:staged:file.txt"]
            XCTAssertTrue(staged.waitForExistence(timeout: 10))
            let success = waitFeedback("success", in: app.windows["main"]).label
            let commit = app.buttons["commit-button"]
            waitEnabled(commit)
            commit.click()
            let failure = waitFeedback("failure", in: app.windows["main"])
            XCTAssertFalse(failure.label.contains(success))
            XCTAssertEqual(message.value as? String, draft)
            XCTAssertEqual(try f.git(["rev-parse", "HEAD"]), head)
            XCTAssertEqual(try f.git(["show", ":file.txt"]), "changed bytes\n")
            XCTAssertTrue(staged.exists)
            XCTAssertTrue(try feedbackDetails(app).contains("Feedback fixture rejects this commit"))
            closeFeedbackDetails(app)
            try FileManager.default.removeItem(at: hook)
            try FileManager.default.removeItem(at: marker)
            waitEnabled(commit)
            commit.click()
            waitForFile(marker)
            _ = waitFeedback("busy", in: app.windows["main"])
            let cancel = app.windows["main"].toolbars.buttons["取消"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.click()
            let cancelled = waitFeedback("cancelled", in: app.windows["main"])
            XCTAssertFalse(cancelled.label.contains(success))
            XCTAssertEqual(message.value as? String, draft)
            XCTAssertEqual(try f.git(["rev-parse", "HEAD"]), head)
            XCTAssertEqual(try f.git(["show", ":file.txt"]), "changed bytes\n")
            retain(app, "Current commit cancellation preserves draft - " + appearance)
            waitEnabled(commit)
            commit.click()
            _ = waitFeedback("success", containing: "提交完成", in: app.windows["main"])
            XCTAssertEqual(try f.git(["log", "-1", "--format=%s"]), draft + "\n")
            XCTAssertEqual(try f.git(["rev-list", "--count", "HEAD"]), "2\n")
            XCTAssertEqual(message.value as? String, "")
        }
    }

    @MainActor func testLostCommitReplyRequiresReviewAndKeepsTheDraftForTheChangedHead() throws {
        continueAfterFailure = false
        let f = try fixture()
        defer { f.remove() }
        try Data("committed bytes\n".utf8).write(to: f.root.appending(path: "file.txt"))
        try f.git(["add", "file.txt"])
        let app = try application(
            f,
            environment: [
                "WEGIT_COMMIT_REPLY_LOSS_MARKER": f.root.appending(path: ".git/feedback-commit-reply").path
            ])
        defer { app.terminate() }
        app.launchWeGit()
        let message = app.textFields["commit-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        let draft = "Keep until the changed HEAD is reviewed"
        message.click()
        message.typeText(draft)
        let commit = app.buttons["commit-button"]
        waitEnabled(commit)
        commit.click()
        _ = waitFeedback("needs-review", containing: "HEAD 已变为", in: app.windows["main"])
        let head = try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(try f.git(["rev-list", "--count", "HEAD"]), "2\n")
        XCTAssertEqual(try f.git(["log", "-1", "--format=%s"]), draft + "\n")
        XCTAssertEqual(message.value as? String, draft)
        XCTAssertFalse(commit.isEnabled)
        let details = try feedbackDetails(app)
        XCTAssertTrue(details.contains(head))
        XCTAssertTrue(details.contains("fixture lost the commit response"))
        retain(app, "Unconfirmed commit exposes actual HEAD and keeps draft")
    }

    @MainActor func testCompletedPushWithUpstreamWarningKeepsCompletionAndReviewTone() throws {
        continueAfterFailure = false
        let f = try fixture()
        defer { f.remove() }
        let bare = try remote(f)
        let head = try f.git(["rev-parse", "HEAD"])
        let configuration = try Data(contentsOf: f.root.appending(path: ".git/config"))
        let app = try application(
            f,
            environment: [
                "WEGIT_UPSTREAM_WRITE_FAILURE_MARKER":
                    f.root.appending(path: ".git/feedback-upstream-write").path
            ])
        defer { app.terminate() }
        app.launchWeGit()
        push(app)
        XCTAssertTrue(app.staticTexts["推送完成"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["sync-verify-push"].exists)
        XCTAssertEqual(app.buttons["sync-close"].label, "完成")
        closeSync(app)
        _ = waitFeedback("needs-review", containing: "推送已完成", in: app.windows["main"])
        XCTAssertFalse(app.buttons["pending-push-action"].exists)
        XCTAssertEqual(try f.git(["--git-dir", bare.path, "rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: f.root.appending(path: ".git/config")), configuration)
        XCTAssertEqual(try f.git(["rev-list", "--count", "HEAD"]), "1\n")
        retain(app, "Push completed while upstream configuration needs review")
    }

    @MainActor func testUnmatchedAndAbsentPushVerificationPreservePendingUntilTheTargetMatches() throws {
        continueAfterFailure = false
        let f = try fixture()
        defer { f.remove() }
        let bare = try remote(f)
        try f.git(["push", "--set-upstream", "origin", "main"])
        let base = try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("delivered bytes\n".utf8).write(to: f.root.appending(path: "file.txt"))
        try f.git(["add", "file.txt"])
        try f.git(["commit", "-m", "Deliver once"])
        let head = try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let app = try application(
            f, environment: ["WEGIT_PUSH_REPLY_LOSS_MARKER": f.root.appending(path: ".git/reply-lost").path])
        defer { app.terminate() }
        app.launchWeGit()
        push(app)
        XCTAssertTrue(app.staticTexts["sync-push-unknown"].waitForExistence(timeout: 15))
        closeSync(app)
        _ = waitFeedback("needs-review", in: app.windows["main"])
        XCTAssertTrue(app.buttons["pending-push-action"].exists)
        try f.git(["--git-dir", bare.path, "update-ref", "refs/heads/main", base, head])
        verifyPendingPush(app)
        XCTAssertTrue(app.buttons["sync-prepare-new-push"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["远端目标已确认"].exists)
        closeSync(app)
        _ = waitFeedback("needs-review", containing: "与本次提交不同", in: app.windows["main"])
        XCTAssertTrue(app.buttons["pending-push-action"].exists)
        let details = try feedbackDetails(app)
        XCTAssertTrue(details.contains("refs/heads/main"))
        XCTAssertTrue(details.contains(head))
        XCTAssertTrue(details.contains(bare.path))
        closeFeedbackDetails(app)
        try f.git(["--git-dir", bare.path, "update-ref", "-d", "refs/heads/main", base])
        verifyPendingPush(app)
        XCTAssertTrue(app.buttons["sync-prepare-new-push"].waitForExistence(timeout: 10))
        closeSync(app)
        _ = waitFeedback("needs-review", containing: "未找到该远端分支", in: app.windows["main"])
        XCTAssertTrue(app.buttons["pending-push-action"].exists)
        XCTAssertEqual(try pushCount(f), 1)
        try f.git(["--git-dir", bare.path, "update-ref", "refs/heads/main", head])
        verifyPendingPush(app)
        XCTAssertTrue(app.staticTexts["远端目标已确认"].waitForExistence(timeout: 10))
        closeSync(app)
        _ = waitFeedback("success", in: app.windows["main"])
        XCTAssertFalse(app.buttons["pending-push-action"].exists)
        XCTAssertEqual(try f.git(["rev-parse", "HEAD"]), head + "\n")
        XCTAssertEqual(try f.git(["--git-dir", bare.path, "rev-parse", "HEAD"]), head + "\n")
        XCTAssertEqual(try pushCount(f), 1)
        retain(app, "Only a matching target clears pending push")
    }

    @MainActor func testTagUnknownAbsentAndDifferentObjectStayPendingUntilMatchingVerification() throws {
        continueAfterFailure = false
        let f = try fixture()
        defer { f.remove() }
        let bare = try remote(f)
        try f.git(["tag", "-a", "chosen", "-m", "Chosen annotation"])
        try f.git(["tag", "-a", "other", "-m", "Different annotation at the same commit"])
        let object = try f.git(["rev-parse", "refs/tags/chosen"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let head = try f.git(["rev-parse", "HEAD"])
        let app = try application(
            f, environment: ["WEGIT_PUSH_REPLY_LOSS_MARKER": f.root.appending(path: ".git/reply-lost").path])
        defer { app.terminate() }
        app.launchWeGit()
        XCTAssertTrue(app.buttons["toolbar-sidebar"].waitForExistence(timeout: 10))
        app.typeKey("5", modifierFlags: .command)
        let search = app.textFields["tag-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("chosen")
        let push = app.buttons["tag-push"]
        XCTAssertTrue(push.waitForExistence(timeout: 10))
        waitEnabled(push)
        push.click()
        let next = app.buttons["tag-push-confirm"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        waitEnabled(next)
        next.click()
        waitLabel("推送", on: next)
        next.click()
        _ = waitFeedback("needs-review", in: app.windows["main"].sheets.firstMatch)
        XCTAssertFalse(next.isEnabled)
        app.windows["main"].sheets.firstMatch.buttons["取消"].click()
        XCTAssertTrue(next.waitForNonExistence(timeout: 5))
        let verify = app.buttons["tag-verify-push"]
        XCTAssertTrue(verify.waitForExistence(timeout: 10))
        XCTAssertEqual(try f.git(["--git-dir", bare.path, "rev-parse", "refs/tags/chosen"]), object + "\n")
        try f.git(["--git-dir", bare.path, "update-ref", "-d", "refs/tags/chosen", object])
        waitEnabled(verify)
        verify.click()
        _ = waitFeedback("needs-review", containing: "远端尚无此标签", in: app.windows["main"])
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "tag-push-pending").firstMatch.exists)
        XCTAssertFalse(push.isEnabled)
        try f.git(["push", "origin", "refs/tags/other:refs/tags/chosen"])
        waitEnabled(verify)
        verify.click()
        _ = waitFeedback("needs-review", containing: "其他对象", in: app.windows["main"])
        XCTAssertTrue(verify.exists)
        XCTAssertFalse(push.isEnabled)
        let target = app.descendants(matching: .any).matching(identifier: "tag-push-target").firstMatch
        XCTAssertTrue(((target.value as? String) ?? target.label).contains(object))
        let details = try feedbackDetails(app)
        XCTAssertTrue(details.contains("refs/tags/chosen"))
        XCTAssertTrue(details.contains(object))
        XCTAssertTrue(details.contains(bare.path))
        closeFeedbackDetails(app)
        try f.git(["push", "--force", "origin", "refs/tags/chosen:refs/tags/chosen"])
        waitEnabled(verify)
        verify.click()
        _ = waitFeedback("success", containing: "已确认远端包含", in: app.windows["main"])
        XCTAssertTrue(verify.exists)
        app.buttons["tag-dismiss-push-notice"].click()
        XCTAssertTrue(verify.waitForNonExistence(timeout: 5))
        waitEnabled(push)
        XCTAssertEqual(try f.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try f.git(["tag", "--list"]), "chosen\nother\n")
        XCTAssertEqual(try pushCount(f), 1)
        retain(app, "Tag verification compares actual annotated objects")
    }

    @MainActor func testStashPopBeforeAndAfterDropFailuresExposeAppliedBytesAndTheRealList() throws {
        continueAfterFailure = false
        for (point, appearance, motion) in [("before", "light", true), ("after", "dark", false)] {
            let f = try fixture()
            defer { f.remove() }
            let file = f.root.appending(path: "file.txt")
            let head = try f.git(["rev-parse", "HEAD"])
            try Data("staged saved bytes\n".utf8).write(to: file)
            try f.git(["add", "file.txt"])
            try Data("working saved bytes\n".utf8).write(to: file)
            try f.git(["stash", "push", "-m", "Review after applying"])
            let object = try f.git(["rev-parse", "refs/stash"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let app = try application(
                f, appearance: appearance, motion: motion,
                environment: [
                    "WEGIT_STASH_DROP_FAILURE_MARKER": f.root.appending(path: ".git/feedback-stash-drop")
                        .path,
                    "WEGIT_STASH_DROP_FAILURE_POINT": point,
                ])
            defer { app.terminate() }
            app.launchWeGit()
            XCTAssertTrue(app.buttons["toolbar-sidebar"].waitForExistence(timeout: 10))
            app.typeKey("4", modifierFlags: .command)
            let pop = app.buttons["stash-pop"]
            XCTAssertTrue(pop.waitForExistence(timeout: 10))
            waitEnabled(pop)
            pop.click()
            let confirm = app.buttons["stash-confirm-action"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.click()
            _ = waitFeedback("needs-review", containing: "请勿重复恢复", in: app.windows["main"])
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "working saved bytes\n")
            XCTAssertEqual(try f.git(["show", ":file.txt"]), "staged saved bytes\n")
            XCTAssertEqual(try f.git(["rev-parse", "HEAD"]), head)
            let remaining = try f.git(["stash", "list", "--format=%H"])
            if point == "before" {
                XCTAssertEqual(remaining, object + "\n")
                XCTAssertTrue(
                    app.descendants(matching: .any).matching(identifier: "stash-list").firstMatch.exists)
                XCTAssertFalse(pop.isEnabled)
            } else {
                XCTAssertEqual(remaining, "")
                XCTAssertTrue(
                    app.descendants(matching: .any).matching(identifier: "stash-empty").firstMatch
                        .waitForExistence(timeout: 10))
                XCTAssertFalse(pop.exists)
            }
            let details = try feedbackDetails(app)
            XCTAssertTrue(details.contains("内容已应用"))
            XCTAssertTrue(details.contains("请勿重复恢复"))
            XCTAssertTrue(details.contains("Git 操作未完成"))
            retain(app, "Applied Stash with real remaining list - " + point)
        }
    }

    private func fixture() throws -> UITestGit {
        let f = try UITestGit(prefix: "WeGitFeedbackUI")
        do {
            try f.git(["init", "-b", "main"])
            try f.git(["config", "user.name", "UI Feedback Fixture"])
            try f.git(["config", "user.email", "ui@example.invalid"])
            try f.git(["config", "commit.gpgsign", "false"])
            try f.git(["config", "tag.gpgsign", "false"])
            try f.git(["config", "core.hooksPath", f.root.appending(path: ".git/hooks").path])
            try Data("base bytes\n".utf8).write(to: f.root.appending(path: "file.txt"))
            try f.git(["add", "."])
            try f.git(["commit", "-m", "Feedback fixture base"])
            return f
        } catch {
            f.remove()
            throw error
        }
    }

    private func remote(_ f: UITestGit) throws -> URL {
        let bare = f.root.appending(path: ".git/feedback-remote.git")
        try f.git(["init", "--bare", "-b", "main", bare.path])
        try f.git(["remote", "add", "origin", bare.path])
        return bare
    }

    @MainActor private func application(
        _ f: UITestGit, appearance: String = "light", motion: Bool = true,
        environment: [String: String] = [:]
    ) throws -> XCUIApplication {
        let wrapper = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "WeGitTestGit", withExtension: nil))
        let app = XCUIApplication()
        app.launchArguments = [
            "-gitExecutable", wrapper.path, "-appearance", appearance,
            "-interfaceMotion", motion ? "YES" : "NO", "--uitesting",
        ]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = f.root.path
        app.launchEnvironment["WEGIT_OPERATION_FEEDBACK_FIXTURE"] = f.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        return app
    }

    @MainActor private func waitFeedback(
        _ kind: String, containing message: String = "", in scope: XCUIElement
    ) -> XCUIElement {
        let row = scope.descendants(matching: .any).matching(identifier: "operation-feedback").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), scope.debugDescription)
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ AND label CONTAINS %@", kind, message), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, row.debugDescription)
        return row
    }

    @MainActor private func feedbackDetails(_ app: XCUIApplication) throws -> String {
        let message = app.windows["main"].buttons["operation-feedback-message"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.click()
        let details = app.descendants(matching: .any).matching(identifier: "operation-feedback-details")
            .firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        let content = (details.value as? String) ?? details.label
        let evidence = XCTAttachment(string: content + "\n" + details.debugDescription)
        evidence.name = "Complete operation feedback and accessible detail"
        evidence.lifetime = .keepAlways
        add(evidence)
        return content
    }

    @MainActor private func closeFeedbackDetails(_ app: XCUIApplication) {
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "operation-feedback-details").firstMatch
                .waitForNonExistence(timeout: 5))
    }

    @MainActor private func push(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["toolbar-sidebar"].waitForExistence(timeout: 10))
        let action = app.toolbarSyncAction("toolbar-push")
        waitEnabled(action)
        action.click()
        let check = app.buttons["sync-check-target"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        waitEnabled(check)
        check.click()
        let push = app.buttons["sync-push-confirm"]
        XCTAssertTrue(push.waitForExistence(timeout: 5))
        waitEnabled(push)
        push.click()
    }

    @MainActor private func verifyPendingPush(_ app: XCUIApplication) {
        let pending = app.buttons["pending-push-action"]
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        waitEnabled(pending)
        pending.click()
        let verify = app.buttons["sync-verify-push"]
        XCTAssertTrue(verify.waitForExistence(timeout: 5))
        waitEnabled(verify)
        verify.click()
    }

    @MainActor private func closeSync(_ app: XCUIApplication) {
        let close = app.buttons["sync-close"]
        let idle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", "取消操作"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 15), .completed)
        close.click()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    @MainActor private func waitEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    @MainActor private func waitLabel(_ label: String, on element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    @MainActor private func waitForFile(_ url: URL) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: url.path) },
            object: NSObject())
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    private func pushCount(_ f: UITestGit) throws -> Int {
        try String(contentsOf: f.root.appending(path: ".git/reply-lost-commands"), encoding: .utf8)
            .filter { $0 == "P" }.count
    }

    @MainActor private func retain(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
