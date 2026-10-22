import Foundation
import WeGitCore

private enum Failed: Error { case check(String) }

@main struct FileHistoryChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitFileHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys) where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let engine = GitEngine(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: env)
        @discardableResult func git(_ args: [String], input: Data? = nil) async throws -> String {
            let value = try await engine.run(args, in: root, input: input, timeout: 120).text
            return value.hasSuffix("\n") ? String(value.dropLast()) : value
        }
        var checks: [String] = []
        func check(_ name: String, _ condition: Bool) throws {
            guard condition else { throw Failed.check(name) }
            checks.append(name)
        }
        try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Alice [literal]"), ("user.email", "alice@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", root.appending(path: "no-hooks").path),
        ] {
            try await git(["config", key, value])
        }
        let old = "旧名\n[1].txt"
        let new = "新名\n[1].txt"
        func write(_ path: String, _ value: String) throws {
            try Data(value.utf8).write(to: root.appending(path: path))
        }
        func commit(_ message: String, date: String) async throws -> String {
            try await git(["add", "--all"])
            var dated = engine
            dated.environment["GIT_AUTHOR_DATE"] = date
            dated.environment["GIT_COMMITTER_DATE"] = date
            _ = try await dated.run(["commit", "-m", message], in: root)
            return try await git(["rev-parse", "HEAD"])
        }
        try write(old, "one\ntwo\nthree\nfour\n")
        let first = try await commit("Initial [literal]", date: "2025-01-01T12:00:00Z")
        try write(old, "one\ntwo\nthree\nfour\nfive\n")
        let modified = try await commit("Modify old", date: "2025-01-02T12:00:00Z")
        try await git(["mv", "--", old, new])
        let renamed = try await commit("Rename only", date: "2025-01-03T12:00:00Z")
        try await git(["config", "user.name", "Bob"])
        try write(new, "one\ntwo\nthree\nfour\nfive\nsix\n")
        let newer = try await commit("Modify new", date: "2025-01-04T12:00:00Z")
        try await git(["rm", "--", new])
        let deleted = try await commit("Delete file", date: "2025-01-05T12:00:00Z")
        let location = try await RepositoryService.discover(root, engine: engine)
        let service = RepositoryService(location: location, engine: engine)
        let anchor = try await service.fileHistoryAnchor(FileHistoryQuery(path: new))
        var entries: [FileHistoryEntry] = []
        var cursor: FileHistoryCursor?
        repeat {
            let page = try await service.fileHistoryPage(anchor, after: cursor, count: 2)
            entries += page.entries
            cursor = page.next
        } while cursor != nil
        FileHandle.standardError.write(
            Data(
                "Observed file history: \(entries.map { $0.commit.subject + ":" + $0.path.debugDescription })\n"
                    .utf8))
        try check(
            "Pagination follows modify, rename and deletion without duplicates",
            entries.map { $0.commit.id } == [deleted, newer, renamed, modified, first])
        try check(
            "Each historical filename is retained including newline and Unicode",
            entries.map(\.path) == [new, new, new, old, old])
        try check(
            "Rename entry preserves both exact paths", entries[2].oldPath == old && entries[2].status == "R")
        let deletion = try await service.commitComparison(id: deleted, paths: [new])
        try check(
            "Deleted file diff uses its real parent and removal status",
            deletion.parent == newer && deletion.files.first?.status == "D")
        let renameDiff = try await service.commitComparison(id: renamed, paths: [old, new])
        try check(
            "Rename diff uses the old/new paths instead of a current worktree file",
            renameDiff.files.first?.oldPath == old && renameDiff.files.first?.path == new)
        let noFollow = try await service.fileHistoryAnchor(FileHistoryQuery(path: new, followRenames: false))
        try check(
            "Rename following can be disabled",
            try await service.fileHistoryPage(noFollow).entries.map { $0.commit.id } == [
                deleted, newer, renamed,
            ])
        let author = try await service.fileHistoryAnchor(
            FileHistoryQuery(path: new, author: "Alice [literal]"))
        try check(
            "Literal author filter still reaches history before the rename",
            try await service.fileHistoryPage(author).entries.map { $0.commit.id } == [
                renamed, modified, first,
            ])
        let message = try await service.fileHistoryAnchor(FileHistoryQuery(path: new, message: "[literal]"))
        try check(
            "Literal message filtering tracks an excluded rename",
            try await service.fileHistoryPage(message).entries.map { $0.commit.id } == [first])
        let date = ISO8601DateFormatter()
        let dated = try await service.fileHistoryAnchor(
            FileHistoryQuery(
                path: new, since: date.date(from: "2025-01-02T00:00:00Z"),
                until: date.date(from: "2025-01-03T23:59:59Z")))
        try check(
            "Date bounds use commit time and preserve rename traversal",
            try await service.fileHistoryPage(dated).entries.map { $0.commit.id } == [renamed, modified])
        let fresh = try await service.fileHistoryAnchor(FileHistoryQuery(path: new))
        let firstPage = try await service.fileHistoryPage(anchor, count: 1)
        var staleCursor = false
        do {
            _ = try await service.fileHistoryPage(fresh, after: firstPage.next, count: 1)
        } catch ModelFailure.changed { staleCursor = true }
        try check("A cursor cannot cross query snapshots", staleCursor)
        try write("unrelated", "another\n")
        _ = try await commit("Outside query", date: "2025-01-06T12:00:00Z")
        try check(
            "External HEAD movement does not shift an anchored page",
            try await service.fileHistoryPage(anchor).entries.map { $0.commit.id }
                == entries.map { $0.commit.id })
        let empty = try await service.fileHistoryAnchor(FileHistoryQuery(path: "not-present"))
        try check(
            "A nonexistent file has an empty result", try await service.fileHistoryPage(empty).entries.isEmpty
        )
        var bad = false
        do { _ = try await service.fileHistoryAnchor(FileHistoryQuery(path: "../outside")) } catch {
            bad = true
        }
        try check("Parent traversal cannot become a path argument", bad)
        try await git(["switch", "-c", "feature", newer])
        try write(new, "one\ntwo\nthree\nfour\nfive\nsix\nfeature\n")
        let feature = try await commit("Feature edit", date: "2025-01-07T12:00:00Z")
        try await git(["switch", "-c", "merge-main", newer])
        try write("other", "side\n")
        let parent = try await commit("Unrelated parent", date: "2025-01-08T12:00:00Z")
        try await git(["merge", "--no-ff", "feature", "-m", "Merged feature"])
        let merge = try await git(["rev-parse", "HEAD"])
        let merged = try await service.fileHistoryAnchor(FileHistoryQuery(path: new))
        let mergePage = try await service.fileHistoryPage(merged)
        try check(
            "Merge history retains both integration and feature commits",
            mergePage.entries.contains { $0.commit.id == merge }
                && mergePage.entries.contains { $0.commit.id == feature })
        let comparison = try await service.commitComparison(id: merge, paths: [new])
        try check(
            "Merge file comparison uses the actual first parent",
            comparison.parent == parent && comparison.files.map(\.path) == [new])
        try Data([0, 1, 2, 3]).write(to: root.appending(path: "binary"))
        let binary = try await commit("Binary", date: "2025-01-09T12:00:00Z")
        let binaryComparison = try await service.commitComparison(id: binary, paths: ["binary"])
        try check(
            "Binary history uses the existing binary diff state", binaryComparison.files.first?.binary == true
        )
        var stream = ""
        for index in 1...5000 {
            let body = "Scale \(index)"
            let contents = "Value \(index)\n"
            stream +=
                "commit refs/heads/scale\ncommitter Scale <scale@example.invalid> \(1_700_000_000 + index) +0000\ndata \(body.utf8.count)\n\(body)\nM 100644 inline scale.txt\ndata \(contents.utf8.count)\n\(contents)\n"
        }
        try await git(["fast-import", "--quiet"], input: Data(stream.utf8))
        let scaleTip = try await git(["rev-parse", "refs/heads/scale"])
        let scale = try await service.fileHistoryAnchor(FileHistoryQuery(path: "scale.txt"), tip: scaleTip)
        var times: [Double] = []
        var baseline: [Double] = []
        try await git(["switch", "scale"])
        func ms(_ start: ContinuousClock.Instant) -> Double {
            let value = start.duration(to: .now).components
            return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
        }
        var boundedPages = true
        for _ in 0..<30 {
            var start = ContinuousClock.now
            let freshScale = try await service.fileHistoryAnchor(
                FileHistoryQuery(path: "scale.txt"), tip: scaleTip)
            let page = try await service.fileHistoryPage(freshScale)
            times.append(ms(start))
            boundedPages = boundedPages && page.entries.count == 100 && page.next != nil
            start = .now
            let history = try await service.historyAnchor(scope: .currentBranch)
            _ = try await service.historyPage(history, count: 100)
            baseline.append(ms(start))
        }
        try check("All scale samples return one bounded page", boundedPages)
        var scaleCursor: FileHistoryCursor?
        var allScale: [String] = []
        repeat {
            let page = try await service.fileHistoryPage(scale, after: scaleCursor, count: 200)
            allScale += page.entries.map(\.id)
            scaleCursor = page.next
        } while scaleCursor != nil
        try check(
            "All five thousand records paginate exactly once",
            allScale.count == 5000 && Set(allScale).count == 5000)
        try check("Five thousand commit file query p95 meets two-second budget", times.sorted()[28] < 2000)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
        try JSONSerialization.data(
            withJSONObject: [
                "samples": 30, "historyCommits": 5000, "fileHistoryMs": times, "existingHistoryMs": baseline,
                "fileHistoryP95Ms": times.sorted()[28], "existingHistoryP95Ms": baseline.sorted()[28],
            ], options: [.prettyPrinted, .sortedKeys]
        ).write(to: directory.appending(path: "performance.json"))
        try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted]).write(
            to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("\(checks.count) isolated file history checks passed.")
    }
}
