import AppKit
import XCTest

/// Designed for hosted batch execution; local validation compiles source without running XCTest.
final class ResourceManagementWorkflowTests: XCTestCase {
    @MainActor func testSubmoduleAddSourceChangeAndRemovalPreserveParentDraftAndChildData() throws {
        continueAfterFailure = false
        let parent = try UITestGit(prefix: "WeGitResourceParentUI")
        let source = try UITestGit(prefix: "WeGitResourceSourceUI")
        let replacement = try UITestGit(prefix: "WeGitResourceReplacementUI")
        defer {
            parent.remove()
            source.remove()
            replacement.remove()
        }
        for fixture in [parent, source, replacement] { try initialize(fixture) }
        let childBytes = Data("child source\r\nlast".utf8)
        try childBytes.write(to: source.root.appending(path: "child.txt"))
        try source.git(["add", "."])
        try source.git(["commit", "-m", "Child source"])
        let sourceOID = try source.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        try Data("replacement source\n".utf8).write(to: replacement.root.appending(path: "child.txt"))
        try replacement.git(["add", "."])
        try replacement.git(["commit", "-m", "Replacement source"])
        let replacementOID = try replacement.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        try Data("base parent\r\nlast".utf8).write(to: parent.root.appending(path: "parent.txt"))
        try parent.git(["add", "."])
        try parent.git(["commit", "-m", "Parent"])
        let head = try parent.git(["rev-parse", "HEAD"])
        try Data("staged parent\r\nlast".utf8).write(to: parent.root.appending(path: "parent.txt"))
        try parent.git(["add", "--", "parent.txt"])
        let workingParent = Data("working parent\r\nlast".utf8)
        try workingParent.write(to: parent.root.appending(path: "parent.txt"))
        try FileManager.default.createDirectory(
            at: parent.root.appending(path: "modules"), withIntermediateDirectories: false)
        let originalIndex = try index(parent.root)
        let originalConfig = try Data(contentsOf: parent.root.appending(path: ".git/config"))
        let path = "modules/子模块 [*]"
        let child = parent.root.appending(path: path)
        let app = launch(parent.root)
        defer { app.terminate() }
        let draft = "资源草稿 🧩"
        fill(app.textFields["commit-message"], draft)
        resources(app, title: "仓库资源")

        openAdd(app, path: path, source: source.root.path)
        previewSubmodule(app)
        capture(app, "Submodule add preview binds the literal path and fixed object")
        cancelSheet(app, identifier: "submodule-cancel")
        XCTAssertEqual(try index(parent.root), originalIndex)
        XCTAssertEqual(try Data(contentsOf: parent.root.appending(path: ".git/config")), originalConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: parent.root.appending(path: ".gitmodules").path))

        openAdd(app, path: path, source: source.root.path)
        previewSubmodule(app)
        executeSubmodule(app)
        XCTAssertEqual(try Data(contentsOf: child.appending(path: "child.txt")), childBytes)
        XCTAssertEqual(try UITestGit.run(["rev-parse", "HEAD"], in: child), sourceOID + "\n")
        XCTAssertTrue(
            try parent.git(["--literal-pathspecs", "ls-files", "--stage", "--", path]).contains(sourceOID))
        XCTAssertEqual(try parent.git(["show", ":parent.txt"]), "staged parent\r\nlast")
        XCTAssertEqual(try Data(contentsOf: parent.root.appending(path: "parent.txt")), workingParent)
        XCTAssertEqual(try parent.git(["rev-parse", "HEAD"]), head)
        closeCompletedSheet(app, identifier: "submodule-cancel", title: "关闭")
        let addedIndex = try index(parent.root)
        let addedModules = try Data(contentsOf: parent.root.appending(path: ".gitmodules"))
        let childIndex = try index(child)
        let childConfig = try Data(contentsOf: child.appending(path: ".git/config"))

        openModuleAction(app, path: path, title: "更改子模块来源")
        let sync = sheet(app).checkBoxes["submodule-sync-child-source"].firstMatch
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        XCTAssertTrue((sync.value as? String) == "0" || (sync.value as? NSNumber)?.intValue == 0)
        fill(sheet(app).textFields["submodule-source"], replacement.root.path)
        previewSubmodule(app)
        cancelSheet(app, identifier: "submodule-cancel")
        XCTAssertEqual(try Data(contentsOf: parent.root.appending(path: ".gitmodules")), addedModules)
        XCTAssertEqual(try Data(contentsOf: child.appending(path: ".git/config")), childConfig)
        XCTAssertEqual(try index(parent.root), addedIndex)

        openModuleAction(app, path: path, title: "更改子模块来源")
        fill(sheet(app).textFields["submodule-source"], replacement.root.path)
        sheet(app).checkBoxes["submodule-sync-child-source"].firstMatch.click()
        previewSubmodule(app)
        capture(app, "Child origin synchronization is an explicit choice without a fetch")
        executeSubmodule(app)
        XCTAssertEqual(
            try UITestGit.run(["config", "--get", "remote.origin.url"], in: child),
            replacement.root.path + "\n")
        XCTAssertEqual(
            try parent.git(["config", "--file", ".gitmodules", "--get", "submodule." + path + ".url"]),
            replacement.root.path + "\n")
        XCTAssertEqual(try index(parent.root), addedIndex)
        XCTAssertEqual(try index(child), childIndex)
        XCTAssertEqual(try UITestGit.run(["rev-parse", "HEAD"], in: child), sourceOID + "\n")
        XCTAssertEqual(try Data(contentsOf: child.appending(path: "child.txt")), childBytes)
        XCTAssertThrowsError(try UITestGit.run(["cat-file", "-e", replacementOID + "^{commit}"], in: child))
        closeCompletedSheet(app, identifier: "submodule-cancel", title: "关闭")

        for (key, value) in [
            ("user.name", "Resource UI"), ("user.email", "ui@example.invalid"), ("commit.gpgsign", "false"),
            ("core.hooksPath", "/dev/null"),
        ] {
            try UITestGit.run(["config", key, value], in: child)
        }
        try Data("independent commit\n".utf8).write(to: child.appending(path: "later.txt"))
        try UITestGit.run(["add", "--", "later.txt"], in: child)
        try UITestGit.run(["commit", "-m", "Independent child commit"], in: child)
        let retainedHead = try UITestGit.run(["rev-parse", "HEAD"], in: child)
        let retainedIndex = try index(child)
        let childDraft = Data("child draft\r\nlast".utf8)
        try childDraft.write(to: child.appending(path: "child.txt"))
        try Data("*.ignored\n".utf8).write(to: child.appending(path: ".gitignore"))
        let ignored = Data("retained ignored\r\nlast".utf8)
        try ignored.write(to: child.appending(path: "retained.ignored"))
        try Data("retained untracked\n".utf8).write(to: child.appending(path: "untracked.txt"))
        let modules = Data(
            ("# keep comment\r\n[submodule \"" + path + "\"] # keep header\r\n\tpath = \"" + path
                + "\"\r\n\turl = \"" + replacement.root.path
                + "\" # keep URL note\r\n\tbranch = main\r\n# no final newline").utf8)
        try modules.write(to: parent.root.appending(path: ".gitmodules"))
        openModuleAction(app, path: path, title: "移除子模块")
        previewSubmodule(app)
        let confirmation = sheet(app)
        XCTAssertTrue(confirmation.staticTexts["有改动"].firstMatch.exists)
        XCTAssertTrue(confirmation.staticTexts["未跟踪"].firstMatch.exists)
        XCTAssertTrue(confirmation.staticTexts["已忽略"].firstMatch.exists)
        XCTAssertTrue(confirmation.staticTexts["存在未进入远端引用的提交"].firstMatch.exists)
        capture(app, "Removal previews dirty ignored untracked and independent child data")
        cancelSheet(app, identifier: "submodule-cancel")
        XCTAssertEqual(try index(parent.root), addedIndex)
        XCTAssertEqual(try Data(contentsOf: parent.root.appending(path: ".gitmodules")), modules)
        XCTAssertEqual(try index(child), retainedIndex)
        XCTAssertEqual(try Data(contentsOf: child.appending(path: "retained.ignored")), ignored)
        openModuleAction(app, path: path, title: "移除子模块")
        previewSubmodule(app)
        executeSubmodule(app)
        XCTAssertEqual(try parent.git(["--literal-pathspecs", "ls-files", "--stage", "--", path]), "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.appending(path: ".git").path))
        XCTAssertEqual(try index(child), retainedIndex)
        XCTAssertEqual(try UITestGit.run(["rev-parse", "HEAD"], in: child), retainedHead)
        XCTAssertEqual(try Data(contentsOf: child.appending(path: "child.txt")), childDraft)
        XCTAssertEqual(try Data(contentsOf: child.appending(path: "retained.ignored")), ignored)
        let removed = try String(contentsOf: parent.root.appending(path: ".gitmodules"), encoding: .utf8)
        XCTAssertTrue(removed.contains("# keep comment\r\n") && removed.contains("# keep header\r\n"))
        XCTAssertTrue(removed.contains("# keep URL note\r\n") && removed.contains("\tbranch = main\r\n"))
        XCTAssertTrue(removed.hasSuffix("# no final newline"))
        closeCompletedSheet(app, identifier: "submodule-cancel", title: "关闭")
        XCTAssertEqual(try parent.git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try parent.git(["show", ":parent.txt"]), "staged parent\r\nlast")
        XCTAssertEqual(try Data(contentsOf: parent.root.appending(path: "parent.txt")), workingParent)
        XCTAssertEqual(app.textFields["commit-message"].value as? String, draft)
        capture(app, "Removed registration retains the child repository and the parent draft")
    }

    @MainActor func testLFSRuleTrackCancelAndUntrackPreserveIndexRawAttributesAndFiles() throws {
        continueAfterFailure = false
        let fixture = try UITestGit(prefix: "WeGitLFSRulesUI")
        defer { fixture.remove() }
        try initialize(fixture)
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: "nested"), withIntermediateDirectories: false)
        let rootBytes = Data("root bytes\r\nlast".utf8)
        let childBytes = Data("nested bytes\r\nlast".utf8)
        try rootBytes.write(to: fixture.root.appending(path: "root.bin"))
        try childBytes.write(to: fixture.root.appending(path: "nested/child.bin"))
        try Data("*.bin filter=custom -text\n".utf8).write(
            to: fixture.root.appending(path: "nested/.gitattributes"))
        let original = Data("# preserved comment\r\n*.bin custom=keep -text".utf8)
        try original.write(to: fixture.root.appending(path: ".gitattributes"))
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-m", "Attribute fixture"])
        let beforeIndex = try index(fixture.root)
        let beforeHead = try fixture.git(["rev-parse", "HEAD"])
        let beforeConfig = try Data(contentsOf: fixture.root.appending(path: ".git/config"))
        let app = launch(fixture.root, language: "en")
        defer { app.terminate() }
        resources(app, title: "Repository resources")
        openLFS(app)
        fill(sheet(app).textFields["lfs-rule-pattern"], "*.bin")
        previewLFS(app)
        capture(app, "English LFS rule preview shows nested effective attribute sources")
        cancelSheet(app, identifier: "lfs-rule-cancel")
        XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: ".gitattributes")), original)
        XCTAssertEqual(try index(fixture.root), beforeIndex)
        openLFS(app)
        fill(sheet(app).textFields["lfs-rule-pattern"], "*.bin")
        previewLFS(app)
        executeLFS(app)
        let tracked = Data(
            (String(decoding: original, as: UTF8.self) + "\r\n\"*.bin\" filter=lfs diff=lfs merge=lfs -text")
                .utf8)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: ".gitattributes")), tracked)
        XCTAssertEqual(
            try fixture.git(["check-attr", "-z", "filter", "--", "root.bin", "nested/child.bin"]),
            "root.bin\0filter\0lfs\0nested/child.bin\0filter\0custom\0")
        closeCompletedSheet(app, identifier: "lfs-rule-cancel", title: "Close")
        openLFS(app)
        let actions = sheet(app).radioButtons
        XCTAssertEqual(actions.count, 2)
        actions.element(boundBy: 1).click()
        fill(sheet(app).textFields["lfs-rule-pattern"], "*.bin")
        previewLFS(app)
        capture(app, "Untrack retains unrelated attributes comments and CRLF")
        executeLFS(app)
        let untracked = Data((String(decoding: original, as: UTF8.self) + "\r\n\"*.bin\"    -text").utf8)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: ".gitattributes")), untracked)
        XCTAssertEqual(
            try fixture.git(["check-attr", "-z", "filter", "--", "root.bin", "nested/child.bin"]),
            "root.bin\0filter\0unspecified\0nested/child.bin\0filter\0custom\0")
        closeCompletedSheet(app, identifier: "lfs-rule-cancel", title: "Close")
        XCTAssertEqual(try index(fixture.root), beforeIndex)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"]), beforeHead)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: ".git/config")), beforeConfig)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: "root.bin")), rootBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appending(path: "nested/child.bin")), childBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.root.appending(path: ".git/hooks/pre-push").path))
        capture(app, "Saved LFS rules preserve the raw index and never hydrate or stage files")
    }

    private func initialize(_ fixture: UITestGit) throws {
        try fixture.git(["init", "--template=", "-b", "main"])
        for (key, value) in [
            ("user.name", "Resource UI"), ("user.email", "ui@example.invalid"), ("commit.gpgsign", "false"),
            ("core.hooksPath", "/dev/null"),
        ] {
            try fixture.git(["config", key, value])
        }
    }
    private func index(_ root: URL) throws -> Data {
        try Data(contentsOf: root.appending(path: ".git/index"))
    }
    @MainActor private func launch(_ root: URL, language: String = "zh-Hans") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-language", language, "--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = root.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        XCTAssertTrue(app.windows["main"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.outlines["changes-list"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor private func sheet(_ app: XCUIApplication) -> XCUIElement {
        let element = app.windows["main"].sheets.firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        return element
    }
    @MainActor private func resources(_ app: XCUIApplication, title: String) {
        app.buttons["toolbar-inspector"].click()
        let tab = app.radioButtons[title].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), app.debugDescription)
        tab.click()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "inspector-resources").firstMatch
                .waitForExistence(timeout: 15))
    }
    @MainActor private func openAdd(_ app: XCUIApplication, path: String, source: String) {
        enabled(app.buttons["inspector-submodule-add"].firstMatch)
        app.buttons["inspector-submodule-add"].firstMatch.click()
        fill(sheet(app).textFields["submodule-path"], path)
        fill(sheet(app).textFields["submodule-source"], source)
    }
    @MainActor private func openModuleAction(_ app: XCUIApplication, path: String, title: String) {
        let menu = app.repositoryInspector.descendants(matching: .any).matching(
            identifier: "inspector-submodule-manage:" + path
        ).firstMatch
        enabled(menu)
        menu.click()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(item.isHittable)
        item.click()
        _ = sheet(app)
    }
    @MainActor private func previewSubmodule(_ app: XCUIApplication) {
        let preview = sheet(app).buttons["submodule-prepare"].firstMatch
        enabled(preview)
        preview.click()
        enabled(sheet(app).buttons["submodule-execute"].firstMatch)
    }
    @MainActor private func executeSubmodule(_ app: XCUIApplication) {
        sheet(app).buttons["submodule-execute"].firstMatch.click()
        XCTAssertTrue(
            sheet(app).staticTexts["子模块配置已更新。"].firstMatch.waitForExistence(timeout: 20), app.debugDescription
        )
    }
    @MainActor private func openLFS(_ app: XCUIApplication) {
        enabled(app.buttons["inspector-lfs-rules"].firstMatch)
        app.buttons["inspector-lfs-rules"].firstMatch.click()
        _ = sheet(app)
    }
    @MainActor private func previewLFS(_ app: XCUIApplication) {
        let preview = sheet(app).buttons["lfs-rule-prepare"].firstMatch
        enabled(preview)
        preview.click()
        enabled(sheet(app).buttons["lfs-rule-execute"].firstMatch)
    }
    @MainActor private func executeLFS(_ app: XCUIApplication) {
        sheet(app).buttons["lfs-rule-execute"].firstMatch.click()
        let result = sheet(app).descendants(matching: .any).matching(identifier: "operation-feedback")
            .firstMatch
        let complete = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", "success"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 20), .completed, app.debugDescription)
    }
    @MainActor private func cancelSheet(_ app: XCUIApplication, identifier: String) {
        let current = sheet(app)
        current.buttons[identifier].firstMatch.click()
        XCTAssertTrue(current.waitForNonExistence(timeout: 10))
    }
    @MainActor private func closeCompletedSheet(_ app: XCUIApplication, identifier: String, title: String) {
        let current = sheet(app)
        let close = current.buttons[identifier].firstMatch
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", title), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        close.click()
        XCTAssertTrue(current.waitForNonExistence(timeout: 10))
    }
    @MainActor private func fill(_ field: XCUIElement, _ value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        UITestGit.preservingClipboard { clipboard in
            clipboard.clearContents()
            clipboard.setString(value, forType: .string)
            field.typeKey("v", modifierFlags: .command)
        }
        XCTAssertEqual(field.value as? String, value)
    }
    @MainActor private func enabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertTrue(element.isHittable)
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
