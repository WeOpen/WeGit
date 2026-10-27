import Foundation
import WeGitCore

private actor BlameGate {
    var entered = false
    func enter() { entered = true }
}

private struct DelayedBlameRunner: ProcessRunning {
    let gate: BlameGate
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        if request.arguments.contains("blame") {
            await gate.enter()
            try await Task.sleep(for: .seconds(30))
        }
        return try await ProcessRunner().run(request)
    }
}

@main struct BlameChecks {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("Blame check failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        var checks: [String] = []
        var samples: [String: [Double]] = [:]
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        func save(_ completed: Bool) throws {
            try JSONSerialization.data(
                withJSONObject: [
                    "completed": completed, "passed": checks.count, "checks": checks,
                    "milliseconds": samples, "xctestExecuted": false,
                    "backendBudgetMilliseconds": 2000, "applicationPerformanceAcceptance": false,
                ],
                options: [.prettyPrinted, .sortedKeys]
            ).write(to: output)
        }
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else {
                throw NSError(domain: "BlameChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
            }
            checks.append(name)
            print("PASS: " + name)
            try save(false)
        }
        func rejected(_ operation: () async throws -> Void) async -> Bool {
            do {
                try await operation()
                return false
            } catch { return true }
        }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitBlameChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let engine = GitEngine(environment: environment)
        @discardableResult func git(_ args: [String]) async throws -> String {
            try await engine.run(args, in: root).text.trimmingCharacters(in: .newlines)
        }
        func write(_ path: String, _ bytes: Data) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        func commit(_ message: String) async throws -> String {
            try await git(["add", "-A"])
            try await git(["commit", "-m", message])
            return try await git(["rev-parse", "HEAD"])
        }
        try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "First Author"), ("user.email", "first@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", root.appending(path: "no-hooks").path),
        ] {
            try await git(["config", key, value])
        }
        let original = "中文\n[origin]\\file.txt"
        let renamed = "renamed\n\"file.txt"
        try write(original, Data("first\r\nsecond\r\nlast".utf8))
        let first = try await commit("Original lines")
        try await git(["config", "user.name", "Second Author"])
        try await git(["config", "user.email", "second@example.invalid"])
        try write(original, Data("first\r\nchanged\r\nlast".utf8))
        let second = try await commit("Change the middle line")
        try await git(["mv", original, renamed])
        let tip = try await commit("Rename")
        let service = try await RepositoryService(
            location: RepositoryService.discover(root, engine: engine), engine: engine)
        try write(renamed, Data("uncommitted working bytes\n".utf8))
        try write(
            ".mailmap",
            Data("Mapped Author <mapped@example.invalid> First Author <first@example.invalid>\n".utf8))
        try write(".git/ignored-revisions", Data((second + "\n").utf8))
        try await git(["config", "blame.ignoreRevsFile", root.appending(path: ".git/ignored-revisions").path])
        let index = try Data(contentsOf: root.appending(path: ".git/index"))
        let document = try await service.blameDocument(path: renamed, revision: tip)
        try check("Fixed blob line count respects CRLF and missing final newline", document.lineCount == 3)
        let page = try await service.blamePage(document, count: 2)
        try check("First page has exact destination line numbers", page.lines.map(\.number) == [1, 2])
        try check(
            "Attribution preserves each original author and commit",
            page.lines.map { $0.commit.id } == [first, second])
        try check(
            "Current mailmap cannot rewrite historical author metadata",
            page.lines[0].commit.author == "First Author")
        try check(
            "Configured ignored revisions do not alter explicit attribution",
            page.lines[1].commit.id == second)
        try check(
            "C-quoted Unicode, newline and backslash paths decode exactly",
            page.lines.allSatisfy { $0.originalPath.utf8.elementsEqual(original.utf8) })
        try check(
            "Returned text is the committed blob, including CR bytes",
            page.lines.map(\.content) == ["first\r", "changed\r"])
        try check(
            "A page cursor reports the next unread line", page.nextLine == 3 && page.previousLine == nil)
        let last = try await service.blamePage(document, firstLine: 3, count: 2)
        try check(
            "Last page preserves root attribution and exact EOF text",
            last.lines.count == 1 && last.lines[0].commit.id == first && last.lines[0].content == "last"
                && last.nextLine == nil)
        try check(
            "Reads preserve HEAD and raw index",
            try await service.head() == tip && Data(contentsOf: root.appending(path: ".git/index")) == index)
        try check(
            "Reads preserve uncommitted working bytes",
            try Data(contentsOf: root.appending(path: renamed)) == Data("uncommitted working bytes\n".utf8))
        try check(
            "Oversized page requests are rejected",
            await rejected { _ = try await service.blamePage(document, count: 201) })
        try check(
            "Out-of-range page requests are rejected",
            await rejected { _ = try await service.blamePage(document, firstLine: 4) })
        try await git(["rm", "-f", renamed])
        let deleted = try await commit("Delete")
        try check(
            "A fixed historical document survives later deletion",
            try await service.blamePage(document).lines.count == 3)
        try check(
            "A deleted version does not borrow working-tree line numbers",
            await rejected { _ = try await service.blameDocument(path: renamed, revision: deleted) })

        for (name, bytes) in [
            ("empty", Data()), ("binary", Data([0, 1, 2])),
            ("non-utf8", Data([0xFF, 0xFE])),
            ("long-line", Data(repeating: 97, count: BlameReadBudget.lineBytes + 1)),
            ("too-many-lines", Data(repeating: 10, count: BlameReadBudget.lines + 1)),
            ("oversized", Data(repeating: 97, count: BlameReadBudget.bytes + 1)),
        ] {
            try write(name, bytes)
        }
        let bounded = try await commit("Read bounds")
        let empty = try await service.blameDocument(path: "empty", revision: bounded)
        try check(
            "Empty committed files have an empty page", try await service.blamePage(empty).lines.isEmpty)
        for name in ["binary", "non-utf8", "long-line", "too-many-lines", "oversized"] {
            try check(
                "Reject unsupported content: " + name,
                await rejected { _ = try await service.blameDocument(path: name, revision: bounded) })
        }
        let gate = BlameGate()
        let delayed = RepositoryService(
            location: service.location,
            engine: GitEngine(runner: DelayedBlameRunner(gate: gate), environment: environment))
        let pending = Task { try await delayed.blamePage(document) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.entered), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try check("Cancellation reaches a running blame query", await gate.entered)
        let cancelStart = ContinuousClock.now
        pending.cancel()
        try check("Cancelled reads cannot return a late page", await rejected { _ = try await pending.value })
        let cancellation = cancelStart.duration(to: .now).components
        samples["cancellation"] = [
            Double(cancellation.seconds) * 1000 + Double(cancellation.attoseconds) / 1e15
        ]

        let largeText = (1...5000).map { "line \($0) = value\n" }.joined()
        try write("large.txt", Data(largeText.utf8))
        let largeTip = try await commit("Large blame fixture")
        let large = try await service.blameDocument(path: "large.txt", revision: largeTip)
        try check("Large documents are paged without losing their full line count", large.lineCount == 5000)
        try check(
            "A distant page remains anchored to its original line range",
            try await service.blamePage(large, firstLine: 4801).lines.map(\.number) == Array(4801...5000))
        let bare = root.appending(path: ".git/read-boundaries/origin.git")
        let partial = root.appending(path: ".git/read-boundaries/partial")
        try FileManager.default.createDirectory(
            at: bare.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git(["clone", "--bare", "--no-local", root.path, bare.path])
        try await git(["-C", bare.path, "config", "uploadpack.allowFilter", "true"])
        try await git(["clone", "--filter=blob:none", "--no-checkout", bare.absoluteString, partial.path])
        var offline = engine
        offline.environment["GIT_NO_LAZY_FETCH"] = "1"
        let absent = try await offline.run(
            ["cat-file", "-e", large.blob], in: partial, accepted: [0, 1, 128])
        try check("Partial clone fixture has no content blob", absent.exitCode != 0)
        let partialService = try await RepositoryService(
            location: RepositoryService.discover(partial, engine: engine), engine: engine)
        try check(
            "Missing blobs require explicit fetch instead of automatic retrieval",
            await rejected {
                _ = try await partialService.blameDocument(path: "large.txt", revision: largeTip)
            })
        let stillAbsent = try await offline.run(
            ["cat-file", "-e", large.blob], in: partial, accepted: [0, 1, 128])
        try check("Read failure leaves the content blob unfetched", stillAbsent.exitCode != 0)
        for _ in 0..<30 {
            var start = ContinuousClock.now
            let fresh = try await service.blameDocument(path: "large.txt", revision: largeTip)
            _ = try await service.blamePage(fresh)
            var duration = start.duration(to: .now).components
            samples["documentAndFirstPage", default: []].append(
                Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            start = .now
            _ = try await service.blamePage(fresh, firstLine: 201)
            duration = start.duration(to: .now).components
            samples["nextPage", default: []].append(
                Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        }
        try save(false)
        try check(
            "Thirty first reads and page reads meet the 2000 ms backend budget",
            samples.filter { $0.key != "cancellation" }.values.allSatisfy { $0.sorted()[28] <= 2000 })
        try save(true)
    }
}
