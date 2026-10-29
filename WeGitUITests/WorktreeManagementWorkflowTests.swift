import CryptoKit
import XCTest

final class WorktreeManagementWorkflowTests: XCTestCase {
    @MainActor func testCreateCancelRemoveAndProtectChangedWorktrees() throws {
        continueAfterFailure = false
        let f = try UITestGit(prefix: "WeGitWorktreeManagementUI")
        defer { f.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.root.path)
        let main = f.root.appending(path: "main").resolvingSymlinksInPath()
        let linked = f.root.appending(path: "linked").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: false)
        func git(_ args: [String], at location: URL? = nil) throws -> String {
            try UITestGit.run(args, in: location ?? main)
        }
        _ = try git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Worktree UI"), ("user.email", "fixture@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", f.root.appending(path: "no-hooks").path),
        ] {
            _ = try git(["config", key, value])
        }
        let base = Data("base\n".utf8)
        try base.write(to: main.appending(path: "file"))
        try Data("other\n".utf8).write(to: main.appending(path: "other"))
        try Data("*.ignored\n".utf8).write(to: main.appending(path: ".gitignore"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-m", "Base"])
        let bare = f.root.appending(path: "remote.git")
        _ = try git(["init", "--bare", bare.path])
        _ = try git(["remote", "add", "origin", bare.path])
        _ = try git(["push", "origin", "main"])
        let head = try git(["rev-parse", "HEAD"])
        try Data("already staged\n".utf8).write(to: main.appending(path: "other"))
        _ = try git(["add", "other"])
        let index = try Data(contentsOf: main.appending(path: ".git/index"))
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", "light", "-confirmRepositorySwitch", "NO", "--uitesting"]
        app.launchEnvironment["WEGIT_UI_TEST_REPOSITORY"] = main.path
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        app.launchEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        app.launchWeGit()
        defer { app.terminate() }
        let draft = app.textFields["commit-message"]
        XCTAssertTrue(draft.exists || draft.waitForExistence(timeout: 10))
        draft.click()
        draft.typeText("Keep Main worktree draft")
        openManager(app)
        prepareCreation(app, path: linked.path, branch: "topic")
        let execute = app.buttons["worktree-execute"]
        waitEnabled(execute)
        capture(app, "Chinese light worktree creation preview")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(execute.waitForNonExistence(timeout: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked.path))
        XCTAssertEqual(try Data(contentsOf: main.appending(path: ".git/index")), index)
        prepareCreation(app, path: linked.path, branch: "topic")
        waitEnabled(execute)
        execute.click()
        XCTAssertTrue(execute.waitForNonExistence(timeout: 10))
        XCTAssertEqual(try git(["symbolic-ref", "HEAD"], at: linked), "refs/heads/topic\n")
        XCTAssertEqual(try Data(contentsOf: linked.appending(path: "file")), base)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: main.appending(path: ".git/index")), index)
        let openLinked = app.buttons["worktree-open:" + id(linked)]
        waitEnabled(openLinked)
        openLinked.click()
        expectValue(draft, "")
        draft.click()
        draft.typeText("Topic worktree draft")
        openManager(app)
        let openMain = app.buttons["worktree-open:" + id(main)]
        waitEnabled(openMain)
        openMain.click()
        expectValue(draft, "Keep Main worktree draft")
        openManager(app)
        let remove = app.buttons["worktree-remove:" + id(linked)]
        waitEnabled(remove)
        _ = try git(["worktree", "lock", linked.path])
        app.buttons["worktree-refresh"].click()
        let disabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == false"), object: remove)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 10), .completed)
        capture(app, "Locked worktree removal is disabled")
        _ = try git(["worktree", "unlock", linked.path])
        try Data("unsaved\n".utf8).write(to: linked.appending(path: "file"))
        app.buttons["worktree-refresh"].click()
        waitEnabled(remove)
        remove.click()
        let error = app.descendants(matching: .any).matching(identifier: "worktree-error").firstMatch
        XCTAssertTrue(error.exists || error.waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: linked.appending(path: "file")), Data("unsaved\n".utf8))
        try base.write(to: linked.appending(path: "file"))
        app.buttons["worktree-refresh"].click()
        waitEnabled(remove)
        remove.click()
        waitEnabled(execute)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(execute.waitForNonExistence(timeout: 5))
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path))
        app.buttons["worktree-cancel"].click()
        app.terminate()
        app.launchArguments = [
            "-language", "en", "-appearance", "dark", "-confirmRepositorySwitch", "NO", "--uitesting",
            "--uitesting-keep-preferences",
        ]
        app.launchWeGit()
        expectValue(draft, "Keep Main worktree draft")
        openManager(app)
        waitEnabled(remove)
        remove.click()
        waitEnabled(execute)
        let external = Data("external edit\n".utf8)
        try external.write(to: linked.appending(path: "file"))
        execute.click()
        XCTAssertTrue(execute.waitForNonExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "worktree-preview-path").firstMatch.exists)
        XCTAssertTrue(app.buttons["worktree-cancel"].exists)
        capture(app, "English dark stale removal preserves the confirmation and external bytes")
        XCTAssertEqual(try Data(contentsOf: linked.appending(path: "file")), external)
        XCTAssertEqual(try Data(contentsOf: main.appending(path: ".git/index")), index)
        app.buttons["worktree-cancel"].click()
        try base.write(to: linked.appending(path: "file"))
        let ignored = Data("private ignored bytes\n".utf8)
        let late = Data("late ignored bytes\n".utf8)
        try ignored.write(to: linked.appending(path: "private.ignored"))
        app.buttons["worktree-refresh"].click()
        waitEnabled(remove)
        remove.click()
        waitEnabled(execute)
        try late.write(to: linked.appending(path: "late.ignored"))
        execute.click()
        XCTAssertTrue(execute.waitForNonExistence(timeout: 10))
        let path = app.descendants(matching: .any).matching(identifier: "worktree-preserved-path").firstMatch
        XCTAssertTrue(path.exists || path.waitForExistence(timeout: 10))
        let reported = (path.value as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } ?? path.label
        XCTAssertTrue(reported.hasPrefix("/"))
        let kept = URL(fileURLWithPath: reported)
        XCTAssertEqual(try Data(contentsOf: kept.appending(path: "file")), base)
        XCTAssertEqual(try Data(contentsOf: kept.appending(path: "private.ignored")), ignored)
        XCTAssertEqual(try Data(contentsOf: kept.appending(path: "late.ignored")), late)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: kept.deletingLastPathComponent().appending(path: "git-state/index").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked.path))
        XCTAssertTrue(remove.waitForNonExistence(timeout: 10))
        capture(app, "Removed registration keeps working files and Git state")
        app.buttons["worktree-cancel"].click()
        expectValue(draft, "Keep Main worktree draft")
        XCTAssertEqual(try git(["rev-parse", "refs/heads/topic"]), head)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: main.appending(path: ".git/index")), index)
        XCTAssertEqual(try git(["show", ":other"]), "already staged\n")
    }

    @MainActor private func openManager(_ app: XCUIApplication) {
        let more = app.descendants(matching: .any).matching(identifier: "toolbar-more").firstMatch
        XCTAssertTrue(more.exists || more.waitForExistence(timeout: 10))
        more.click()
        app.menuItems["worktree-management"].click()
        waitEnabled(app.buttons["worktree-create"])
    }
    @MainActor private func prepareCreation(_ app: XCUIApplication, path: String, branch: String) {
        app.buttons["worktree-create"].click()
        let field = app.textFields["worktree-destination"]
        XCTAssertTrue(field.exists || field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(path)
        let name = app.textFields["worktree-branch"]
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText(branch)
        waitEnabled(app.buttons["worktree-preview"])
        app.buttons["worktree-preview"].click()
    }
    @MainActor private func waitEnabled(_ element: XCUIElement) {
        if !element.exists || !element.isEnabled {
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in element.exists && element.isEnabled }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isEnabled)
    }
    @MainActor private func expectValue(_ element: XCUIElement, _ value: String) {
        if !element.exists || element.value as? String != value {
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in element.exists && element.value as? String == value },
                object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        }
        XCTAssertTrue(element.exists)
        XCTAssertEqual(element.value as? String, value)
    }
    private func id(_ url: URL) -> String {
        SHA256.hash(data: Data(url.resolvingSymlinksInPath().path.utf8)).map { String(format: "%02x", $0) }
            .joined()
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows["main"].screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
