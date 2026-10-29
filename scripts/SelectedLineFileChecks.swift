import Foundation
import WeGitCore

@main struct SelectedLineFileChecks {
    static func main() async throws {
        var passed = 0
        for unborn in [false, true] {
            for all in [false, true] {
                let root = FileManager.default.temporaryDirectory.appending(
                    path: "WeGitSelectedUntracked-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: root) }
                var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                env["GIT_CONFIG_GLOBAL"] = "/dev/null"
                env["GIT_CONFIG_SYSTEM"] = "/dev/null"
                let engine = GitEngine(environment: env)
                @discardableResult func git(_ args: [String]) async throws -> ProcessResult {
                    try await engine.run(args, in: root)
                }
                try await git(["init", "-b", "main"])
                for (key, value) in [
                    ("user.name", "Tester"), ("user.email", "test@example.invalid"),
                    ("commit.gpgsign", "false"),
                ] { try await git(["config", key, value]) }
                if !unborn { try await git(["commit", "--allow-empty", "-m", "Base"]) }
                let name = "未跟踪 [x]\nspace.txt"
                let url = root.appending(path: name)
                let content = Data("a\r\nb\r\nc".utf8)
                try content.write(to: url)
                let service = try await RepositoryService(
                    location: RepositoryService.discover(root, engine: engine), engine: engine)
                let diff = try await service.diff(path: name, layer: .untracked)
                let ids: Set<Int> = all ? [0, 1, 2] : [0, 2]
                let index = root.appending(path: ".git/index")
                let hadIndex = FileManager.default.fileExists(atPath: index.path)
                let before = hadIndex ? try Data(contentsOf: index) : nil
                let plan = try await service.prepareSelectedLines(diff: diff, lineIDs: ids)
                guard
                    (FileManager.default.fileExists(atPath: index.path) ? try Data(contentsOf: index) : nil)
                        == before
                else { throw ModelFailure.changed }
                try await service.executeSelectedLines(plan)
                let blob = try await git(["show", ":" + name]).stdout
                let expected = all ? content : Data("a\r\nc".utf8)
                guard blob == expected, try Data(contentsOf: url) == content else {
                    throw ModelFailure.changed
                }
                passed += 1
                print("PASS untracked stage unborn=\(unborn) all=\(all)")
                fflush(stdout)
            }
        }
        for unborn in [false, true] {
            for all in [false, true] {
                let root = FileManager.default.temporaryDirectory.appending(
                    path: "WeGitSelectedNew-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: root) }
                var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                env["GIT_CONFIG_GLOBAL"] = "/dev/null"
                env["GIT_CONFIG_SYSTEM"] = "/dev/null"
                let engine = GitEngine(environment: env)
                @discardableResult func git(_ args: [String], accepted: Set<Int32> = [0]) async throws
                    -> ProcessResult
                {
                    try await engine.run(args, in: root, accepted: accepted)
                }
                try await git(["init", "-b", "main"])
                for (key, value) in [
                    ("user.name", "Tester"), ("user.email", "test@example.invalid"),
                    ("commit.gpgsign", "false"),
                ] { try await git(["config", key, value]) }
                if !unborn { try await git(["commit", "--allow-empty", "-m", "Base"]) }
                let name = "新建 [x]\nspace.txt"
                let url = root.appending(path: name)
                let content = Data("a\nb\nc\n".utf8)
                try content.write(to: url)
                try await git(["add", "--", name])
                let service = try await RepositoryService(
                    location: RepositoryService.discover(root, engine: engine), engine: engine)
                let diff = try await service.diff(
                    path: name, layer: .staged, options: DiffReadOptions(contextLines: 0))
                let lines: [DiffLine] = diff.hunks.flatMap { $0.lines }
                let ids = Set(lines.filter { $0.kind == "+" && (all || $0.content == "b") }.map { $0.id })
                let plan = try await service.prepareSelectedLines(diff: diff, lineIDs: ids)
                try await service.executeSelectedLines(plan)
                let listed = try await git(["ls-files", "--stage", "-z", "--", name]).stdout
                if all {
                    guard listed.isEmpty else { throw ModelFailure.changed }
                } else {
                    let blob = try await git(["show", ":" + name]).stdout
                    guard blob == Data("a\nc\n".utf8) else { throw ModelFailure.changed }
                }
                guard try Data(contentsOf: url) == content else { throw ModelFailure.changed }
                passed += 1
                print("PASS new-file unstage unborn=\(unborn) all=\(all)")
                fflush(stdout)
            }
        }
        for staged in [false, true] {
            for all in [false, true] {
                let root = FileManager.default.temporaryDirectory.appending(
                    path: "WeGitSelectedDeleted-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: root) }
                var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                env["GIT_CONFIG_GLOBAL"] = "/dev/null"
                env["GIT_CONFIG_SYSTEM"] = "/dev/null"
                let engine = GitEngine(environment: env)
                @discardableResult func git(_ args: [String]) async throws -> ProcessResult {
                    try await engine.run(args, in: root)
                }
                try await git(["init", "-b", "main"])
                for (key, value) in [
                    ("user.name", "Tester"), ("user.email", "test@example.invalid"),
                    ("commit.gpgsign", "false"),
                ] { try await git(["config", key, value]) }
                let name = "删除 [x]\nspace.txt"
                let url = root.appending(path: name)
                let content = Data("a\nb\nc\n".utf8)
                try content.write(to: url)
                try await git(["add", "--", name])
                try await git(["commit", "-m", "Base"])
                if staged {
                    try await git(["rm", "--", name])
                } else {
                    try FileManager.default.removeItem(at: url)
                }
                let service = try await RepositoryService(
                    location: RepositoryService.discover(root, engine: engine), engine: engine)
                let diff = try await service.diff(
                    path: name, layer: staged ? .staged : .unstaged, options: DiffReadOptions(contextLines: 0)
                )
                let lines: [DiffLine] = diff.hunks.flatMap { $0.lines }
                let ids = Set(lines.filter { $0.kind == "-" && (all || $0.content == "b") }.map { $0.id })
                let plan = try await service.prepareSelectedLines(diff: diff, lineIDs: ids)
                try await service.executeSelectedLines(plan)
                let listed = try await git(["ls-files", "--stage", "-z", "--", name]).stdout
                if !staged && all {
                    guard listed.isEmpty else { throw ModelFailure.changed }
                } else {
                    let blob = try await git(["show", ":" + name]).stdout
                    let expected = staged ? (all ? "a\nb\nc\n" : "b\n") : "a\nc\n"
                    guard blob == Data(expected.utf8) else { throw ModelFailure.changed }
                }
                guard !FileManager.default.fileExists(atPath: url.path) else { throw ModelFailure.changed }
                passed += 1
                print("PASS deleted-file staged=\(staged) all=\(all)")
                fflush(stdout)
            }
        }
        for useFilter in [false, true] {
            let root = FileManager.default.temporaryDirectory.appending(
                path: "WeGitSelectedAttribute-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            env["GIT_CONFIG_GLOBAL"] = "/dev/null"
            env["GIT_CONFIG_SYSTEM"] = "/dev/null"
            let engine = GitEngine(environment: env)
            @discardableResult func git(_ args: [String]) async throws -> ProcessResult {
                try await engine.run(args, in: root)
            }
            try await git(["init", "-b", "main"])
            let marker = root.appending(path: "marker")
            let filter = root.appending(path: "filter.sh")
            if useFilter {
                try Data("#!/bin/sh\necho ran > \(marker.path)\ncat\n".utf8).write(to: filter)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: filter.path)
                try await git(["config", "filter.probe.clean", filter.path])
                try Data("*.txt filter=probe\n".utf8).write(to: root.appending(path: ".gitattributes"))
            } else {
                try Data("*.txt text eol=lf\n".utf8).write(to: root.appending(path: ".gitattributes"))
            }
            let name = "file.txt"
            let content = Data("a\r\nb\r\n".utf8)
            try content.write(to: root.appending(path: name))
            let service = try await RepositoryService(
                location: RepositoryService.discover(root, engine: engine), engine: engine)
            let diff = try await service.diff(path: name, layer: .untracked)
            var rejected = false
            do { _ = try await service.prepareSelectedLines(diff: diff, lineIDs: [0]) } catch {
                rejected = true
            }
            guard rejected, !FileManager.default.fileExists(atPath: marker.path),
                !FileManager.default.fileExists(atPath: root.appending(path: ".git/index").path),
                try Data(contentsOf: root.appending(path: name)) == content
            else { throw ModelFailure.changed }
            passed += 1
            print("PASS incompatible clean conversion refused filter=\(useFilter)")
        }
        print("PASS \(passed) file cases including conversion guards")
    }
}
