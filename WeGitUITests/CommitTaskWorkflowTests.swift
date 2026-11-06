import XCTest

final class CommitTaskWorkflowTests: XCTestCase {
    @MainActor func testOrderedQueueReopensAndSkipsOnlyTheConflictingItem() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitQueueBatchUI")
        defer { f.remove() }
        try initialize(f)
        try write(f, "file.txt", "base\r\nlast")
        _ = try commit(f, "Base")
        try f.git(["switch", "-c", "source"])
        try write(f, "one.txt", "one\r\nlast")
        let one = try commit(f, "First queued change")
        try write(f, "file.txt", "source\r\nlast")
        let conflict = try commit(f, "Second queued conflict")
        try write(f, "three.txt", "three\n")
        let three = try commit(f, "Third queued change")
        try f.git(["switch", "main"])
        try write(f, "file.txt", "target\r\nlast")
        let original = try commit(f, "Target divergence")
        let app = launch(f.root)
        defer { app.terminate() }
        let message = "Queue draft 🧩\nKeep the current task"
        fill(app.textFields["commit-message"], message)
        route(app, "提交历史")
        selectCommits(app, [one, conflict, three])
        operation(app, "Cherry-pick…")
        enabled(app.buttons["commit-queue-preview"])
        capture(app, "Ordered queue contains all three fixed sources")
        app.buttons["commit-queue-preview"].click()
        enabled(app.buttons["commit-queue-start"])
        app.buttons["commit-queue-start"].click()
        progress(app, "commit-queue-progress", "已处理 1 / 3 个提交")
        XCTAssertEqual(try bytes(f, "one.txt"), Data("one\r\nlast".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appending(path: "three.txt").path))
        capture(app, "Queue stops at the second item without losing its first commit")
        app.buttons["commit-queue-close"].click()
        app.terminate()
        app.launchArguments.append("--uitesting-keep-preferences")
        app.launchWeGit()
        enabled(app.buttons["commit-queue-recovery"])
        app.buttons["commit-queue-recovery"].click()
        enabled(app.buttons["commit-queue-skip"])
        app.buttons["commit-queue-skip"].click()
        progress(app, "commit-queue-progress", "已处理 3 / 3 个提交")
        XCTAssertEqual(try bytes(f, "file.txt"), Data("target\r\nlast".utf8))
        XCTAssertEqual(try bytes(f, "three.txt"), Data("three\n".utf8))
        XCTAssertEqual(try f.git(["rev-list", "--count", original + "..HEAD"]), "2\n")
        XCTAssertEqual(try f.git(["status", "--porcelain"]), "")
        app.buttons["commit-queue-finish"].click()
        gone(app.buttons["commit-queue-finish"])
        route(app, "更改")
        XCTAssertEqual(app.textFields["commit-message"].value as? String, message)
        capture(app, "Reopened queue preserves the draft and completed and skipped outcomes")
    }

    @MainActor func testMergeQueueRequiresAndUsesTheSelectedMainlineParent() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitMainlineBatchUI")
        defer { f.remove() }
        try initialize(f)
        try write(f, "base.txt", "base\n")
        _ = try commit(f, "Base")
        try f.git(["switch", "-c", "feature"])
        try write(f, "feature.txt", "feature\r\nlast")
        _ = try commit(f, "Feature change")
        try f.git(["switch", "main"])
        try write(f, "main.txt", "main\n")
        let parent = try commit(f, "Main change")
        try f.git(["merge", "--no-ff", "feature", "-m", "Merge with two parents"])
        let merge = try oid(f)
        try f.git(["switch", "-c", "target", parent])
        let app = launch(f.root)
        defer { app.terminate() }
        route(app, "提交历史")
        selectCommits(app, [merge])
        operation(app, "Cherry-pick…")
        XCTAssertTrue(app.buttons["commit-queue-preview"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["commit-queue-preview"].isEnabled)
        let mainline = app.popUpButtons["commit-queue-mainline:" + merge]
        XCTAssertTrue(mainline.waitForExistence(timeout: 5))
        mainline.click()
        app.menuItems["1 · " + parent.prefix(12)].click()
        enabled(app.buttons["commit-queue-preview"])
        app.buttons["commit-queue-preview"].click()
        enabled(app.buttons["commit-queue-start"])
        capture(app, "The merge queue previews the chosen first-parent difference")
        app.buttons["commit-queue-start"].click()
        progress(app, "commit-queue-progress", "已处理 1 / 1 个提交")
        XCTAssertEqual(try bytes(f, "feature.txt"), Data("feature\r\nlast".utf8))
        XCTAssertEqual(try bytes(f, "main.txt"), Data("main\n".utf8))
        XCTAssertEqual(try f.git(["rev-parse", "HEAD^"]), parent + "\n")
        XCTAssertEqual(try f.git(["status", "--porcelain"]), "")
    }

    @MainActor func testSaveTaskSwitchAndStashBranchRestoreExactLayersAndDraft() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitTaskBatchUI")
        defer { f.remove() }
        try initialize(f)
        try write(f, "a.txt", "base a\r\nlast")
        try write(f, "b.txt", "base b\r\nlast")
        _ = try commit(f, "Base")
        try f.git(["branch", "feature"])
        try write(f, "a.txt", "staged a\r\nlast")
        try f.git(["add", "a.txt"])
        try write(f, "a.txt", "working a\r\nlast")
        try write(f, "b.txt", "working b\r\nlast")
        try write(f, "extra.txt", "untracked\r\nlast")
        let index = try rawIndex(f)
        let app = launch(f.root)
        defer { app.terminate() }
        let draft = "Task draft 🧩\nKeep staging and working files separate"
        fill(app.textFields["commit-message"], draft)
        toolbarAction(app, "task-save-and-switch")
        let target = app.popUpButtons["task-switch-target"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.click()
        app.menuItems["feature"].click()
        fill(app.textFields["task-switch-message"], "Private task")
        app.checkBoxes["task-switch-untracked"].click()
        app.buttons["task-switch-preview"].click()
        enabled(app.buttons["task-switch-execute"])
        capture(app, "Task switch explicitly includes untracked files")
        app.buttons["task-switch-execute"].click()
        gone(app.buttons["task-switch-execute"])
        XCTAssertEqual(try f.git(["branch", "--show-current"]), "feature\n")
        XCTAssertEqual(try f.git(["status", "--porcelain"]), "")
        XCTAssertEqual(app.textFields["commit-message"].value as? String, draft)
        let stash = try f.git(["rev-parse", "refs/stash"])
        route(app, "储藏")
        let entry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'stash-record:'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        entry.click()
        enabled(app.buttons["stash-create-branch"])
        app.buttons["stash-create-branch"].click()
        fill(app.textFields["stash-branch-name"], "resumed")
        app.buttons["stash-branch-preview"].click()
        enabled(app.buttons["stash-branch-execute"])
        app.buttons["stash-branch-execute"].click()
        gone(app.buttons["stash-branch-execute"])
        XCTAssertEqual(try f.git(["branch", "--show-current"]), "resumed\n")
        XCTAssertEqual(try bytes(f, "a.txt"), Data("working a\r\nlast".utf8))
        XCTAssertEqual(try bytes(f, "b.txt"), Data("working b\r\nlast".utf8))
        XCTAssertEqual(try bytes(f, "extra.txt"), Data("untracked\r\nlast".utf8))
        XCTAssertEqual(try rawIndex(f), index)
        XCTAssertEqual(try f.git(["rev-parse", "refs/stash"]), stash)
        route(app, "更改")
        XCTAssertEqual(app.textFields["commit-message"].value as? String, draft)
        capture(app, "Stash branch keeps its entry and restores original raw layers")
    }

    @MainActor func testTemplateHistorySSHSignatureWorktreeOverrideAndHookFailureKeepDrafts() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitMetadataBatchUI")
        defer { f.remove() }
        try initialize(f)
        try write(f, "file.txt", "base\r\nlast")
        _ = try commit(f, "Unsigned base")
        let files = f.root.appending(path: ".git/fixture")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false)
        let key = files.appending(path: "key with spaces")
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        generator.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "ui@example.invalid", "-f", key.path]
        let output = Pipe()
        generator.standardOutput = output
        generator.standardError = output
        try generator.run()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        let publicKey = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
        let signers = files.appending(path: "allowed-signers")
        try Data(("ui@example.invalid " + publicKey).utf8).write(to: signers)
        let template = files.appending(path: "template")
        let templateText = "模板标题 🧩\n\n模板正文\n"
        try Data(templateText.utf8).write(to: template)
        for (name, value) in [
            ("gpg.format", "ssh"), ("user.signingkey", key.path),
            ("gpg.ssh.allowedSignersFile", signers.path), ("commit.gpgsign", "true"),
            ("tag.gpgsign", "true"), ("commit.template", template.path),
            ("extensions.worktreeConfig", "true"),
        ] { try f.git(["config", "--local", name, value]) }
        try write(f, "file.txt", "signed\r\nlast")
        try f.git(["add", "file.txt"])
        let app = launch(f.root)
        defer { app.terminate() }
        let draft = "原草稿 🧩\nKeep me"
        fill(app.textFields["commit-message"], draft)
        messageSource(app, "使用模板…")
        XCTAssertTrue(app.buttons["message-source-use"].waitForExistence(timeout: 10))
        capture(app, "Template preview does not replace the current draft")
        app.typeKey(.escape, modifierFlags: [])
        gone(app.buttons["message-source-use"])
        XCTAssertEqual(app.textFields["commit-message"].value as? String, draft)
        messageSource(app, "使用模板…")
        enabled(app.buttons["message-source-use"])
        app.buttons["message-source-use"].click()
        gone(app.buttons["message-source-use"])
        XCTAssertEqual(app.textFields["commit-message"].value as? String, templateText)
        app.buttons["message-source-undo"].click()
        XCTAssertEqual(app.textFields["commit-message"].value as? String, draft)
        let submitted = "SSH 消息\n\n完整正文 📬"
        fill(app.textFields["commit-message"], submitted)
        enabled(app.buttons["commit-button"])
        app.buttons["commit-button"].click()
        waitForText(app.textFields["commit-message"], "")
        let signed = try oid(f)
        try f.git(["tag", "-s", "-m", "Signed tag", "ui-signed"])
        let current = "新的草稿 🧩\nHistory must preserve it"
        fill(app.textFields["commit-message"], current)
        messageSource(app, "消息历史…")
        enabled(app.buttons["message-history-clear"])
        app.buttons["message-history-clear"].click()
        enabled(app.buttons["message-history-undo-clear"])
        app.buttons["message-history-undo-clear"].click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "message-history:0").firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        gone(app.buttons["message-source-use"])
        XCTAssertEqual(app.textFields["commit-message"].value as? String, current)
        route(app, "提交历史")
        selectCommits(app, [signed])
        enabled(app.buttons["commit-signature"])
        app.buttons["commit-signature"].click()
        progress(app, "signature-state", "签名验证通过")
        capture(app, "SSH commit signature reports verification separately from unsigned content")
        app.buttons["signature-close"].click()
        route(app, "标签")
        let tag = app.descendants(matching: .any).matching(identifier: "tag-row:ui-signed").firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 15))
        tag.click()
        enabled(app.buttons["tag-signature"])
        app.buttons["tag-signature"].click()
        progress(app, "signature-state", "签名验证通过")
        app.buttons["signature-close"].click()
        native(app, menu: "app", command: "settings")
        let gitTab = app.buttons["Git"].firstMatch
        if gitTab.waitForExistence(timeout: 3) { gitTab.click() } else { app.radioButtons["Git"].click() }
        let scope = app.popUpButtons["git-setting-scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.click()
        app.menuItems["当前工作区"].click()
        enabled(app.buttons["edit-setting:commit.gpgsign"])
        app.buttons["edit-setting:commit.gpgsign"].click()
        let value = app.popUpButtons["git-setting-value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        value.click()
        app.menuItems["关闭"].click()
        app.buttons["git-setting-save"].click()
        gone(app.buttons["git-setting-save"])
        XCTAssertEqual(try f.git(["config", "--worktree", "--get", "commit.gpgsign"]), "false\n")
        XCTAssertEqual(try f.git(["config", "--local", "--get", "commit.gpgsign"]), "true\n")
        app.windows["com_apple_SwiftUI_Settings_window"].buttons[XCUIIdentifierCloseWindow].click()
        route(app, "更改")
        XCTAssertEqual(app.textFields["commit-message"].value as? String, current)
        let hooks = f.root.appending(path: ".git/no-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
        let hook = hooks.appending(path: "pre-commit")
        try Data("#!/bin/sh\nprintf fixture-hook-failure >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        try write(f, "file.txt", "failed commit\r\nlast")
        try f.git(["add", "file.txt"])
        let staged = try rawIndex(f)
        enabled(app.buttons["commit-button"])
        app.buttons["commit-button"].click()
        let failure = app.descendants(matching: .any).matching(identifier: "operation-feedback").firstMatch
        let failed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label BEGINSWITH %@", "失败: "), object: failure)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 20), .completed)
        enabled(app.buttons["commit-button"])
        XCTAssertEqual(try oid(f), signed)
        XCTAssertEqual(try rawIndex(f), staged)
        XCTAssertEqual(app.textFields["commit-message"].value as? String, current)
        capture(app, "A failing hook preserves the signed commit, staged bytes and newer draft")
    }

    @MainActor func testMailOrderExportAndConflictContinueAcrossRelaunch() throws {
        continueAfterFailure = false
        let f = try mailFixture(prefix: "WeGitMailContinueBatchUI")
        defer { f.git.remove() }
        let app = launch(f.git.root)
        defer { app.terminate() }
        let draft = "Mail draft 📬\nKeep across recovery"
        fill(app.textFields["commit-message"], draft)
        importMail(app, f.mail)
        enabled(app.buttons["mail-patch-up:2"])
        app.buttons["mail-patch-up:2"].click()
        enabled(app.buttons["mail-patch-down:1"])
        app.buttons["mail-patch-down:1"].click()
        capture(app, "Mail order can change and return before any repository write")
        app.buttons["mail-patch-execute"].click()
        progress(app, "mail-patch-progress", "已处理 1 / 2 个提交")
        app.buttons["mail-patch-resolve"].click()
        let row = app.outlineRows.matching(NSPredicate(format: "value CONTAINS %@", "file.txt")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.rightClick()
        app.menuItems["编辑冲突…"].click()
        enabled(app.buttons["conflict-editor-accept-theirs"])
        app.buttons["conflict-editor-accept-theirs"].click()
        enabled(app.buttons["conflict-editor-save"])
        let unmergedIndex = try rawIndex(f.git)
        app.buttons["conflict-editor-save"].click()
        enabled(app.buttons["conflict-editor-mark-resolved"])
        XCTAssertEqual(try rawIndex(f.git), unmergedIndex)
        XCTAssertEqual(try bytes(f.git, "file.txt"), Data("source\r\nlast".utf8))
        app.buttons["conflict-editor-mark-resolved"].click()
        gone(app.buttons["conflict-editor-mark-resolved"])
        app.terminate()
        app.launchArguments.append("--uitesting-keep-preferences")
        app.launchWeGit()
        app.buttons["mail-patch-recovery"].click()
        enabled(app.buttons["mail-patch-continue"])
        app.buttons["mail-patch-continue"].click()
        progress(app, "mail-patch-progress", "已处理 2 / 2 个提交")
        app.buttons["mail-patch-finish"].click()
        gone(app.buttons["mail-patch-finish"])
        XCTAssertEqual(try bytes(f.git, "file.txt"), Data("source\r\nlast".utf8))
        XCTAssertEqual(try bytes(f.git, "one.txt"), Data("one\r\nlast".utf8))
        XCTAssertEqual(try f.git.git(["status", "--porcelain"]), "")
        XCTAssertEqual(app.textFields["commit-message"].value as? String, draft)
        let head = try oid(f.git)
        let parent = try f.git.git(["rev-parse", "HEAD^"]).trimmingCharacters(in: .newlines)
        let export = f.git.root.appending(path: "native-mails.mbox")
        route(app, "提交历史")
        selectCommits(app, [parent, head])
        operation(app, "导出提交邮件补丁…")
        saveTo(app, export)
        let file = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: export.path) },
            object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [file], timeout: 20), .completed)
        let flags = [
            "format-patch", "--stdout", "--binary", "--full-index", "--root", "--no-zero-commit",
            "--no-ext-diff", "--no-textconv", "--no-color", "-1",
        ]
        let expected = try f.git.git(flags + [parent, "--"]) + f.git.git(flags + [head, "--"])
        XCTAssertEqual(try Data(contentsOf: export), Data(expected.utf8))
        capture(app, "Native selected-commit mail export equals Git's original byte stream")
    }

    @MainActor func testMailAbortCancelAndConfirmationPreserveOriginalTaskAndBackup() throws {
        continueAfterFailure = false
        let f = try mailFixture(prefix: "WeGitMailAbortBatchUI")
        defer { f.git.remove() }
        let app = launch(f.git.root)
        defer { app.terminate() }
        let draft = "Abort draft 🧩\nKeep the original task"
        fill(app.textFields["commit-message"], draft)
        importMail(app, f.mail)
        app.buttons["mail-patch-execute"].click()
        progress(app, "mail-patch-progress", "已处理 1 / 2 个提交")
        let paused = try oid(f.git)
        let index = try rawIndex(f.git)
        let working = try bytes(f.git, "file.txt")
        app.buttons["mail-patch-abort"].click()
        let cancel = app.dialogs.buttons["取消"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertEqual(try oid(f.git), paused)
        XCTAssertEqual(try rawIndex(f.git), index)
        XCTAssertEqual(try bytes(f.git, "file.txt"), working)
        app.buttons["mail-patch-abort"].click()
        let confirm = app.dialogs.buttons["中止序列"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        enabled(app.buttons["mail-patch-finish"])
        XCTAssertEqual(try oid(f.git), f.head)
        XCTAssertEqual(try bytes(f.git, "file.txt"), Data("target\r\nlast".utf8))
        XCTAssertEqual(try f.git.git(["status", "--porcelain"]), "")
        app.buttons["mail-patch-finish"].click()
        gone(app.buttons["mail-patch-finish"])
        XCTAssertEqual(app.textFields["commit-message"].value as? String, draft)
        let root = f.git.root.appending(path: ".git/wegit-recovery")
        let records = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var found = false
        for folder in records {
            let record = folder.appending(path: "record.json")
            guard FileManager.default.fileExists(atPath: record.path),
                let value = try JSONSerialization.jsonObject(with: Data(contentsOf: record))
                    as? [String: Any],
                value["operation"] as? String == "git-am-interruption-backup"
            else { continue }
            XCTAssertNotNil(value["conflictIndexTree"])
            XCTAssertEqual(try Data(contentsOf: folder.appending(path: "index")), index)
            found = true
        }
        XCTAssertTrue(found)
        capture(app, "Native abort returns to the start and retains the original conflict index backup")
    }

    private func initialize(_ f: UITestGit) throws {
        try f.git(["init", "--template=", "-b", "main"])
        for (name, value) in [
            ("user.name", "Commit Task UI"), ("user.email", "ui@example.invalid"),
            ("commit.gpgsign", "false"), ("core.autocrlf", "false"),
            ("core.hooksPath", f.root.appending(path: ".git/no-hooks").path),
        ] { try f.git(["config", "--local", name, value]) }
    }
    private func write(_ f: UITestGit, _ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: f.root.appending(path: path))
    }
    private func bytes(_ f: UITestGit, _ path: String) throws -> Data {
        try Data(contentsOf: f.root.appending(path: path))
    }
    private func rawIndex(_ f: UITestGit) throws -> Data {
        try Data(contentsOf: f.root.appending(path: ".git/index"))
    }
    private func oid(_ f: UITestGit) throws -> String {
        try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
    }
    private func commit(_ f: UITestGit, _ message: String) throws -> String {
        try f.git(["add", "--all"])
        try f.git(["commit", "-m", message])
        return try oid(f)
    }
    private func mailFixture(prefix: String) throws -> (git: UITestGit, mail: URL, head: String) {
        let f = try UITestGit(prefix: prefix)
        try initialize(f)
        try write(f, "file.txt", "base\r\nlast")
        _ = try commit(f, "Base")
        try f.git(["switch", "-c", "source"])
        try write(f, "one.txt", "one\r\nlast")
        _ = try commit(f, "First mail\n\nComplete message 📬")
        try write(f, "file.txt", "source\r\nlast")
        _ = try commit(f, "Second mail\n\nSecond body")
        let mail = f.root.appending(path: ".git/ordered.mbox")
        try Data(f.git(["format-patch", "--stdout", "--binary", "--full-index", "-2"]).utf8).write(to: mail)
        try f.git(["switch", "main"])
        try write(f, "file.txt", "target\r\nlast")
        return (f, mail, try commit(f, "Target divergence"))
    }
    @MainActor private func launch(_ root: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", "light", "--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        return app
    }
    @MainActor private func route(_ app: XCUIApplication, _ title: String) {
        let row = app.outlineRows.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
    }
    @MainActor private func selectCommits(_ app: XCUIApplication, _ commits: [String]) {
        for (index, commit) in commits.enumerated() {
            let row = app.outlineRows.matching(
                NSPredicate(format: "value CONTAINS %@", "提交 " + commit.prefix(12))
            ).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            if index == 0 {
                row.click()
            } else {
                XCUIElement.perform(withKeyModifiers: .command) { row.click() }
            }
        }
    }
    @MainActor private func operation(_ app: XCUIApplication, _ title: String) {
        enabled(app.menuButtons["history-operations"])
        app.menuButtons["history-operations"].click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }
    @MainActor private func toolbarAction(_ app: XCUIApplication, _ id: String) {
        enabled(app.menuButtons["toolbar-more"])
        app.menuButtons["toolbar-more"].click()
        let item = app.menuItems[id]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }
    @MainActor private func messageSource(_ app: XCUIApplication, _ title: String) {
        app.menuButtons["commit-message-sources"].click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }
    @MainActor private func native(_ app: XCUIApplication, menu: String, command: String) {
        app.menuBars.menuBarItems["native-menu-" + menu].click()
        let item = app.menuItems["native-command-" + command]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }
    @MainActor private func importMail(_ app: XCUIApplication, _ path: URL) {
        native(app, menu: "file", command: "importMailPatches")
        XCTAssertTrue(app.buttons["CancelButton"].waitForExistence(timeout: 5))
        goTo(app, path)
        enabled(app.buttons["OKButton"])
        app.buttons["OKButton"].click()
        enabled(app.buttons["mail-patch-execute"])
    }
    @MainActor private func goTo(_ app: XCUIApplication, _ path: URL) {
        app.typeKey("g", modifierFlags: [.command, .shift])
        let field = app.textFields["PathTextField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        fill(field, path.path)
        field.typeKey(.return, modifierFlags: [])
        gone(field)
    }
    @MainActor private func saveTo(_ app: XCUIApplication, _ path: URL) {
        let name = app.textFields["saveAsNameTextField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        goTo(app, path.deletingLastPathComponent())
        fill(name, path.lastPathComponent)
        enabled(app.buttons["OKButton"])
        app.buttons["OKButton"].click()
        gone(name)
    }
    @MainActor private func fill(_ field: XCUIElement, _ value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        UITestGit.preservingClipboard { clipboard in
            clipboard.clearContents()
            clipboard.setString(value, forType: .string)
            field.typeKey("v", modifierFlags: .command)
        }
        XCTAssertEqual(field.value as? String, value)
    }
    @MainActor private func waitForText(_ element: XCUIElement, _ value: String) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
    }
    @MainActor private func enabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
    }
    @MainActor private func gone(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForNonExistence(timeout: 20))
    }
    @MainActor private func progress(_ app: XCUIApplication, _ id: String, _ text: String) {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ title: String) {
        for attachment in [
            XCTAttachment(screenshot: app.windows["main"].screenshot()),
            XCTAttachment(string: app.debugDescription),
        ] {
            attachment.name = title
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
