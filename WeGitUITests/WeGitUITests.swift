import Darwin
import XCTest

final class WeGitUITests: XCTestCase {
    @MainActor func testLostPushReplyRestoresVerificationAfterLocalHeadMoves() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitPushUnknownUI")
        let bare = fixture.root.appendingPathExtension("remote.git")
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: bare)
        }
        try prepareReplyLossFixture(fixture, bare: bare, published: false)
        try Data("delivered\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Delivered before lost reply"])
        let delivered = try fixture.git(["rev-parse", "HEAD"])
        let app = try replyLossApplication(fixture)
        defer { app.terminate() }
        app.launchWeGit()
        try pushUntilReplyIsLost(app)
        XCTAssertFalse(app.buttons["sync-check-target"].exists)
        XCTAssertFalse(app.buttons["sync-push-confirm"].exists)
        XCTAssertEqual(try fixture.git(["--git-dir", bare.path, "rev-parse", "HEAD"]), delivered)
        app.buttons["sync-close"].click()
        app.terminate()
        try Data("new local work\n".utf8).write(to: fixture.root.appending(path: "newer"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Newer local commit"])
        let newer = try fixture.git(["rev-parse", "HEAD"])
        app.launchArguments.append("--uitesting-keep-preferences")
        app.launchWeGit()
        let pending = app.buttons["pending-push-action"]
        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        pending.click()
        let verify = app.buttons["sync-verify-push"]
        XCTAssertTrue(verify.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: verify)
        waitForExpectations(timeout: 5)
        verify.click()
        XCTAssertTrue(app.staticTexts["远端目标已确认"].waitForExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), newer)
        XCTAssertEqual(try fixture.git(["--git-dir", bare.path, "rev-parse", "HEAD"]), delivered)
        XCTAssertEqual(try replyLossCommands(fixture).filter { $0 == "P" }.count, 1)
        app.buttons["sync-close"].click()
        XCTAssertFalse(pending.exists)
    }

    @MainActor func testCommitAndPushLostReplyOnlyVerifiesTheDeliveredCommit() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitCommitReplyLossUI")
        let bare = fixture.root.appendingPathExtension("remote.git")
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: bare)
        }
        try prepareReplyLossFixture(fixture, bare: bare, published: true)
        try Data("commit once\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        let app = try replyLossApplication(fixture)
        defer { app.terminate() }
        app.launchWeGit()
        let message = app.textFields["commit-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.click()
        message.typeText("Commit once despite a missing reply")
        app.buttons["commit-push-button"].click()
        let commit = app.buttons["sync-commit-push-confirm"]
        XCTAssertTrue(commit.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: commit)
        waitForExpectations(timeout: 5)
        commit.click()
        XCTAssertTrue(app.staticTexts["sync-push-unknown"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "sync-commit-completed").firstMatch.exists)
        let head = try fixture.git(["rev-parse", "HEAD"])
        let verify = app.buttons["sync-verify-push"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: verify)
        waitForExpectations(timeout: 5)
        verify.click()
        XCTAssertTrue(app.staticTexts["远端目标已确认"].waitForExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-list", "--count", "HEAD"]), "2\n")
        XCTAssertEqual(try replyLossCommands(fixture).filter { $0 == "P" }.count, 1)
        app.buttons["sync-close"].click()
        XCTAssertEqual(message.value as? String, "")
    }

    @MainActor func testRestoredUnknownPushRefusesAChangedDestination() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitChangedPushTargetUI")
        let bare = fixture.root.appendingPathExtension("remote.git")
        let other = fixture.root.appendingPathExtension("other.git")
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: bare)
            try? FileManager.default.removeItem(at: other)
        }
        try prepareReplyLossFixture(fixture, bare: bare, published: true)
        try fixture.git(["clone", "--bare", "--", bare.path, other.path])
        let base = try fixture.git(["rev-parse", "HEAD"])
        try Data("delivered\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Pinned uncertain destination"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try replyLossApplication(fixture)
        defer { app.terminate() }
        app.launchWeGit()
        try pushUntilReplyIsLost(app)
        app.buttons["sync-close"].click()
        app.terminate()
        let commands = try replyLossCommands(fixture)
        try fixture.git(["config", "remote.origin.url", other.path])
        app.launchArguments.append("--uitesting-keep-preferences")
        app.launchWeGit()
        let pending = app.buttons["pending-push-action"]
        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        pending.click()
        let verify = app.buttons["sync-verify-push"]
        XCTAssertTrue(verify.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: verify)
        waitForExpectations(timeout: 5)
        verify.click()
        let error = app.descendants(matching: .any).matching(identifier: "sync-error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(((error.value as? String) ?? error.label).contains("地址已变化"))
        XCTAssertEqual(try replyLossCommands(fixture), commands)
        XCTAssertEqual(try fixture.git(["--git-dir", bare.path, "rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["--git-dir", other.path, "rev-parse", "HEAD"]), base)
        XCTAssertFalse(app.buttons["sync-push-confirm"].exists)
        try fixture.git(["config", "remote.origin.url", bare.path])
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: verify)
        waitForExpectations(timeout: 5)
        verify.click()
        XCTAssertTrue(app.staticTexts["远端目标已确认"].waitForExistence(timeout: 10))
        XCTAssertEqual(try replyLossCommands(fixture).filter { $0 == "P" }.count, 1)
    }

    @MainActor private func prepareReplyLossFixture(_ fixture: UITestGit, bare: URL, published: Bool) throws {
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Test"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Base"])
        try fixture.git(["init", "--bare", "-b", "main", bare.path])
        try fixture.git(["remote", "add", "origin", bare.path])
        if published { try fixture.git(["push", "--set-upstream", "origin", "main"]) }
    }

    @MainActor func testUnknownPushRequiresNewConfirmationWhenTargetDoesNotMatch() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitPushReconfirmationUI")
        let bare = fixture.root.appendingPathExtension("remote.git")
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: bare)
        }
        try prepareReplyLossFixture(fixture, bare: bare, published: true)
        let base = try fixture.git(["rev-parse", "HEAD"])
        try Data("delivered\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Require new push confirmation"])
        let head = try fixture.git(["rev-parse", "HEAD"])
        let app = try replyLossApplication(fixture)
        defer { app.terminate() }
        app.launchWeGit()
        try pushUntilReplyIsLost(app)
        try fixture.git([
            "--git-dir", bare.path, "update-ref", "refs/heads/main",
            base.trimmingCharacters(in: .whitespacesAndNewlines),
            head.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
        let verify = app.buttons["sync-verify-push"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: verify)
        waitForExpectations(timeout: 5)
        verify.click()
        let restart = app.buttons["sync-prepare-new-push"]
        XCTAssertTrue(restart.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: restart)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(try replyLossCommands(fixture).filter { $0 == "P" }.count, 1)
        XCTAssertEqual(try fixture.git(["--git-dir", bare.path, "rev-parse", "HEAD"]), base)
        restart.click()
        app.buttons["重新选择"].firstMatch.click()
        let check = app.buttons["sync-check-target"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: check)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["sync-push-confirm"].exists)
        XCTAssertEqual(try replyLossCommands(fixture).filter { $0 == "P" }.count, 1)
        check.click()
        let push = app.buttons["sync-push-confirm"]
        XCTAssertTrue(push.waitForExistence(timeout: 5))
        push.click()
        XCTAssertTrue(app.staticTexts["推送完成"].waitForExistence(timeout: 10))
        XCTAssertEqual(try replyLossCommands(fixture).filter { $0 == "P" }.count, 2)
        XCTAssertEqual(try fixture.git(["--git-dir", bare.path, "rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-list", "--count", "HEAD"]), "2\n")
    }

    @MainActor private func replyLossApplication(_ fixture: UITestGit) throws -> XCUIApplication {
        let wrapper = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "WeGitTestGit", withExtension: nil))
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-gitExecutable", wrapper.path]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["WEGIT_PUSH_REPLY_LOSS_MARKER"] =
            fixture.root.appending(path: ".git/reply-lost").path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        return app
    }

    @MainActor private func pushUntilReplyIsLost(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.staticTexts["工作区干净"].waitForExistence(timeout: 10))
        app.toolbarSyncAction("toolbar-push").click()
        let check = app.buttons["sync-check-target"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: check)
        waitForExpectations(timeout: 5)
        check.click()
        XCTAssertTrue(app.buttons["sync-push-confirm"].waitForExistence(timeout: 5))
        app.buttons["sync-push-confirm"].click()
        XCTAssertTrue(app.staticTexts["sync-push-unknown"].waitForExistence(timeout: 10))
    }

    private func replyLossCommands(_ fixture: UITestGit) throws -> String {
        try String(contentsOf: fixture.root.appending(path: ".git/reply-lost-commands"), encoding: .utf8)
    }

    @MainActor func testHistoryFirstReadRecoversWhenRefreshCancelsIt() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitHistoryRefreshUI")
        let marker = fixture.root.appendingPathExtension("history-started")
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: marker)
        }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Test"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "History survives refresh"])
        let wrapper = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "WeGitTestGit", withExtension: nil))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: wrapper.path))
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-gitExecutable", wrapper.path]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["WEGIT_HISTORY_DELAY_MARKER"] = marker.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["工作区干净"].waitForExistence(timeout: 10))
        app.typeKey("2", modifierFlags: .command)
        expectation(
            for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: marker.path) },
            evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        app.typeKey("r", modifierFlags: .command)
        let count = app.staticTexts["history-count"]
        expectation(
            for: NSPredicate { element, _ in (element as? XCUIElement)?.value as? String == "1 个提交" },
            evaluatedWith: count)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["History survives refresh"].firstMatch.exists)
        XCTAssertFalse(app.buttons["重试"].exists)
    }

    @MainActor func testCommandPaletteCanSwitchAFilteredLocalBranch() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitBranchSwitcherUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Test"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Base"])
        try fixture.git(["branch", "feature-keyboard"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["工作区干净"].waitForExistence(timeout: 10))
        app.typeKey("p", modifierFlags: [.command, .shift])
        let command = app.textFields["command-search"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.typeText("切换分支")
        command.typeKey(.return, modifierFlags: [])
        let branch = app.textFields["branch-switch-search"]
        XCTAssertTrue(branch.waitForExistence(timeout: 5))
        branch.typeText("feature-keyboard")
        branch.typeKey(.return, modifierFlags: [])
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: branch)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(try fixture.git(["branch", "--show-current"]), "feature-keyboard\n")
    }

    @MainActor func testStatusFilterPreservesStageAllScopeAndDeletedFileOpenIsDisabled() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitStatusFilterUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Test"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        for name in ["modified.txt", "deleted.txt"] {
            try Data("base\n".utf8).write(to: fixture.root.appending(path: name))
        }
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Base"])
        try Data("changed\n".utf8).write(to: fixture.root.appending(path: "modified.txt"))
        try FileManager.default.removeItem(at: fixture.root.appending(path: "deleted.txt"))
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let filter = app.descendants(matching: .any).matching(identifier: "changes-state-filter").firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        filter.click()
        app.menuItems["删除 D"].click()
        XCTAssertTrue(app.staticTexts["deleted.txt"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["modified.txt"].firstMatch.exists)
        app.staticTexts["deleted.txt"].firstMatch.rightClick()
        XCTAssertTrue(app.menuItems["在文本编辑器中打开"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.menuItems["在文本编辑器中打开"].isEnabled)
        XCTAssertTrue(app.menuItems["复制绝对路径"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("p", modifierFlags: [.command, .shift])
        let command = app.textFields["command-search"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.typeText("暂存全部更改")
        command.typeKey(.return, modifierFlags: [])
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: command)
        waitForExpectations(timeout: 5)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: filter)
        waitForExpectations(timeout: 10)
        let staged = try fixture.git(["diff", "--cached", "--name-only"])
        XCTAssertTrue(staged.contains("modified.txt") && staged.contains("deleted.txt"))
    }

    @MainActor func testDraftAndRepositoryPageRestoreAcrossRelaunch() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitPersistenceUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Test"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Base"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let message = app.textFields["commit-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.click()
        message.typeText("Keep this draft after restart")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["history-count"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--uitesting", "--uitesting-keep-preferences"]
        app.launchWeGit()
        XCTAssertTrue(app.staticTexts["history-count"].waitForExistence(timeout: 10))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.value as? String, "Keep this draft after restart")
    }

    @MainActor func testRepositorySearchOpensTheExactCommitAndPaletteSupportsKeyboard() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitSearchUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Test"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Searchable fixture commit"])
        let head = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["工作区干净"].waitForExistence(timeout: 10))
        app.typeKey("2", modifierFlags: .command)
        app.typeKey("f", modifierFlags: [.command, .shift])
        let search = app.textFields["repository-search-query"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Searchable fixture")
        let open = app.buttons["打开结果"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: open)
        waitForExpectations(timeout: 10)
        search.typeKey(.return, modifierFlags: [])
        let historySearch = app.textFields["history-search"]
        XCTAssertTrue(historySearch.waitForExistence(timeout: 5))
        XCTAssertEqual(historySearch.value as? String, head)
        app.typeKey("p", modifierFlags: [.command, .shift])
        let command = app.textFields["command-search"]
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.typeText("更改")
        command.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textFields["commit-message"].waitForExistence(timeout: 5))
    }

    @MainActor func testEncryptedCommitAuthenticationCanBeCancelledAndRetried() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitAuthenticationUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Test"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Base"])
        let key = fixture.root.appending(path: ".git/fixture-signing-key")
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "fixture-only-passphrase", "-f", key.path]
        try keygen.run()
        keygen.waitUntilExit()
        XCTAssertEqual(keygen.terminationStatus, 0)
        try fixture.git(["config", "gpg.format", "ssh"])
        try fixture.git(["config", "user.signingkey", key.path])
        try fixture.git(["config", "commit.gpgsign", "true"])
        try Data("signed change\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "file"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let message = app.textFields["commit-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.click()
        message.typeText("Signed through AskPass")
        app.buttons["commit-button"].click()
        let password = app.secureTextFields["auth-secret"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        app.buttons["auth-cancel"].click()
        let commit = app.buttons["commit-button"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: commit)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(try fixture.git(["rev-list", "--count", "HEAD"]), "1\n")
        XCTAssertEqual(message.value as? String, "Signed through AskPass")
        commit.click()
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.click()
        password.typeText("fixture-only-passphrase")
        app.buttons["auth-submit"].click()
        XCTAssertTrue(app.staticTexts["工作区干净"].waitForExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-list", "--count", "HEAD"]), "2\n")
        XCTAssertTrue(try fixture.git(["cat-file", "-p", "HEAD"]).contains("BEGIN SSH SIGNATURE"))
    }

    @MainActor func testFirstPushAndFastForwardPullUseTheSelectedRemote() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitSyncUI")
        let bare = fixture.root.appendingPathExtension("remote.git")
        let peer = fixture.root.appendingPathExtension("peer")
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: bare)
            try? FileManager.default.removeItem(at: peer)
        }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Test"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Base"])
        try fixture.git(["init", "--bare", "-b", "main", bare.path])
        try fixture.git(["remote", "add", "origin", bare.path])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["工作区干净"].waitForExistence(timeout: 10))
        app.toolbarSyncAction("toolbar-push").click()
        let check = app.buttons["sync-check-target"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: check)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.checkBoxes["sync-set-upstream"].value as? Int, 1)
        check.click()
        XCTAssertTrue(app.buttons["sync-push-confirm"].waitForExistence(timeout: 5))
        app.buttons["sync-push-confirm"].click()
        XCTAssertTrue(app.staticTexts["推送完成"].waitForExistence(timeout: 10))
        XCTAssertEqual(
            try fixture.git(["--git-dir", bare.path, "rev-parse", "HEAD"]),
            try fixture.git(["rev-parse", "HEAD"]))
        XCTAssertEqual(try fixture.git(["config", "branch.main.remote"]), "origin\n")
        app.buttons["sync-close"].click()
        try fixture.git(["clone", bare.path, peer.path])
        try Data("pulled change\n".utf8).write(to: peer.appending(path: "file"))
        try fixture.git(["-C", peer.path, "add", "."])
        try fixture.git([
            "-C", peer.path, "-c", "user.name=UI Test", "-c", "user.email=ui@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-m", "Remote change",
        ])
        try fixture.git(["-C", peer.path, "push", "origin", "main"])
        // Exercise the application's action without a desktop-wide hotkey handler
        // intercepting this remote workflow (keyboard paths have separate coverage).
        app.toolbarSyncAction("toolbar-pull").click()
        let pull = app.buttons["sync-pull-confirm"]
        XCTAssertTrue(pull.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: pull)
        waitForExpectations(timeout: 5)
        pull.click()
        XCTAssertTrue(app.staticTexts["拉取完成"].waitForExistence(timeout: 10))
        XCTAssertEqual(
            try String(contentsOf: fixture.root.appending(path: "file"), encoding: .utf8), "pulled change\n")
    }

    @MainActor func testCommitAndPushFailureRetriesWithoutAnotherCommit() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitCommitPushUI")
        let bare = fixture.root.appendingPathExtension("remote.git")
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: bare)
        }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Test"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Base"])
        try fixture.git(["init", "--bare", "-b", "main", bare.path])
        try fixture.git(["remote", "add", "origin", bare.path])
        try fixture.git(["push", "--set-upstream", "origin", "main"])
        let hook = bare.appending(path: "hooks/pre-receive")
        try Data("#!/bin/sh\necho 'Fixture rejects first push' >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        try Data("local change\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "file"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let message = app.textFields["commit-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.click()
        message.typeText("Commit once and retry push")
        app.buttons["commit-push-button"].click()
        let commit = app.buttons["sync-commit-push-confirm"]
        XCTAssertTrue(commit.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: commit)
        waitForExpectations(timeout: 5)
        commit.click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "sync-error").firstMatch.waitForExistence(
                timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "sync-commit-completed").firstMatch.exists)
        let head = try fixture.git(["rev-parse", "HEAD"])
        XCTAssertEqual(try fixture.git(["rev-list", "--count", "HEAD"]), "2\n")
        XCTAssertNotEqual(head, try fixture.git(["--git-dir", bare.path, "rev-parse", "HEAD"]))
        try FileManager.default.removeItem(at: hook)
        let retry = app.buttons["sync-check-target"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: retry)
        waitForExpectations(timeout: 5)
        retry.click()
        XCTAssertTrue(app.buttons["sync-push-confirm"].waitForExistence(timeout: 5))
        app.buttons["sync-push-confirm"].click()
        XCTAssertTrue(app.staticTexts["推送完成"].waitForExistence(timeout: 10))
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["--git-dir", bare.path, "rev-parse", "HEAD"]), head)
        XCTAssertEqual(try fixture.git(["rev-list", "--count", "HEAD"]), "2\n")
    }

    @MainActor func testBranchRenameDeleteAndTrackingCreation() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitBranchesUI")
        let bare = fixture.root.appendingPathExtension("remote.git")
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: bare)
        }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Test"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Base"])
        try fixture.git(["branch", "merged"])
        try fixture.git(["switch", "-c", "feature"])
        try Data("feature\n".utf8).write(to: fixture.root.appending(path: "file"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Feature"])
        try fixture.git(["switch", "main"])
        try fixture.git(["init", "--bare", "-b", "main", bare.path])
        try fixture.git(["remote", "add", "origin", bare.path])
        try fixture.git(["push", "origin", "main"])
        try fixture.git(["fetch", "origin"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["工作区干净"].waitForExistence(timeout: 10))
        app.typeKey("3", modifierFlags: .command)
        func actions(_ ref: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "branch-actions:" + ref).firstMatch
        }
        func row(_ ref: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "branch-row:" + ref).firstMatch
        }
        XCTAssertTrue(actions("refs/heads/merged").waitForExistence(timeout: 5))
        actions("refs/heads/merged").click()
        app.menuItems["重命名…"].click()
        let field = app.textFields["branch-edit-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("renamed")
        app.buttons["branch-edit-save"].click()
        XCTAssertTrue(row("refs/heads/renamed").waitForExistence(timeout: 5))
        actions("refs/heads/renamed").click()
        app.menuItems["删除本地分支…"].click()
        XCTAssertTrue(app.buttons["branch-delete-confirm"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["branch-delete-confirm"].isEnabled)
        app.buttons["branch-delete-confirm"].click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row("refs/heads/renamed"))
        waitForExpectations(timeout: 5)
        actions("refs/heads/feature").click()
        app.menuItems["删除本地分支…"].click()
        XCTAssertTrue(app.checkBoxes["branch-delete-unmerged"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["branch-delete-confirm"].isEnabled)
        app.checkBoxes["branch-delete-unmerged"].click()
        app.buttons["branch-delete-confirm"].click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row("refs/heads/feature"))
        waitForExpectations(timeout: 5)
        actions("refs/remotes/origin/main").click()
        app.menuItems["创建本地跟踪分支…"].click()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("tracked")
        app.buttons["branch-edit-save"].click()
        XCTAssertTrue(row("refs/heads/tracked").waitForExistence(timeout: 5))
    }

    @MainActor func testHistoryPaginationParentComparisonAndStaleReferences() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitHistoryUI")
        defer { fixture.remove() }
        try fixture.git(["init", "-b", "main"])
        try fixture.git(["config", "user.name", "UI Test"])
        try fixture.git(["config", "user.email", "ui@example.invalid"])
        try fixture.git(["config", "commit.gpgsign", "false"])
        try fixture.git(["config", "core.hooksPath", fixture.root.appending(path: "no-hooks").path])
        var stream = "blob\nmark :1\ndata 5\nhello\n"
        for index in 1...240 {
            let message = "History \(index)"
            stream +=
                "commit refs/heads/main\nmark :\(index + 1)\nauthor A <a@example.invalid> 1700000000 +0000\ncommitter C <c@example.invalid> 1700000000 +0000\ndata \(message.utf8.count)\n\(message)\n"
            if index > 1 { stream += "from :\(index)\n" }
            stream += "M 100644 :1 file.txt\n\n"
        }
        try fixture.git(["fast-import", "--quiet"], input: stream + "done\n")
        try fixture.git(["reset", "--hard", "HEAD"])
        try fixture.git(["switch", "-c", "feature"])
        try Data("feature\n".utf8).write(to: fixture.root.appending(path: "feature.txt"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Feature change"])
        try fixture.git(["switch", "main"])
        try Data("main\n".utf8).write(to: fixture.root.appending(path: "main.txt"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Main change"])
        try fixture.git(["merge", "feature", "-m", "Merge feature"])
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = fixture.root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["工作区干净"].waitForExistence(timeout: 10))
        app.typeKey("2", modifierFlags: .command)
        let count = app.staticTexts["history-count"]
        func expectCount(_ expected: Int) {
            let predicate = NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return ((element.value as? String) ?? element.label).filter(\.isNumber) == String(expected)
            }
            expectation(for: predicate, evaluatedWith: count)
            waitForExpectations(timeout: 10)
        }
        expectCount(200)
        app.buttons["history-load-more"].click()
        expectCount(243)
        app.staticTexts["Merge feature"].firstMatch.click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "commit-file:feature.txt").firstMatch
                .waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "history-parent").firstMatch.click()
        app.menuItems.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR title BEGINSWITH %@ OR value BEGINSWITH %@", "父提交 2", "父提交 2",
                "父提交 2")
        ).firstMatch.click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "commit-file:main.txt").firstMatch
                .waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["暂存此块"].exists)
        try fixture.git(["commit", "--allow-empty", "-m", "Reference changed"])
        XCTAssertTrue(app.buttons["读取最新历史"].waitForExistence(timeout: 8))
        expectCount(243)
        app.buttons["读取最新历史"].click()
        expectCount(200)
        XCTAssertTrue(app.staticTexts["Reference changed"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testUntrackedTrashConfirmationCanBeCancelled() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appending(path: "WeGitTrashUI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            _ = try UITestGit.run(arguments, in: root)
        }
        try git(["init", "-b", "main"])
        let tracked = root.appending(path: "tracked.txt")
        try Data("base\n".utf8).write(to: tracked)
        try git(["add", "tracked.txt"])
        try git([
            "-c", "user.name=UI Test", "-c", "user.email=ui@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", "Trash fixture",
        ])
        try Data("working change\n".utf8).write(to: tracked)
        let candidate = root.appending(path: "delete-candidate.txt")
        try Data("keep on cancel\n".utf8).write(to: candidate)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let file = app.staticTexts["delete-candidate.txt"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.rightClick()
        XCTAssertTrue(app.menuItems["移到废纸篓…"].waitForExistence(timeout: 3))
        app.menuItems["移到废纸篓…"].click()
        XCTAssertTrue(app.buttons["移到废纸篓"].waitForExistence(timeout: 5))
        app.buttons["取消"].firstMatch.click()
        XCTAssertEqual(try String(contentsOf: candidate, encoding: .utf8), "keep on cancel\n")
        XCTAssertTrue(file.exists)
        app.staticTexts["tracked.txt"].firstMatch.rightClick()
        XCTAssertFalse(app.menuItems["移到废纸篓…"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor func testReopeningAReplacedRepositoryCreatesANewSession() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitIdentityUI-\(UUID().uuidString)")
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
        }
        func git(_ arguments: [String], directory: URL? = nil) throws {
            _ = try UITestGit.run(arguments, in: directory ?? root)
        }
        try git(["init", "-b", "main"], directory: root)
        try Data("original\n".utf8).write(to: root.appending(path: "original.swift"))
        try git(["add", "."], directory: root)
        try git(
            [
                "-c", "user.name=UI Test", "-c", "user.email=ui@example.invalid", "-c",
                "commit.gpgsign=false", "commit", "-m", "Identity fixture",
            ], directory: root)
        try Data("uncommitted original\n".utf8).write(to: root.appending(path: "original.swift"))
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["original.swift"].firstMatch.waitForExistence(timeout: 10))
        guard rename(root.path, moved.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try git(["clone", moved.path, root.path], directory: moved.deletingLastPathComponent())
        try Data("replacement\n".utf8).write(to: root.appending(path: "replacement.swift"))
        app.typeKey("k", modifierFlags: .command)
        let reopen = app.buttons.matching(
            NSPredicate(format: "identifier == %@", "repository:" + root.resolvingSymlinksInPath().path)
        ).firstMatch
        XCTAssertTrue(reopen.waitForExistence(timeout: 5))
        reopen.click()
        XCTAssertTrue(app.staticTexts["replacement.swift"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["original.swift"].firstMatch.exists)
        XCTAssertTrue(app.checkBoxes["stage:untracked:replacement.swift"].isEnabled)
    }

    @MainActor func testWelcomeAndCloneForm() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["open-repository"].waitForExistence(timeout: 10))
        app.buttons["克隆仓库…"].firstMatch.click()
        XCTAssertTrue(app.textFields["clone-url"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["clone-start"].isEnabled)
        app.textFields["clone-url"].click()
        app.textFields["clone-url"].typeText("https://example.invalid/team/repository.git")
        XCTAssertEqual(app.textFields["clone-folder"].value as? String, "repository")
        app.buttons["clone-cancel"].click()
        XCTAssertTrue(app.buttons["open-repository"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Welcome after Clone cancellation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let fixture = try UITestGit(prefix: "WeGitSmokeGit")
        defer { fixture.remove() }
        let version = try fixture.git(["--version"])
        XCTAssertTrue(version.hasPrefix("git version "))
        let helper = Process()
        helper.executableURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "WeGitTestGit", withExtension: nil))
        helper.arguments = ["--version"]
        helper.environment = [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "LC_ALL": "C",
        ]
        let output = Pipe()
        helper.standardOutput = output
        helper.standardError = output
        try helper.run()
        let actual = output.fileHandleForReading.readDataToEndOfFile()
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0, String(decoding: actual, as: UTF8.self))
        XCTAssertEqual(String(decoding: actual, as: UTF8.self), version)
    }
    @MainActor func testStageCommitAndHistory() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appending(path: "WeGitUITest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws -> String {
            try UITestGit.run(arguments, in: root)
        }
        _ = try git(["init", "-b", "main"])
        _ = try git(["config", "user.name", "UI Test"])
        _ = try git(["config", "user.email", "ui@example.invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["config", "core.hooksPath", root.appending(path: "no-hooks").path])
        try Data("let message = \"Hello WeGit\"\n".utf8).write(to: root.appending(path: "sample.swift"))
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let stage = app.checkBoxes["stage:untracked:sample.swift"]
        XCTAssertTrue(stage.waitForExistence(timeout: 10), app.windows.debugDescription)
        app.staticTexts["sample.swift"].firstMatch.click()
        stage.click()
        let unstage = app.checkBoxes["stage:staged:sample.swift"]
        XCTAssertTrue(unstage.waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes["diff-ignore-whitespace"].waitForExistence(timeout: 5))
        let message = app.descendants(matching: .any).matching(identifier: "commit-message").firstMatch
        message.click()
        message.typeText("First UI commit")
        XCTAssertTrue(app.buttons["commit-button"].isEnabled)
        app.buttons["commit-button"].click()
        XCTAssertTrue(app.staticTexts["工作区干净"].waitForExistence(timeout: 10))
        XCTAssertEqual(
            try git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines),
            "First UI commit")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["First UI commit"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor func testCloneRejectsExistingDirectoryThenRetriesSuccessfully() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appending(path: "WeGitCloneUI-\(UUID().uuidString)")
        let source = root.appending(path: "source")
        let existing = root.appending(path: "existing")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep this file".utf8).write(to: existing.appending(path: "user.txt"))
        func git(_ args: [String], in directory: URL) throws -> String {
            try UITestGit.run(args, in: directory)
        }
        _ = try git(["init", "-b", "main"], in: source)
        try Data("cloned through the actual UI\n".utf8).write(to: source.appending(path: "hello.txt"))
        _ = try git(["add", "hello.txt"], in: source)
        _ = try git(
            [
                "-c", "user.name=UI Test", "-c", "user.email=ui@example.invalid", "-c",
                "commit.gpgsign=false", "commit", "-m", "Clone fixture",
            ], in: source)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["open-repository"].waitForExistence(timeout: 10))
        app.buttons["克隆仓库…"].firstMatch.click()
        func fill(_ identifier: String, _ value: String) {
            let field = app.textFields[identifier]
            let before = field.frame
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeText(value)
            let complete = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", value), object: field)
            let result = XCTWaiter.wait(for: [complete], timeout: 2)
            if result != .completed {
                let evidence = XCTAttachment(
                    string: "Before: \(before); after: \(field.frame)\n" + app.debugDescription)
                evidence.name = "Long clone input state"
                evidence.lifetime = .keepAlways
                add(evidence)
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Long clone input layout"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            XCTAssertEqual(field.value as? String, value, "输入字段 \(identifier) 未保留完整内容")
        }
        fill("clone-url", source.path)
        fill("clone-parent", root.path)
        fill("clone-folder", "existing")
        app.buttons["clone-start"].click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "clone-error").firstMatch.waitForExistence(
                timeout: 5))
        let cloneError = app.descendants(matching: .any).matching(identifier: "clone-error").firstMatch
        XCTAssertTrue(((cloneError.value as? String) ?? cloneError.label).contains("目标已存在"))
        XCTAssertFalse(app.buttons["clone-cleanup"].exists)
        XCTAssertEqual(
            try String(contentsOf: existing.appending(path: "user.txt"), encoding: .utf8), "keep this file")
        fill("clone-folder", "checkout")
        app.buttons["clone-start"].click()
        XCTAssertTrue(app.staticTexts["工作区干净"].waitForExistence(timeout: 15))
        let checkout = root.appending(path: "checkout")
        XCTAssertEqual(
            try git(["rev-parse", "HEAD"], in: checkout), try git(["rev-parse", "HEAD"], in: source))
        XCTAssertEqual(
            try String(contentsOf: checkout.appending(path: "hello.txt"), encoding: .utf8),
            "cloned through the actual UI\n")
    }
    @MainActor func testDiffReadingOptionsAndFilterEmptyState() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appending(path: "WeGitDiffUI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            _ = try UITestGit.run(arguments, in: root)
        }
        try git(["init", "-b", "main"])
        let file = root.appending(path: "sample.swift")
        try Data((1...40).map { "let value\($0) = \($0)\n" }.joined().utf8).write(to: file)
        try git(["add", "sample.swift"])
        try git([
            "-c", "user.name=UI Test", "-c", "user.email=ui@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", "Diff fixture",
        ])
        let modified = (1...40).map {
            [5, 25].contains($0) ? "let value\($0) = 99\n" : "let value\($0) = \($0)\n"
        }.joined()
        try Data(modified.utf8).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(
            app.staticTexts["sample.swift"].firstMatch.waitForExistence(timeout: 10),
            app.windows.debugDescription)
        app.staticTexts["sample.swift"].firstMatch.click()
        XCTAssertTrue(app.buttons.matching(identifier: "暂存此块").firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "暂存此块").count, 2)
        let wordHighlight = app.checkBoxes["diff-word-highlight"]
        XCTAssertTrue(wordHighlight.exists)
        wordHighlight.click()
        XCTAssertTrue(
            (wordHighlight.value as? NSNumber)?.boolValue == true || (wordHighlight.value as? String) == "1")
        XCTAssertTrue(app.buttons.matching(identifier: "暂存此块").firstMatch.exists)
        app.radioButtons["分栏"].click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "split-diff-row").firstMatch
                .waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "split-diff-row").count, 14)
        let headers = app.descendants(matching: .any).matching(identifier: "diff-column-headers").firstMatch
        XCTAssertTrue(headers.staticTexts["原始内容"].exists)
        XCTAssertTrue(headers.staticTexts["修改后"].exists)
        app.radioButtons["统一"].click()
        XCTAssertTrue(app.buttons.matching(identifier: "暂存此块").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "split-diff-row").firstMatch.exists)
        let expand = app.buttons["diff-context-expand-0"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        let rows = app.descendants(matching: .any).matching(identifier: "unified-diff-row")
        let collapsedCount = rows.count
        expand.click()
        expectation(for: NSPredicate(format: "count == %d", collapsedCount + 1), evaluatedWith: rows)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.buttons.matching(identifier: "暂存此块").count, 2)
        app.buttons["diff-context-collapse-0"].click()
        XCTAssertTrue(app.buttons["diff-context-expand-0"].waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, collapsedCount)
        app.descendants(matching: .any).matching(identifier: "diff-context").firstMatch.click()
        app.menuItems["20 行"].click()
        XCTAssertTrue(app.buttons.matching(identifier: "暂存此块").firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "暂存此块").count, 1)
        app.checkBoxes["diff-ignore-whitespace"].click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "diff-readonly-notice").firstMatch
                .waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(identifier: "暂存此块").firstMatch.exists)
        app.checkBoxes["diff-ignore-whitespace"].click()
        XCTAssertTrue(app.buttons["丢弃此块…"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["丢弃此块…"].firstMatch.click()
        app.buttons["取消"].firstMatch.click()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), modified)
        let filter = app.textFields["changes-filter"]
        filter.click()
        filter.typeText("no-such-file")
        XCTAssertTrue(app.staticTexts["没有匹配文件"].waitForExistence(timeout: 5))
        app.buttons["清除筛选"].click()
        XCTAssertTrue(app.staticTexts["sample.swift"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testDiskBackedDiffPagesAndLayoutSwitch() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitDiskDiffUI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            _ = try UITestGit.run(arguments, in: root)
        }
        try git(["init", "-b", "main"])
        let file = root.appending(path: "disk.swift")
        let padding = String(repeating: "x", count: 240) + "\t中文🙂"
        func text(_ prefix: String) -> String {
            (1...20_000).map { "let \($0 <= 4 ? "old" : prefix)\($0) = \"\(padding)\"\r\n" }.joined()
        }
        try Data(text("old").utf8).write(to: file)
        try git(["add", "disk.swift"])
        try git([
            "-c", "user.name=UI Test", "-c", "user.email=ui@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", "Disk diff fixture",
        ])
        try Data(text("new").utf8).write(to: file)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["disk.swift"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["disk.swift"].firstMatch.click()
        XCTAssertTrue(app.buttons["diff-load-large"].waitForExistence(timeout: 5))
        app.buttons["diff-load-large"].click()
        let progress = app.staticTexts["disk-diff-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 20))
        func expectPage(_ number: Int, _ first: Int, _ last: Int, total: Int) {
            let expected = "\(number)\(first)\(last)\(total)"
            let predicate = NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                let text = (element.value as? String) ?? element.label
                return text.filter(\.isNumber) == expected
            }
            expectation(for: predicate, evaluatedWith: progress)
            waitForExpectations(timeout: 10)
        }
        expectPage(1, 1, 399, total: 39_995)
        UITestGit.preservingClipboard { clipboard in
            let code = app.textViews.containing(NSPredicate(format: "value CONTAINS %@", "old2 ="))
                .firstMatch
            XCTAssertTrue(code.exists)
            code.rightClick()
            app.menuItems["复制完整行"].click()
            XCTAssertEqual(
                Data((clipboard.string(forType: .string) ?? "").utf8),
                Data("let old2 = \"\(padding)\"\r\n".utf8))
        }
        let expand = app.buttons["diff-context-expand-0"]
        XCTAssertTrue(expand.exists)
        expand.click()
        let contextLine = app.descendants(matching: .any).matching(identifier: "disk-context-line:-2")
            .firstMatch
        XCTAssertTrue(contextLine.waitForExistence(timeout: 5))
        app.buttons["diff-context-collapse-0"].click()
        XCTAssertFalse(contextLine.exists)
        XCTAssertFalse(app.buttons["disk-diff-previous"].isEnabled)
        XCTAssertFalse(app.buttons["暂存此块"].exists)
        app.buttons["disk-diff-next"].click()
        expectPage(2, 400, 798, total: 39_995)
        XCTAssertFalse(app.buttons["diff-context-expand-0"].exists)
        app.buttons["disk-diff-previous"].click()
        expectPage(1, 1, 399, total: 39_995)
        XCTAssertTrue(app.buttons["diff-context-expand-0"].exists)
        app.radioButtons["分栏"].click()
        expectPage(1, 1, 399, total: 19_999)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "diff-column-headers").firstMatch.exists)
        app.checkBoxes["diff-word-highlight"].click()
        XCTAssertTrue(app.buttons["disk-diff-next"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testLargeDiffSummaryPagingAndSelectionReset() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitLargeDiffUI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            _ = try UITestGit.run(arguments, in: root)
        }
        try git(["init", "-b", "main"])
        let large = root.appending(path: "large.swift")
        let small = root.appending(path: "small.swift")
        try Data((1...1_200).map { "let old\($0) = \($0)\n" }.joined().utf8).write(to: large)
        try Data("let small = 1\n".utf8).write(to: small)
        try git(["add", "."])
        try git([
            "-c", "user.name=UI Test", "-c", "user.email=ui@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "-m", "Large diff fixture",
        ])
        try Data((1...1_200).map { "let new\($0) = \($0)\n" }.joined().utf8).write(to: large)
        try Data("let small = 2\n".utf8).write(to: small)
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["large.swift"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["large.swift"].firstMatch.click()
        XCTAssertTrue(app.buttons["diff-load-large"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["暂存此块"].exists)
        app.buttons["diff-load-large"].click()
        XCTAssertTrue(app.buttons["diff-load-more"].waitForExistence(timeout: 10))
        let progress = app.staticTexts["diff-page-progress"]
        func waitForProgress(_ shown: Int, total: Int) {
            let predicate = NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                let text = (element.value as? String) ?? element.label
                return text.filter(\.isNumber) == "\(shown)\(total)"
            }
            expectation(for: predicate, evaluatedWith: progress)
            waitForExpectations(timeout: 5)
        }
        waitForProgress(399, total: 2_400)
        XCTAssertFalse(app.buttons["暂存此块"].exists)
        app.buttons["diff-load-more"].click()
        waitForProgress(799, total: 2_400)
        app.radioButtons["分栏"].click()
        waitForProgress(399, total: 1_200)
        let headers = app.descendants(matching: .any).matching(identifier: "diff-column-headers").firstMatch
        XCTAssertTrue(headers.staticTexts["原始内容"].exists)
        XCTAssertTrue(headers.staticTexts["修改后"].exists)
        app.staticTexts["small.swift"].firstMatch.click()
        XCTAssertTrue(app.buttons["暂存此块"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["diff-load-more"].exists)
        XCTAssertFalse(app.buttons["diff-load-large"].exists)
        app.staticTexts["large.swift"].firstMatch.click()
        XCTAssertTrue(app.buttons["diff-load-large"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
