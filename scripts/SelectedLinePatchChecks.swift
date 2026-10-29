import Foundation
import WeGitCore

@main struct SelectedLineProbe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitSelectedProbe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        let engine = GitEngine(environment: env)
        @discardableResult func git(_ args: [String], input: Data? = nil) async throws -> ProcessResult {
            try await engine.run(args, in: root, input: input)
        }
        try await git(["init", "-b", "main"])
        for (key, value) in [
            ("user.name", "Tester"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false"),
            ("core.hooksPath", root.appending(path: "no-hooks").path),
        ] {
            try await git(["config", key, value])
        }
        let file = root.appending(path: "file")
        try Data("a\nb\nc\nd\n".utf8).write(to: file)
        try await git(["add", "file"])
        try await git(["commit", "-m", "Base"])
        try Data("a\nB\nC\nd\n".utf8).write(to: file)
        let service = try await RepositoryService(
            location: RepositoryService.discover(root, engine: engine), engine: engine)
        let forward: [[String]] = [
            [], ["c"], ["b"], [], ["B", "b", "c"], ["B", "c"], ["b", "B"], ["B"], ["C", "b", "c"],
            ["C", "c"], ["b", "C"], ["C"], ["B", "C", "b", "c"], ["B", "C", "c"], ["b", "B", "C"],
            ["B", "C"],
        ]
        let reverse: [[String]] = [
            [], ["b", "B", "C"], ["c", "B", "C"], ["b", "c", "B", "C"], ["C"], ["b", "C"], ["c", "C"],
            ["b", "c", "C"], ["B"], ["B", "b"], ["B", "c"], ["B", "b", "c"], [], ["b"], ["c"], ["b", "c"],
        ]
        var passed = 0
        for context in [0, 3] {
            for layer in [DiffLayer.unstaged, .staged] {
                for mask in 1...15 {
                    try await git(["reset", "-q", "HEAD", "--", "file"])
                    if layer == .staged { try await git(["add", "file"]) }
                    let diff = try await service.diff(
                        path: "file", layer: layer, options: DiffReadOptions(contextLines: context))
                    let allLines: [DiffLine] = diff.hunks.flatMap { $0.lines }
                    let pairs: [(Character, String)] = [("-", "b"), ("-", "c"), ("+", "B"), ("+", "C")]
                    let matching = allLines.filter { line in
                        pairs.enumerated().contains { index, pair in
                            mask & (1 << index) != 0 && line.kind == pair.0 && line.content == pair.1
                        }
                    }
                    let ids = Set(matching.map { $0.id })
                    guard ids.count == mask.nonzeroBitCount else { throw ModelFailure.changed }
                    let current = try await git(["show", ":file"]).stdout
                    let calculated = try SelectedLinePatch.expectedIndex(
                        diff: diff, lineIDs: ids, current: current)
                    let patch = try SelectedLinePatch.make(diff: diff, lineIDs: ids)
                    let indexBefore = try Data(contentsOf: root.appending(path: ".git/index"))
                    let plan = try await service.prepareSelectedLines(diff: diff, lineIDs: ids)
                    guard plan.patch == patch,
                        try Data(contentsOf: root.appending(path: ".git/index")) == indexBefore
                    else { throw ModelFailure.changed }
                    try await service.executeSelectedLines(plan)
                    let actual = try await git(["show", ":file"]).stdout
                    let middle = layer == .staged ? reverse[mask] : forward[mask]
                    let expected = Data((["a"] + middle + ["d"]).map { $0 + "\n" }.joined().utf8)
                    guard actual == expected, calculated == expected,
                        try Data(contentsOf: file) == Data("a\nB\nC\nd\n".utf8)
                    else {
                        print(
                            "FAIL", context, layer, mask,
                            String(decoding: patch, as: UTF8.self).debugDescription,
                            String(decoding: actual, as: UTF8.self).debugDescription,
                            String(decoding: expected, as: UTF8.self).debugDescription)
                        fflush(stdout)
                        throw ModelFailure.changed
                    }
                    passed += 1
                }
            }
        }
        let variants: [(String, String)] = [
            ("a\r\nold\r\nx", "a\r\nnew\r\nx"),
            ("a\nold", "a\nnew"),
            (
                "é\nleft\nunchanged1\nunchanged2\nunchanged3\nunchanged4\nunchanged5\nold-end\n",
                "é\nright\nunchanged1\nunchanged2\nunchanged3\nunchanged4\nunchanged5\nnew-end\n"
            ),
        ]
        for (number, pair) in variants.enumerated() {
            try Data(pair.0.utf8).write(to: file)
            try await git(["add", "file"])
            try await git(["commit", "-m", "Variant \(number)"])
            try Data(pair.1.utf8).write(to: file)
            for context in [0, 3] {
                for layer in [DiffLayer.unstaged, .staged] {
                    try await git(["reset", "-q", "HEAD", "--", "file"])
                    if layer == .staged { try await git(["add", "file"]) }
                    let diff = try await service.diff(
                        path: "file", layer: layer, options: DiffReadOptions(contextLines: context))
                    let allLines: [DiffLine] = diff.hunks.flatMap { $0.lines }
                    let ids = Set(allLines.filter { $0.kind == "+" || $0.kind == "-" }.map { $0.id })
                    let current = try await git(["show", ":file"]).stdout
                    let calculated = try SelectedLinePatch.expectedIndex(
                        diff: diff, lineIDs: ids, current: current)
                    let patch = try SelectedLinePatch.make(diff: diff, lineIDs: ids)
                    let indexBefore = try Data(contentsOf: root.appending(path: ".git/index"))
                    let plan = try await service.prepareSelectedLines(diff: diff, lineIDs: ids)
                    guard plan.patch == patch,
                        try Data(contentsOf: root.appending(path: ".git/index")) == indexBefore
                    else { throw ModelFailure.changed }
                    try await service.executeSelectedLines(plan)
                    let actual = try await git(["show", ":file"]).stdout
                    let expected = Data((layer == .staged ? pair.0 : pair.1).utf8)
                    guard actual == expected, calculated == expected,
                        try Data(contentsOf: file) == Data(pair.1.utf8)
                    else {
                        print(
                            "VARIANT FAILED", number, context, layer,
                            String(decoding: patch, as: UTF8.self).debugDescription,
                            String(decoding: actual, as: UTF8.self).debugDescription)
                        fflush(stdout)
                        throw ModelFailure.changed
                    }
                    passed += 1
                }
            }
        }
        print("PASS", passed, "selections including CRLF, no final newline, Unicode, and separated hunks")
    }
}
