import Foundation
import WeGitCore

@main struct ChangeFileTreeChecks {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(
                Data("Change list check failed: \(error.localizedDescription)\n".utf8))
            if let failure = error as? GitFailure {
                FileHandle.standardError.write(Data((failure.details + "\n").utf8))
            }
            exit(1)
        }
    }

    private static func run() async throws {
        var passed: [String] = []
        func check(_ title: String, _ value: Bool) throws {
            guard value else {
                throw NSError(
                    domain: "WeGit.ChangeList", code: 1, userInfo: [NSLocalizedDescriptionKey: title])
            }
            passed.append(title)
        }
        let paths = [
            "root.txt", "src/a.swift", "src/nested/b.swift", "docs/note.md", "src/a\nline.txt", ":(glob)*",
        ]
        let files = try StatusParser.parse(Data(paths.map { "? " + $0 + "\0" }.joined().utf8)).files
        let rows = ChangeFileTree.rows(files)
        try check("Tree retains all exact file paths", Set(rows.compactMap { $0.file?.path }) == Set(paths))
        try check("Folder rows sort before root files", rows.first?.path == "docs" && rows.first?.file == nil)
        try check(
            "Nested file depth is preserved", rows.first { $0.path == "src/nested/b.swift" }?.depth == 2)
        try check("Root files retain depth zero", rows.first { $0.path == "root.txt" }?.depth == 0)
        try check("Row identities are unique", Set(rows.map(\.id)).count == rows.count)
        let src = rows.first { $0.id == "folder:src" }!
        try check(
            "Folder operations carry files, never the directory path",
            Set(src.files.map(\.path)) == Set(paths.filter { $0.hasPrefix("src/") }))
        let folded = ChangeFileTree.rows(files, collapsedFolders: ["src"])
        try check(
            "Collapsing a folder hides its descendants",
            !folded.contains { $0.file?.path.hasPrefix("src/") == true })
        try check(
            "Collapsing preserves the folder operation scope",
            folded.first { $0.id == "folder:src" }?.files.count == 3)
        try check("Unrelated folders stay expanded", folded.contains { $0.file?.path == "docs/note.md" })
        try check(
            "Nested collapse leaves direct children visible",
            ChangeFileTree.rows(files, collapsedFolders: ["src/nested"]).contains {
                $0.file?.path == "src/a.swift"
            })
        let filtered = files.filter { ChangeFilter(query: "b.swift").matches($0, layer: .untracked) }
        try check(
            "Filtered folders contain only matching files",
            ChangeFileTree.rows(filtered).first?.files.map(\.path) == ["src/nested/b.swift"])
        let collision = try StatusParser.parse(Data("? src\0? src/a.swift\0".utf8)).files
        try check(
            "A deleted-file/new-folder name collision keeps distinct identities",
            Set(ChangeFileTree.rows(collision).map(\.id)).count == 3)
        try check("Empty input makes an empty tree", ChangeFileTree.rows([]).isEmpty)
        try check(
            "Input order does not affect display ordering",
            ChangeFileTree.rows(files.reversed()).map(\.id) == rows.map(\.id))

        let root = FileManager.default.temporaryDirectory.appending(
            path: "WeGitChangeList-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        func git(_ arguments: [String]) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "core.hooksPath=" + root.appending(path: "no-hooks").path] + arguments
            process.currentDirectoryURL = root
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ModelFailure.changed }
            return data
        }
        _ = try git(["init", "-b", "main"])
        let fixturePaths = ["src/one.swift", "src/two.swift", "docs/note.md"]
        for path in fixturePaths {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("before\n".utf8).write(to: url)
        }
        _ = try git(["add", "."])
        _ = try git([
            "-c", "user.name=UI Fixture", "-c", "user.email=fixture@example.invalid", "-c",
            "commit.gpgSign=false", "commit", "-m", "Fixture",
        ])
        for path in fixturePaths { try Data("after\n".utf8).write(to: root.appending(path: path)) }
        try Data("new\n".utf8).write(to: root.appending(path: "src/new.swift"))
        let engine = GitEngine(environment: environment)
        let location = try await RepositoryService.discover(root, engine: engine)
        let service = RepositoryService(location: location, engine: engine)
        var state = try await service.status()
        let head = state.head
        let one = state.files.filter { ChangeFilter(query: "one.swift").matches($0, layer: .unstaged) }
        try await service.stage(paths: one.map(\.path), expectedHead: head)
        state = try await service.status()
        try check(
            "Filtered group staging leaves hidden files unstaged",
            state.files.filter(\.staged).map(\.path) == ["src/one.swift"])
        try Data("third\n".utf8).write(to: root.appending(path: "src/one.swift"))
        state = try await service.status()
        try check(
            "Partially staged files remain in both layers",
            state.files.first { $0.path == "src/one.swift" }?.layers == [.staged, .unstaged])
        let unstaged = state.files.filter { ChangeFilter().matches($0, layer: .unstaged) }
        let folderFiles = ChangeFileTree.rows(unstaged).first { $0.id == "folder:src" }!.files
        try await service.stage(paths: folderFiles.map(\.path), expectedHead: head)
        state = try await service.status()
        try check(
            "Folder staging includes its tracked descendants",
            Set(state.files.filter(\.staged).map(\.path)) == ["src/one.swift", "src/two.swift"])
        try check(
            "Folder staging excludes untracked and unrelated layers",
            state.files.contains { $0.path == "src/new.swift" && $0.untracked }
                && state.files.contains { $0.path == "docs/note.md" && $0.unstaged })
        let remaining = state.files.filter { ChangeFilter().matches($0, layer: .unstaged) }
        try await service.stage(paths: remaining.map(\.path), expectedHead: head)
        state = try await service.status()
        try check(
            "Unstaged select-all excludes the untracked group",
            state.files.filter(\.staged).count == 3
                && state.files.contains { $0.path == "src/new.swift" && $0.untracked })
        let untracked = state.files.filter { ChangeFilter().matches($0, layer: .untracked) }
        try await service.stage(paths: untracked.map(\.path), expectedHead: head)
        state = try await service.status()
        try check(
            "Untracked checkboxes stage exact files",
            state.files.filter(\.staged).count == 4 && !state.files.contains(where: \.untracked))
        let selected = ChangeFileTree.rows(state.files.filter(\.staged)).first { $0.id == "folder:src" }!
            .files
        try await service.unstage(paths: selected.map(\.path), expectedHead: head)
        state = try await service.status()
        try check(
            "Folder unstage leaves unrelated staged files intact",
            state.files.filter(\.staged).map(\.path) == ["docs/note.md"])
        try check(
            "Unstage preserves the working file bytes",
            try Data(contentsOf: root.appending(path: "src/one.swift")) == Data("third\n".utf8))
        try check("Operations do not move HEAD", state.head == head)
        for path in ["replacement", "second"] {
            try Data("tracked\n".utf8).write(to: root.appending(path: path))
        }
        _ = try git(["add", "--", "replacement", "second"])
        _ = try git([
            "-c", "user.name=UI Fixture", "-c", "user.email=fixture@example.invalid", "-c",
            "commit.gpgSign=false", "commit", "-m", "Replacement fixture",
        ])
        let collisionHead = try await service.head()
        try FileManager.default.removeItem(at: root.appending(path: "replacement"))
        try FileManager.default.createDirectory(
            at: root.appending(path: "replacement"), withIntermediateDirectories: true)
        try Data("untracked\n".utf8).write(to: root.appending(path: "replacement/hidden"))
        try Data("modified\n".utf8).write(to: root.appending(path: "second"))
        let indexBefore = try git(["diff", "--cached", "--raw", "-z"])
        var stageRejected = false
        do {
            try await service.stage(paths: ["replacement", "second"], expectedHead: collisionHead)
        } catch ModelFailure.unsupported { stageRejected = true }
        try check("A tracked selection cannot recursively stage an unselected untracked child", stageRejected)
        try check(
            "Rejected ancestor staging preserves the index",
            try git(["diff", "--cached", "--raw", "-z"]) == indexBefore)
        _ = try git(["add", "-A", "--", "replacement", "second"])
        let stagedBefore = try git(["diff", "--cached", "--raw", "-z"])
        var unstageRejected = false
        do {
            try await service.unstage(paths: ["replacement", "second"], expectedHead: collisionHead)
        } catch ModelFailure.unsupported { unstageRejected = true }
        try check(
            "A filtered staged selection cannot recursively unstage an unselected child", unstageRejected)
        try check(
            "Rejected ancestor unstaging preserves the index",
            try git(["diff", "--cached", "--raw", "-z"]) == stagedBefore)
        try await service.unstage(
            paths: ["replacement", "replacement/hidden", "second"], expectedHead: collisionHead)
        try check(
            "An explicitly selected parent and child can be unstaged together",
            try git(["diff", "--cached", "--raw", "-z"]).isEmpty)
        _ = try git(["add", "-u", "--", "replacement"])
        try await service.unstage(paths: ["replacement"], expectedHead: collisionHead)
        try check(
            "Unstaging a deletion does not reject an already untracked child",
            try git(["diff", "--cached", "--raw", "-z"]).isEmpty)
        try check(
            "Ancestor operations preserve untracked child bytes",
            try Data(contentsOf: root.appending(path: "replacement/hidden")) == Data("untracked\n".utf8))
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try JSONSerialization.data(withJSONObject: passed, options: [.prettyPrinted]).write(to: output)
        print("\(passed.count) change file tree and isolated staging checks passed.")
    }
}
