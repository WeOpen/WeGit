import Darwin
import Foundation
import WeGitCore

private actor LoseTagReply: ProcessRunning {
    enum Mode { case pushReply, verificationLaunch }
    let mode: Mode
    private var pushed = false
    init(_ mode: Mode) { self.mode = mode }
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if pushed && mode == .verificationLaunch && request.arguments.contains("ls-remote") {
            pushed = false
            throw ProcessFailure.launch(ENOENT)
        }
        let result = try await ProcessRunner().run(request)
        if request.arguments.contains("push") {
            pushed = true
            if mode == .pushReply { throw ProcessFailure.timedOut }
        }
        return result
    }
}

@main struct TagChecks {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(
                Data(("Tag check failed: " + error.localizedDescription + "\n").utf8))
            if let error = error as? GitFailure {
                FileHandle.standardError.write(Data((error.details + "\n").utf8))
            }
            exit(1)
        }
    }
    static func run() async throws {
        var checks: [String] = []
        func check(_ name: String, _ value: Bool) throws {
            guard value else {
                throw NSError(domain: "WeGit.TagChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
            }
            checks.append(name)
        }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitTagChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GNUPGHOME"] = root.appending(path: "private-gnupg").path
        let engine = GitEngine(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: env)
        @discardableResult func git(_ args: [String], at directory: URL? = nil, input: Data? = nil)
            async throws -> Data
        {
            try await engine.run(args, in: directory ?? root, input: input).stdout
        }
        try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Tag Fixture"), ("user.email", "tag@example.invalid"), ("commit.gpgsign", "false"),
            ("tag.gpgsign", "false"), ("core.hooksPath", root.appending(path: "no-hooks").path),
        ] {
            try await git(["config", key, value])
        }
        let file = root.appending(path: "file")
        try Data("base\n".utf8).write(to: file)
        try await git(["add", "."])
        try await git(["commit", "-m", "Base"])
        let location = try await RepositoryService.discover(root, engine: engine)
        let service = RepositoryService(location: location, engine: engine)
        let first = try await service.head()!
        func create(_ name: String, kind: TagKind = .lightweight, message: String = "", target: String? = nil)
            async throws -> GitTag
        {
            let head = try await service.head()
            let plan = try await service.prepareTagCreation(
                name: name, target: target ?? head!, kind: kind, message: message, expectedHead: head)
            return try await service.createTag(plan)
        }
        let main = try await create("main")
        try check(
            "Lightweight tag can share the current branch name", main.targetCommit == first && !main.annotated
        )
        let named = try await create("发布/v1.1", kind: .annotated, message: "发布说明\n\n# keep heading\n中文内容\n")
        try check(
            "Annotated tag has a distinct object and the exact commit",
            named.annotated && named.objectID != first && named.targetCommit == first)
        let message = try await service.tagMessage(named)
        try check(
            "Annotation preserves Unicode and explicit headings",
            message?.contains("中文内容") == true && message?.contains("# keep heading") == true)
        try check(
            "Nested name search is literal and Unicode aware",
            try await service.tags(query: "发布/").entries == [named])
        try check(
            "Wildcard search text does not become a ref glob",
            try await service.tags(query: "*").entries.isEmpty)
        let page = try await service.tags(limit: 1)
        try check("Tag listing exposes pagination", page.entries.count == 1 && page.hasMore)
        var duplicate = false
        do { _ = try await create("main") } catch ModelFailure.changed { duplicate = true }
        let mainAfterDuplicate = try await service.tags(query: "main").entries.first?.objectID
        try check(
            "Same-name creation refuses replacement",
            duplicate && mainAfterDuplicate == first)
        try await git(["symbolic-ref", "refs/tags/dangling", "refs/heads/missing"])
        var alias = false
        do { _ = try await create("dangling") } catch ModelFailure.changed { alias = true }
        try check("A dangling symbolic tag is not mistaken for an absent name", alias)
        try await git(["symbolic-ref", "--delete", "refs/tags/dangling"])
        try Data("next\n".utf8).write(to: file)
        try await git(["add", "file"])
        try await git(["commit", "-m", "Next"])
        let head = try await service.head()!
        let changing = try await create("changed", target: first)
        try await git(["update-ref", changing.reference, head])
        var staleDelete = false
        do { try await service.deleteTag(changing, expectedHead: head) } catch ModelFailure.changed {
            staleDelete = true
        }
        try check("Deletion refuses a tag retargeted outside the app", staleDelete)
        try check(
            "Rejected deletion preserves the new target",
            String(decoding: try await git(["rev-parse", changing.reference]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == head)
        try await service.deleteTag(main, expectedHead: head)
        try check("Deleting same-name tag preserves the branch and HEAD", try await service.head() == head)
        try check("Only the local tag is deleted", try await service.tags(query: "main").entries.isEmpty)
        try await git(["symbolic-ref", "refs/tags/alias", "refs/heads/main"])
        let symbolic = try await service.tags(query: "alias").entries.first!
        var symbolicRejected = false
        do { try await service.deleteTag(symbolic, expectedHead: head) } catch ModelFailure.unsupported {
            symbolicRejected = true
        }
        let headAfterSymbolicDelete = try await service.head()
        try check(
            "Symbolic tag deletion cannot delete its branch",
            symbolicRejected && headAfterSymbolicDelete == head)
        try await git(["symbolic-ref", "--delete", "refs/tags/alias"])
        let pending = try await service.prepareTagCreation(
            name: "stale-config", target: head, kind: .lightweight, expectedHead: head)
        try await git(["config", "tag.sort", "version:refname"])
        var staleConfig = false
        do { _ = try await service.createTag(pending) } catch ModelFailure.changed { staleConfig = true }
        try check("External configuration changes invalidate tag creation", staleConfig)
        let bare = location.gitDirectory.appending(path: "tag-remote.git")
        try await git(["init", "--bare", bare.path])
        let remotes = try await service.remoteManagement()
        try await service.changeRemote(
            .add(name: "origin", fetchURL: bare.path, pushURL: nil), in: remotes, expectedHead: head)
        let branchPlan = try await service.preparePush(remote: "origin", branch: "main", expectedHead: head)
        _ = try await service.push(branchPlan)
        try await git(["config", "push.followTags", "true"])
        try await git(["config", "remote.origin.mirror", "true"])
        _ = try await create("hidden", kind: .annotated, message: "Do not push this tag", target: first)
        let selected = try await create("publish-one", target: first)
        let push = try await service.prepareTagPush(selected, remote: "origin", expectedHead: head)
        _ = try await service.pushTag(push)
        let remoteTags = try await git(["for-each-ref", "--format=%(refname)", "refs/tags/"], at: bare)
        try check(
            "Single-tag push ignores followTags and mirror defaults",
            remoteTags == Data("refs/tags/publish-one\n".utf8))
        try check(
            "Tag push leaves the remote branch unchanged",
            String(decoding: try await git(["rev-parse", "refs/heads/main"], at: bare), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == head)
        if case .alreadyPresent = try await service.pushTag(push) {
            try check("An already-present object is verified without replacement", true)
        } else {
            try check("An already-present object is verified without replacement", false)
        }
        let conflictPlan = try await service.prepareTagPush(named, remote: "origin", expectedHead: head)
        let alternate = try await create(
            "alternate", kind: .annotated, message: "Another annotation", target: first)
        _ = try await engine.run(
            ["push", "--porcelain", "--", "origin", alternate.objectID + ":" + named.reference], in: root,
            configuration: [("remote.origin.mirror", "false"), ("push.followTags", "false")])
        var conflict = false
        do {
            _ = try await service.prepareTagPush(named, remote: "origin", expectedHead: head)
        } catch ModelFailure.unsupported { conflict = true }
        try check("A different annotation of the same commit is a remote conflict", conflict)
        var stalePush = false
        do { _ = try await service.pushTag(conflictPlan) } catch ModelFailure.changed { stalePush = true }
        try check("A changed remote tag invalidates an old confirmation", stalePush)
        try check(
            "Published conflicting object is never moved",
            String(decoding: try await git(["rev-parse", named.reference], at: bare), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == alternate.objectID)
        for (index, mode) in [LoseTagReply.Mode.pushReply, .verificationLaunch].enumerated() {
            let tag = try await create("uncertain-\(index)")
            let plan = try await service.prepareTagPush(tag, remote: "origin", expectedHead: head)
            let failing = RepositoryService(
                location: location,
                engine: GitEngine(
                    executable: URL(fileURLWithPath: "/usr/bin/git"), runner: LoseTagReply(mode),
                    environment: env))
            var unknown = false
            do { _ = try await failing.pushTag(plan) } catch is TagPushOutcomeUnknown { unknown = true }
            try check("Lost reply or post-push verification is reported as unknown \(index)", unknown)
            if case .matches = try await service.verifyTagPush(plan) {
                try check("Unknown tag push can be verified by the tag object \(index)", true)
            } else {
                try check("Unknown tag push can be verified by the tag object \(index)", false)
            }
        }
        try await git(["config", "tag.gpgSign", "true"])
        var signingGuard = false
        do {
            _ = try await service.prepareTagCreation(
                name: "unsigned", target: head, kind: .lightweight, expectedHead: head)
        } catch ModelFailure.unsupported { signingGuard = true }
        try check("Lightweight creation cannot silently override configured signing", signingGuard)
        try await git(["config", "gpg.format", "openpgp"])
        try await git(["config", "gpg.program", root.appending(path: "missing-signer").path])
        let signedPlan = try await service.prepareTagCreation(
            name: "signing-failure", target: head, kind: .annotated, message: "Must sign", expectedHead: head)
        var signingFailed = false
        do { _ = try await service.createTag(signedPlan) } catch { signingFailed = true }
        let signingFailureTags = try await service.tags(query: "signing-failure")
        try check(
            "Missing configured signer fails without creating a tag",
            signingFailed && signingFailureTags.entries.isEmpty)
        try check(
            "Signing failure preserves HEAD and worktree bytes",
            try await service.head() == head && Data(contentsOf: file) == Data("next\n".utf8))
        try await git(["config", "tag.gpgSign", "false"])
        for name in ["", "-flag", "bad..name", "bad name", "bad@{x"] {
            var rejected = false
            do {
                _ = try await service.prepareTagCreation(
                    name: name, target: head, kind: .lightweight, expectedHead: head)
            } catch { rejected = true }
            try check("Invalid tag name is rejected: " + name, rejected)
        }
        let commands = (0..<300).map { "create refs/tags/bulk/\(String(format:"%04d",$0)) \(head)\n" }
            .joined()
        try await git(["update-ref", "--stdin"], input: Data(commands.utf8))
        let large = try await service.tags(query: "BULK/0", limit: 25)
        try check(
            "Filtering reaches nested names beyond a first display page",
            large.entries.count == 25 && large.hasMore)
        var timings: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            _ = try await service.tags(query: "bulk/01", limit: 25)
            let t = start.duration(to: .now).components
            timings.append(Double(t.seconds) * 1000 + Double(t.attoseconds) / 1e15)
        }
        let sorted = timings.sorted()
        let metrics: [String: Any] = [
            "samplesMs": timings, "samples": 30,
            "tagCount": try await service.tags(limit: 1000).entries.count, "medianMs": sorted[15],
            "p95Ms": sorted[28],
        ]
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted]).write(
            to: output.deletingLastPathComponent().appending(path: "performance.json"))
        try check("Tag query p95 stays within the two-second read budget", sorted[28] < 2000)
        try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted]).write(to: output)
        print("\(checks.count) isolated tag checks passed.")
    }
}
