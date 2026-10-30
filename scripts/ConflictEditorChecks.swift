import Foundation
import WeGitCore

@main struct ConflictEditorChecks {
    static func main() async throws {
        var passed = 0
        try parserChecks(&passed)
        try await mergeEditorChecks(&passed)
        try await sequencerChecks(&passed)
        try await replayParentChecks(&passed)
        try await unsupportedContentChecks(&passed)
        try await externalChangeChecks(&passed)
        try await snapshotInvalidationChecks(&passed)
        print("PASS \(passed) conflict editor checks")
    }

    private static func parserChecks(_ passed: inout Int) throws {
        let input =
            "before\r\n<<<<<<< ours\r\nours\r\n||||||| base\r\nbase\r\n=======\r\ntheirs\r\n>>>>>>> theirs\r\nafter"
        let analysis = ConflictMarkerParser.analyze(input)
        let acceptedBoth = try ConflictMarkerParser.replacing(
            text: input, block: analysis.blocks[0], with: .both)
        guard !analysis.malformed, analysis.blocks.count == 1,
            analysis.blocks[0].hasBaseSection,
            acceptedBoth == "before\r\nours\r\ntheirs\r\nafter"
        else { throw ModelFailure.changed }
        let malformed = ConflictMarkerParser.analyze("<<<<<<< ours\nmissing separator\n>>>>>>> theirs")
        guard malformed.malformed, !malformed.resolved else { throw ModelFailure.changed }
        let noFinalNewline = ConflictMarkerParser.analyze("<<<<<<< ours\nours\n=======\ntheirs\n>>>>>>>")
        guard !noFinalNewline.malformed, noFinalNewline.blocks.count == 1 else {
            throw ModelFailure.changed
        }
        passed += 3
        print("PASS parser CRLF/no-final-newline/malformed")
    }

    private static func mergeEditorChecks(_ passed: inout Int) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.git(["init", "-b", "main"])
        try await fixture.configure()
        try Data("base\n".utf8).write(to: fixture.root.appending(path: "file.txt"))
        try await fixture.git(["add", "file.txt"])
        try await fixture.git(["commit", "-m", "base"])
        try await fixture.git(["switch", "-c", "feature"])
        try Data("theirs\n".utf8).write(to: fixture.root.appending(path: "file.txt"))
        try await fixture.git(["commit", "-am", "theirs"])
        try await fixture.git(["switch", "main"])
        try Data("ours\n".utf8).write(to: fixture.root.appending(path: "file.txt"))
        try await fixture.git(["commit", "-am", "ours"])
        try await fixture.git(["merge", "feature"], accepted: [0, 1, 128])

        let service = try await fixture.service()
        let head = try await service.head()
        var document = try await service.readConflictEditor(path: "file.txt", expectedHead: head)
        guard document.sequencer == .merge,
            document.base.source.revision != nil,
            document.ours.source.revision != nil,
            document.theirs.source.revision != nil,
            document.unresolvedBlocks.count == 1,
            document.blockResolutions?.count == 1,
            !document.hasMalformedMarkers
        else { throw ModelFailure.changed }
        let block = document.unresolvedBlocks[0]
        let resolution = document.blockResolutions![0]
        let acceptedBase = try ConflictMarkerParser.replacing(
            text: document.result.text, block: block, with: .base,
            baseOverride: resolution.baseBytes)
        guard resolution.oursBytes == block.oursBytes,
            resolution.theirsBytes == block.theirsBytes,
            acceptedBase == "base\n"
        else { throw ModelFailure.changed }
        let indexBefore = try await fixture.git(["ls-files", "--stage", "-z"]).stdout
        document = try await service.saveConflictResult(document, text: "resolved\n")
        let indexAfter = try await fixture.git(["ls-files", "--stage", "-z"]).stdout
        let pending = try await service.status()
        guard indexBefore == indexAfter,
            try Data(contentsOf: fixture.root.appending(path: "file.txt")) == Data("resolved\n".utf8),
            !pending.conflicts.isEmpty
        else { throw ModelFailure.changed }
        try await service.markConflictResolved(document)
        guard (try await service.status()).conflicts.isEmpty,
            try await fixture.git(["show", ":file.txt"]).stdout == Data("resolved\n".utf8)
        else { throw ModelFailure.changed }
        passed += 5
        print("PASS merge source/save/index/resolve")
    }

    private static func externalChangeChecks(_ passed: inout Int) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.git(["init", "-b", "main"])
        try await fixture.configure()
        try Data("base\n".utf8).write(to: fixture.root.appending(path: "file.txt"))
        try await fixture.git(["add", "file.txt"])
        try await fixture.git(["commit", "-m", "base"])
        try await fixture.git(["switch", "-c", "feature"])
        try Data("theirs\n".utf8).write(to: fixture.root.appending(path: "file.txt"))
        try await fixture.git(["commit", "-am", "theirs"])
        try await fixture.git(["switch", "main"])
        try Data("ours\n".utf8).write(to: fixture.root.appending(path: "file.txt"))
        try await fixture.git(["commit", "-am", "ours"])
        try await fixture.git(["merge", "feature"], accepted: [0, 1, 128])
        let service = try await fixture.service()
        let document = try await service.readConflictEditor(
            path: "file.txt", expectedHead: try await service.head())
        try Data("external\n".utf8).write(to: fixture.root.appending(path: "file.txt"))
        var rejected = false
        do { _ = try await service.saveConflictResult(document, text: "must-not-win\n") } catch {
            rejected = true
        }
        guard rejected,
            try Data(contentsOf: fixture.root.appending(path: "file.txt")) == Data("external\n".utf8)
        else { throw ModelFailure.changed }
        passed += 2
        print("PASS external working-file change rejected")
    }

    private static func sequencerChecks(_ passed: inout Int) async throws {
        for operation in ConflictOperation.allCases {
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let expectedSequencer = try await fixture.prepareConflict(operation)
            let service = try await fixture.service()
            let head = try await service.head()
            var document = try await service.readConflictEditor(path: "nested/file.txt", expectedHead: head)
            guard document.sequencer == expectedSequencer,
                document.base.source.revision != nil,
                document.ours.source.revision != nil,
                document.theirs.source.revision != nil,
                document.unresolvedBlocks.count == 1,
                !document.hasMalformedMarkers
            else { throw ModelFailure.changed }
            document = try await service.saveConflictResult(
                document, text: "resolved \(operation.rawValue)\n")
            try await service.markConflictResolved(document)
            let state = try await service.status()
            let index = try await fixture.git(["show", ":nested/file.txt"])
            guard state.conflicts.isEmpty,
                index.stdout == Data("resolved \(operation.rawValue)\n".utf8)
            else { throw ModelFailure.changed }
            passed += 1
        }
        print("PASS merge/cherry-pick/revert/rebase source/save/resolve")
    }

    private static func snapshotInvalidationChecks(_ passed: inout Int) async throws {
        try await rejectsEditAfterMutation("index") { fixture in
            try Data("other\n".utf8).write(to: fixture.root.appending(path: "other.txt"))
            try await fixture.git(["add", "other.txt"])
        }
        try await rejectsEditAfterMutation("attributes") { fixture in
            try Data("nested/file.txt text eol=lf\n".utf8).write(
                to: fixture.root.appending(path: ".gitattributes"))
        }
        try await rejectsEditAfterMutation("head") { fixture in
            let target = try await fixture.git(["rev-parse", "topic"])
            try await fixture.git([
                "update-ref", "HEAD", target.text.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
        }
        try await rejectsEditAfterMutation("operation metadata") { fixture in
            try Data("externally changed\n".utf8).write(to: fixture.root.appending(path: ".git/MERGE_MSG"))
        }
        try await rejectsEditAfterMutation("file mode") { fixture in
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fixture.root.appending(path: "nested/file.txt").path
            )
        }
        try await rejectsEditAfterMutation("parent replacement") { fixture in
            let directory = fixture.root.appending(path: "nested")
            let moved = fixture.root.appending(path: "nested-saved")
            let file = directory.appending(path: "file.txt")
            let contents = try Data(contentsOf: file)
            try FileManager.default.moveItem(at: directory, to: moved)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try contents.write(to: directory.appending(path: "file.txt"))
        }
        passed += 6
        print("PASS index/attributes/HEAD/operation/mode/parent replacement rejected")
    }

    private static func replayParentChecks(_ passed: inout Int) async throws {
        for rebase in [false, true] {
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try await fixture.git(["init", "-b", "main"])
            try await fixture.configure()
            let path = fixture.root.appending(path: "file.txt")
            try Data("base\n".utf8).write(to: path)
            try await fixture.git(["add", "file.txt"])
            try await fixture.git(["commit", "-m", "base"])
            try await fixture.git(["switch", "-c", "topic"])
            try Data("first\n".utf8).write(to: path)
            try await fixture.git(["commit", "-am", "first"])
            let parent = try await fixture.git(["rev-parse", "HEAD"])
            try Data("second\n".utf8).write(to: path)
            try await fixture.git(["commit", "-am", "second"])
            let second = try await fixture.git(["rev-parse", "HEAD"])
            try await fixture.git(["switch", "main"])
            try Data("target\n".utf8).write(to: path)
            try await fixture.git(["commit", "-am", "target"])
            if rebase {
                try await fixture.git(["switch", "topic"])
                try await fixture.git(["rebase", "main"], accepted: [1])
                try Data("resolved first\n".utf8).write(to: path)
                try await fixture.git(["add", "file.txt"])
                try await fixture.git(["-c", "core.editor=true", "rebase", "--continue"], accepted: [1])
            } else {
                try await fixture.git(
                    [
                        "cherry-pick", second.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    ], accepted: [1])
            }
            let service = try await fixture.service()
            let document = try await service.readConflictEditor(
                path: "file.txt", expectedHead: try await service.head())
            guard document.base.bytes == Data("first\n".utf8),
                document.base.source.revision == parent.text.trimmingCharacters(in: .whitespacesAndNewlines),
                document.theirs.source.revision
                    == second.text.trimmingCharacters(in: .whitespacesAndNewlines),
                document.ours.bytes == Data((rebase ? "resolved first\n" : "target\n").utf8)
            else { throw ModelFailure.changed }
            passed += 1
        }
        print("PASS later rebase/cherry-pick conflicts use the original parent as BASE")
    }

    private static func unsupportedContentChecks(_ passed: inout Int) async throws {
        for boundary in ["merge driver", "content filter", "invalid UTF-8", "symbolic link", "index lock"] {
            let fixture = try Fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            _ = try await fixture.prepareConflict(.merge)
            let service = try await fixture.service()
            let file = fixture.root.appending(path: "nested/file.txt")
            let indexURL = fixture.root.appending(path: ".git/index")
            let indexBefore = try Data(contentsOf: indexURL)
            switch boundary {
            case "merge driver", "content filter":
                let attribute = boundary == "merge driver" ? "merge=private-driver" : "filter=private-filter"
                try Data(("nested/file.txt " + attribute + "\n").utf8).write(
                    to: fixture.root.appending(path: ".gitattributes"))
            case "invalid UTF-8":
                try Data([0xFF, 0xFE, 0x01]).write(to: file)
            case "symbolic link":
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(
                    atPath: file.path, withDestinationPath: "elsewhere")
            case "index lock":
                let document = try await service.readConflictEditor(
                    path: "nested/file.txt", expectedHead: try await service.head())
                let saved = try await service.saveConflictResult(document, text: "confirmed result\n")
                let lock = fixture.root.appending(path: ".git/index.lock")
                let lockBytes = Data("external lock\n".utf8)
                try lockBytes.write(to: lock)
                var rejected = false
                do { try await service.markConflictResolved(saved) } catch { rejected = true }
                guard rejected, try Data(contentsOf: lock) == lockBytes,
                    try Data(contentsOf: indexURL) == indexBefore,
                    try Data(contentsOf: file) == Data("confirmed result\n".utf8)
                else { throw ModelFailure.changed }
                passed += 1
                continue
            default: throw ModelFailure.changed
            }
            var rejected = false
            do {
                _ = try await service.readConflictEditor(
                    path: "nested/file.txt", expectedHead: try await service.head())
            } catch { rejected = true }
            guard rejected, try Data(contentsOf: indexURL) == indexBefore else { throw ModelFailure.changed }
            passed += 1
        }
        print("PASS merge driver/filter/encoding/symlink/foreign index lock boundaries")
    }

    private static func rejectsEditAfterMutation(
        _ name: String, mutate: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.prepareConflict(.merge)
        let service = try await fixture.service()
        let document = try await service.readConflictEditor(
            path: "nested/file.txt", expectedHead: try await service.head())
        let before = try Data(contentsOf: fixture.root.appending(path: "nested/file.txt"))
        try await mutate(fixture)
        var rejected = false
        do { _ = try await service.saveConflictResult(document, text: "must-not-win\n") } catch {
            rejected = true
        }
        guard rejected, try Data(contentsOf: fixture.root.appending(path: "nested/file.txt")) == before else {
            throw ModelFailure.unsupported("\(name) change was not rejected")
        }
        print("PASS \(name) snapshot change rejected")
    }

    private enum ConflictOperation: String, CaseIterable {
        case merge, cherryPick, revert, rebase
    }

    private struct Fixture {
        let root: URL
        let engine: GitEngine

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(
                path: "WeGitConflict-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
            engine = GitEngine(environment: environment)
        }

        func configure() async throws {
            try await git(["config", "user.name", "WeGit Conflict Test"])
            try await git(["config", "user.email", "conflict@example.invalid"])
            try await git(["config", "commit.gpgsign", "false"])
        }

        func service() async throws -> RepositoryService {
            let location = try await RepositoryService.discover(root, engine: engine)
            return RepositoryService(location: location, engine: engine)
        }

        @discardableResult
        func git(_ args: [String], accepted: Set<Int32> = [0]) async throws -> ProcessResult {
            try await engine.run(args, in: root, accepted: accepted)
        }

        func prepareConflict(_ operation: ConflictOperation) async throws -> Sequencer {
            let directory = root.appending(path: "nested")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await git(["init", "-b", "main"])
            try await configure()
            try Data("base\n".utf8).write(to: directory.appending(path: "file.txt"))
            try await git(["add", "nested/file.txt"])
            try await git(["commit", "-m", "base"])

            if operation == .revert {
                try Data("theirs\n".utf8).write(to: directory.appending(path: "file.txt"))
                try await git(["commit", "-am", "target"])
                let target = try await git(["rev-parse", "HEAD"])
                try Data("ours\n".utf8).write(to: directory.appending(path: "file.txt"))
                try await git(["commit", "-am", "later"])
                try await git(
                    ["revert", target.text.trimmingCharacters(in: .whitespacesAndNewlines)],
                    accepted: [0, 1, 128])
                return .revert
            }

            try await git(["switch", "-c", "topic"])
            try Data("theirs\n".utf8).write(to: directory.appending(path: "file.txt"))
            try await git(["commit", "-am", "topic"])
            let target = try await git(["rev-parse", "HEAD"])
            try await git(["switch", "main"])
            try Data("ours\n".utf8).write(to: directory.appending(path: "file.txt"))
            try await git(["commit", "-am", "main"])

            switch operation {
            case .merge:
                try await git(["merge", "topic"], accepted: [0, 1, 128])
                return .merge
            case .cherryPick:
                try await git(
                    ["cherry-pick", target.text.trimmingCharacters(in: .whitespacesAndNewlines)],
                    accepted: [0, 1, 128])
                return .cherryPick
            case .rebase:
                try await git(["switch", "topic"])
                try await git(["rebase", "main"], accepted: [0, 1, 128])
                return .rebase
            case .revert:
                throw ModelFailure.changed
            }
        }
    }
}
