import XCTest

final class RepositoryToolsWorkflowTests: XCTestCase {
    @MainActor func testInitializationAndExplicitShallowHistoryPreserveFilesAndLayers() throws {
        continueAfterFailure = false
        let source = try UITestGit(prefix: "WeGitToolsSourceUI")
        let existing = try UITestGit(prefix: "WeGitToolsExistingUI")
        let destination = try UITestGit(prefix: "WeGitToolsCloneUI")
        defer {
            source.remove()
            existing.remove()
            destination.remove()
        }
        try initialize(source)
        try Data("base\r\nlast".utf8).write(to: source.root.appending(path: "sample.txt"))
        try source.git(["add", "."])
        try source.git(["commit", "-m", "Base"])
        try source.git(["switch", "-c", "feature"])
        try Data("feature\n".utf8).write(to: source.root.appending(path: "feature.txt"))
        try source.git(["add", "."])
        try source.git(["commit", "-m", "Feature"])
        try source.git(["switch", "main"])
        for number in 1...4 {
            try Data("main \(number)\r\nlast".utf8).write(to: source.root.appending(path: "sample.txt"))
            try source.git(["commit", "-am", "Main \(number)"])
        }
        let kept = Data("已有内容\r\n末行".utf8)
        let keptFile = existing.root.appending(path: "保留.txt")
        try kept.write(to: keptFile)
        let sourceHead = try source.git(["rev-parse", "HEAD"])
        let sourceIndex = try index(source.root)
        let app = launch(source.root)
        defer { app.terminate() }
        native(app, menu: "file", command: "initializeRepository")
        fill(app.textFields["init-directory"], existing.root.path)
        fill(app.textFields["init-branch"], "preview-main")
        enabled(app.buttons["init-start"])
        capture(app, "Initialize an existing directory without staging its files")
        app.buttons["init-start"].click()
        gone(app.buttons["init-start"])
        XCTAssertTrue(app.checkBoxes["stage:untracked:保留.txt"].waitForExistence(timeout: 15))
        XCTAssertEqual(try Data(contentsOf: keptFile), kept)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: existing.root.appending(path: ".git/index").path))
        XCTAssertEqual(try existing.git(["symbolic-ref", "HEAD"]), "refs/heads/preview-main\n")

        native(app, menu: "file", command: "clone")
        fill(app.textFields["clone-url"], source.root.absoluteString)
        fill(app.textFields["clone-parent"], destination.root.path)
        fill(app.textFields["clone-folder"], "Shallow")
        let options = app.descendants(matching: .any).matching(identifier: "clone-options").firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        fill(app.textFields["clone-branch"], "main")
        app.checkBoxes["clone-single-branch"].click()
        app.checkBoxes["clone-shallow"].click()
        fill(app.textFields["clone-depth"], "1")
        enabled(app.buttons["clone-start"])
        capture(app, "Clone only main with one commit of history")
        app.buttons["clone-start"].click()
        gone(app.buttons["clone-start"])
        let clone = destination.root.appending(path: "Shallow")
        XCTAssertEqual(try UITestGit.run(["rev-list", "--count", "HEAD"], in: clone), "1\n")
        let refs = try UITestGit.run(["for-each-ref", "--format=%(refname)", "refs/remotes"], in: clone)
        XCTAssertTrue(refs.contains("refs/remotes/origin/main"))
        XCTAssertFalse(refs.contains("refs/remotes/origin/feature"))
        let head = try UITestGit.run(["rev-parse", "HEAD"], in: clone)
        let bytes = try Data(contentsOf: clone.appending(path: "sample.txt"))
        let originalIndex = try index(clone)
        native(app, menu: "repository", command: "historyDepth")
        fill(app.textFields["depth-count"], "1")
        enabled(app.buttons["depth-preview"])
        app.buttons["depth-preview"].click()
        enabled(app.buttons["depth-execute"])
        app.buttons["depth-execute"].click()
        gone(app.buttons["depth-execute"])
        XCTAssertEqual(try UITestGit.run(["rev-list", "--count", "HEAD"], in: clone), "2\n")
        app.buttons["depth-close"].click()
        gone(app.buttons["depth-close"])
        native(app, menu: "repository", command: "historyDepth")
        let complete = app.checkBoxes["depth-complete"]
        enabled(complete)
        complete.click()
        app.buttons["depth-preview"].click()
        enabled(app.buttons["depth-execute"])
        capture(app, "Explicitly fetch the remaining history without changing the checkout")
        app.buttons["depth-execute"].click()
        gone(app.buttons["depth-execute"])
        XCTAssertEqual(try UITestGit.run(["rev-list", "--count", "HEAD"], in: clone), "5\n")
        XCTAssertEqual(try UITestGit.run(["rev-parse", "--is-shallow-repository"], in: clone), "false\n")
        XCTAssertEqual(try UITestGit.run(["rev-parse", "HEAD"], in: clone), head)
        XCTAssertEqual(try index(clone), originalIndex)
        XCTAssertEqual(try Data(contentsOf: clone.appending(path: "sample.txt")), bytes)
        XCTAssertEqual(try source.git(["rev-parse", "HEAD"]), sourceHead)
        XCTAssertEqual(try index(source.root), sourceIndex)
        XCTAssertEqual(try Data(contentsOf: keptFile), kept)
    }

    @MainActor func testDivergentComparisonDirectionAndMergeBaseRemainReadOnly() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitToolsCompareUI")
        defer { f.remove() }
        try initialize(f)
        try Data("base\n".utf8).write(to: f.root.appending(path: "sample.txt"))
        try f.git(["add", "."])
        try f.git(["commit", "-m", "Base"])
        let ancestor = try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        try f.git(["switch", "-c", "feature"])
        try Data("feature\n".utf8).write(to: f.root.appending(path: "feature.txt"))
        try f.git(["add", "."])
        try f.git(["commit", "-m", "Feature"])
        let feature = try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        try f.git(["switch", "main"])
        let targetBytes = Data("target\r\nlast".utf8)
        try targetBytes.write(to: f.root.appending(path: "sample.txt"))
        try f.git(["commit", "-am", "Target"])
        let target = try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        let beforeIndex = try index(f.root)
        let app = launch(f.root)
        defer { app.terminate() }
        native(app, menu: "repository", command: "compareReferences")
        fill(app.textFields["comparison-base"], "feature")
        fill(app.textFields["comparison-target"], "main")
        enabled(app.buttons["comparison-execute"])
        app.buttons["comparison-execute"].click()
        let featureFile = app.descendants(matching: .any).matching(identifier: "comparison-file:feature.txt")
            .firstMatch
        XCTAssertTrue(featureFile.waitForExistence(timeout: 20))
        let objects = app.staticTexts["comparison-objects"]
        XCTAssertEqual(
            objects.value as? String ?? objects.label,
            String(feature.prefix(12)) + " → " + String(target.prefix(12)))
        capture(app, "Two-point comparison includes the feature-side deletion")
        let kind = app.popUpButtons["comparison-kind"]
        XCTAssertTrue(kind.waitForExistence(timeout: 5))
        kind.click()
        app.menuItems["共同祖先到目标"].click()
        enabled(app.buttons["comparison-execute"])
        app.buttons["comparison-execute"].click()
        let effective = app.staticTexts["comparison-effective-base"]
        XCTAssertTrue(effective.waitForExistence(timeout: 20))
        XCTAssertTrue((effective.value as? String ?? effective.label).contains(String(ancestor.prefix(12))))
        XCTAssertFalse(featureFile.exists)
        let sample = app.descendants(matching: .any).matching(identifier: "comparison-file:sample.txt")
            .firstMatch
        XCTAssertTrue(sample.exists)
        sample.click()
        XCTAssertTrue(app.menuButtons["commit-export-patch"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.menuButtons["commit-file-restore:sample.txt"].isHittable)
        capture(app, "Merge-base comparison shows only target-side changes and reachable file tools")
        app.buttons["comparison-close"].click()
        gone(app.buttons["comparison-close"])
        XCTAssertEqual(try index(f.root), beforeIndex)
        XCTAssertEqual(try f.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines), target)
        XCTAssertEqual(try Data(contentsOf: f.root.appending(path: "sample.txt")), targetBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appending(path: "feature.txt").path))
    }

    @MainActor func testSelectedDiscardHistoricalRestoreAndIgnoreUndoPreserveRawLayers() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitToolsFilesUI")
        defer { f.remove() }
        try initialize(f)
        let path = "selected.txt"
        let file = f.root.appending(path: path)
        let base = Data("a\r\nb\r\nc\r\nd".utf8)
        let working = Data("a\r\nb\r\nadded\r\nCC\r\nd".utf8)
        try base.write(to: file)
        try Data("original\n".utf8).write(to: f.root.appending(path: "other.txt"))
        try f.git(["add", "."])
        try f.git(["commit", "-m", "Base"])
        let head = try f.git(["rev-parse", "HEAD"])
        try Data("already staged\n".utf8).write(to: f.root.appending(path: "other.txt"))
        try f.git(["add", "other.txt"])
        try working.write(to: file)
        let untouched = Data("private\r\nlast".utf8)
        try untouched.write(to: f.root.appending(path: "private.txt"))
        let originalIndex = try index(f.root)
        let originalExclude = try Data(contentsOf: f.root.appending(path: ".git/info/exclude"))
        let app = launch(f.root)
        defer { app.terminate() }
        fill(app.textFields["commit-message"], "保留草稿 👨‍💻")
        openFile(app, layer: "unstaged", path: path)
        let selected = app.buttons["diff-select-line:3:unified"]
        XCTAssertTrue(selected.waitForExistence(timeout: 15))
        selected.click()
        app.buttons["diff-discard-selected-lines-preview"].click()
        enabled(app.buttons["file-modification-execute"])
        capture(app, "Discard preview preserves the unselected replacement")
        app.buttons["file-modification-cancel"].click()
        gone(app.buttons["file-modification-execute"])
        XCTAssertEqual(try Data(contentsOf: file), working)
        XCTAssertEqual(try index(f.root), originalIndex)
        app.buttons["diff-discard-selected-lines-preview"].click()
        enabled(app.buttons["file-modification-execute"])
        app.buttons["file-modification-execute"].click()
        success(app, "文件更新完成")
        XCTAssertEqual(try Data(contentsOf: file), Data("a\r\nb\r\nCC\r\nd".utf8))
        XCTAssertEqual(try index(f.root), originalIndex)
        app.buttons["file-modification-recovery"].click()
        restoreLatest(app)
        XCTAssertEqual(try Data(contentsOf: file), working)
        XCTAssertEqual(try index(f.root), originalIndex)
        app.buttons["recovery-close"].click()
        gone(app.buttons["recovery-close"])
        app.typeKey("2", modifierFlags: .command)
        let history = app.descendants(matching: .any).matching(identifier: "history-list").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        let row = history.descendants(matching: .any).matching(
            NSPredicate(
                format: "value CONTAINS %@", String(head.trimmingCharacters(in: .newlines).prefix(12)))
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let commitFile = app.descendants(matching: .any).matching(identifier: "commit-file:" + path)
            .firstMatch
        XCTAssertTrue(commitFile.waitForExistence(timeout: 15))
        commitFile.click()
        app.menuButtons["commit-file-restore:" + path].click()
        app.menuItems["恢复目标版本…"].click()
        enabled(app.buttons["file-modification-execute"])
        XCTAssertEqual(app.radioButtons["工作文件"].value as? Int, 1)
        app.buttons["file-modification-execute"].click()
        success(app, "文件更新完成")
        XCTAssertEqual(try Data(contentsOf: file), base)
        XCTAssertEqual(try index(f.root), originalIndex)
        app.buttons["file-modification-cancel"].click()
        gone(app.buttons["file-modification-cancel"])
        app.typeKey("1", modifierFlags: .command)
        for scope in [".git/info/exclude", ".gitignore"] {
            let untracked = fileRow(app, layer: "untracked", path: "private.txt")
            untracked.rightClick()
            app.menuItems["ignore-untracked:private.txt"].click()
            let radio = app.radioButtons[scope]
            XCTAssertTrue(radio.waitForExistence(timeout: 10))
            if radio.value as? Int != 1 { radio.click() }
            enabled(app.buttons["ignore-rule-execute"])
            app.buttons["ignore-rule-execute"].click()
            success(app, "忽略规则已保存")
            let ruleFile = f.root.appending(path: scope)
            let expected =
                scope == ".gitignore"
                ? Data("/private.txt\n".utf8)
                : originalExclude + Data("/private.txt\n".utf8)
            XCTAssertEqual(try Data(contentsOf: ruleFile), expected)
            XCTAssertEqual(try Data(contentsOf: f.root.appending(path: "private.txt")), untouched)
            XCTAssertEqual(try index(f.root), originalIndex)
            capture(app, "\(scope) saves only the selected ignore rule")
            app.buttons["ignore-rule-undo"].click()
            success(app, "忽略规则已撤销")
            if scope == ".gitignore" {
                XCTAssertFalse(FileManager.default.fileExists(atPath: ruleFile.path))
            } else {
                XCTAssertEqual(try Data(contentsOf: ruleFile), originalExclude)
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: f.root.appending(path: ".git/info/exclude.lock").path))
            app.buttons["ignore-rule-cancel"].click()
            gone(app.buttons["ignore-rule-cancel"])
        }
        XCTAssertEqual(try f.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try index(f.root), originalIndex)
        XCTAssertEqual(app.textFields["commit-message"].value as? String, "保留草稿 👨‍💻")
    }

    @MainActor func testRawPatchExportCancelApplyAndBackupRestoreRoundTrip() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitToolsPatchUI")
        let output = try UITestGit(prefix: "WeGitToolsPatchOutputUI")
        defer {
            f.remove()
            output.remove()
        }
        try initialize(f)
        let file = f.root.appending(path: "sample.txt")
        let original = Data("a\r\nb\r\nc\r\nd".utf8)
        let working = Data("a\r\nB\r\nC\r\nd".utf8)
        try original.write(to: file)
        try Data("original\n".utf8).write(to: f.root.appending(path: "other.txt"))
        try f.git(["add", "."])
        try f.git(["commit", "-m", "Base"])
        let head = try f.git(["rev-parse", "HEAD"])
        try Data("already staged\n".utf8).write(to: f.root.appending(path: "other.txt"))
        try f.git(["add", "other.txt"])
        try working.write(to: file)
        let originalIndex = try index(f.root)
        let expected = Data(
            try f.git([
                "diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "--no-color", "--",
                "sample.txt",
            ]).utf8)
        let app = launch(f.root)
        defer { app.terminate() }
        let row = fileRow(app, layer: "unstaged", path: "sample.txt")
        row.rightClick()
        app.menuItems["导出文件补丁…"].click()
        fill(app.textFields["saveAsNameTextField"], "roundtrip.patch")
        goTo(app, output.root)
        app.buttons["OKButton"].click()
        let patch = output.root.appending(path: "roundtrip.patch")
        let exported = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: patch.path) }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [exported], timeout: 15), .completed)
        XCTAssertEqual(try Data(contentsOf: patch), expected)
        XCTAssertEqual(try Data(contentsOf: file), working)
        XCTAssertEqual(try index(f.root), originalIndex)
        // Reproduce a separate consumer's clean work layer while retaining staged work.
        try original.write(to: file)
        importPatch(app, patch)
        enabled(app.buttons["patch-execute"])
        XCTAssertEqual(app.radioButtons["工作文件"].value as? Int, 1)
        capture(app, "Raw CRLF patch defaults to the work layer")
        app.buttons["patch-cancel"].click()
        gone(app.buttons["patch-cancel"])
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try index(f.root), originalIndex)
        importPatch(app, patch)
        enabled(app.buttons["patch-execute"])
        app.buttons["patch-execute"].click()
        success(app, "文件补丁已应用")
        XCTAssertEqual(try Data(contentsOf: file), working)
        XCTAssertEqual(try index(f.root), originalIndex)
        XCTAssertEqual(try f.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try f.git(["show", ":other.txt"]), "already staged\n")
        app.buttons["patch-show-recovery"].click()
        restoreLatest(app)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try index(f.root), originalIndex)
        XCTAssertEqual(try f.git(["rev-parse", "HEAD"]), head)
        capture(app, "Patch backup restores exact pre-application bytes without creating a commit")
    }

    private func initialize(_ fixture: UITestGit) throws {
        try fixture.git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Repository Tools UI"), ("user.email", "ui@example.invalid"),
            ("commit.gpgsign", "false"), ("core.autocrlf", "false"),
            ("core.hooksPath", fixture.root.appending(path: "no-hooks").path),
        ] { try fixture.git(["config", key, value]) }
    }
    private func index(_ root: URL) throws -> Data {
        try Data(contentsOf: root.appending(path: ".git/index"))
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
    @MainActor private func native(_ app: XCUIApplication, menu: String, command: String) {
        let opener = app.menuBars.menuBarItems["native-menu-" + menu]
        XCTAssertTrue(opener.waitForExistence(timeout: 5))
        opener.click()
        let item = app.menuItems["native-command-" + command]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
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
    @MainActor private func fileRow(_ app: XCUIApplication, layer: String, path: String) -> XCUIElement {
        let row = app.outlineRows.containing(.checkBox, identifier: "stage:" + layer + ":" + path).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        return row
    }
    @MainActor private func openFile(_ app: XCUIApplication, layer: String, path: String) {
        fileRow(app, layer: layer, path: path).staticTexts[path].firstMatch.click()
        XCTAssertTrue(app.scrollViews["diff-content"].waitForExistence(timeout: 15))
    }
    @MainActor private func restoreLatest(_ app: XCUIApplication) {
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recovery-record:'"))
            .firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        record.click()
        enabled(app.buttons["recovery-restore"])
        app.buttons["recovery-restore"].click()
        enabled(app.buttons["recovery-execute"])
        app.buttons["recovery-execute"].click()
        gone(app.buttons["recovery-execute"])
        success(app, "内容已恢复")
    }
    @MainActor private func importPatch(_ app: XCUIApplication, _ patch: URL) {
        native(app, menu: "file", command: "importPatch")
        XCTAssertTrue(app.buttons["CancelButton"].waitForExistence(timeout: 5))
        goTo(app, patch)
        enabled(app.buttons["OKButton"])
        app.buttons["OKButton"].click()
    }
    @MainActor private func goTo(_ app: XCUIApplication, _ url: URL) {
        app.typeKey("g", modifierFlags: [.command, .shift])
        let field = app.textFields["PathTextField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(url.path)
        XCTAssertEqual(field.value as? String, url.path)
        field.typeKey(.return, modifierFlags: [])
        gone(field)
    }
    @MainActor private func enabled(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed)
    }
    @MainActor private func gone(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForNonExistence(timeout: 20))
    }
    @MainActor private func success(_ app: XCUIApplication, _ message: String) {
        let sheet = app.windows["main"].sheets.firstMatch
        let host = sheet.exists ? sheet : app.windows["main"]
        let feedback = host.buttons["operation-feedback-message"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND label BEGINSWITH %@ AND label CONTAINS %@", "完成:", message),
            object: feedback)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        for attachment in [
            XCTAttachment(screenshot: app.windows["main"].screenshot()),
            XCTAttachment(string: app.debugDescription),
        ] {
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
