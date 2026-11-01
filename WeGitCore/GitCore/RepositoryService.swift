import Darwin
import Foundation

public struct RepositoryService: Sendable {
    public let location: RepositoryLocation
    public let engine: GitEngine
    public let queue: RepositoryOperationQueue
    public let sharedQueue: RepositoryOperationQueue
    private var expectedBranch: String?
    public init(
        location: RepositoryLocation, engine: GitEngine,
        queue: RepositoryOperationQueue? = nil
    ) {
        self.location = location
        self.engine = engine
        self.queue = queue ?? RepositoryOperationQueue.worktree(for: location)
        self.sharedQueue = RepositoryOperationQueue.shared(for: location)
    }

    /// A common-first lock order serializes shared writes without blocking local
    /// work in sibling worktrees. No worktree-local operation may acquire common.
    func withSharedOperation<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await sharedQueue.perform {
            if queue === sharedQueue { return try await operation() }
            return try await queue.perform(operation)
        }
    }

    public func expectingBranch(_ branch: String) -> RepositoryService {
        var copy = self
        copy.expectedBranch = branch
        return copy
    }

    public static func discover(_ directory: URL, engine: GitEngine) async throws -> RepositoryLocation {
        let bare = try await engine.run(["rev-parse", "--is-bare-repository"], in: directory).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard bare == "false" else {
            throw ModelFailure.unsupported(L10n.text("此版本尚不支持打开 Bare 仓库，请选择含工作区的仓库。"))
        }
        let root = try await engine.run(["rev-parse", "--show-toplevel"], in: directory).text
            .removingLastNewline
        let git = try await engine.run(["rev-parse", "--absolute-git-dir"], in: directory).text
            .removingLastNewline
        let common = try await engine.run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory
        ).text.removingLastNewline
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let gitURL = URL(fileURLWithPath: git).resolvingSymlinksInPath()
        let commonURL = URL(fileURLWithPath: common).resolvingSymlinksInPath()
        let location = RepositoryLocation(
            root: rootURL, gitDirectory: gitURL,
            commonDirectory: commonURL,
            rootIdentity: try RepositoryNodeIdentity.read(rootURL, directory: true),
            gitIdentity: try RepositoryNodeIdentity.read(gitURL, directory: true),
            markerIdentity: try RepositoryNodeIdentity.read(rootURL.appending(path: ".git")),
            commonIdentity: try RepositoryNodeIdentity.read(commonURL, directory: true),
            commonMarkerIdentity: try RepositoryNodeIdentity.readIfPresent(
                gitURL.appending(path: "commondir")),
            worktreeLinkIdentity: try RepositoryNodeIdentity.readIfPresent(gitURL.appending(path: "gitdir")))
        try location.validateLayout()
        return location
    }

    public func status() async throws -> RepositoryStatus {
        try location.validateIdentity()
        // Background reads must not refresh the index stat cache and generate
        // their own filesystem events or contend with real index writes.
        var readEngine = engine
        readEngine.environment["GIT_OPTIONAL_LOCKS"] = "0"
        var value = try StatusParser.parse(
            await readEngine.run(
                ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: location.root
            ).stdout)
        let base = location.gitDirectory
        if FileManager.default.fileExists(atPath: base.appending(path: "rebase-apply/applying").path) {
            // git am uses rebase-apply too, but must not be driven by rebase --continue.
            value.sequencer = .unknown
        } else if FileManager.default.fileExists(atPath: base.appending(path: "rebase-merge").path)
            || FileManager.default.fileExists(atPath: base.appending(path: "rebase-apply").path)
        {
            value.sequencer = .rebase
        } else if FileManager.default.fileExists(atPath: base.appending(path: "MERGE_HEAD").path) {
            value.sequencer = .merge
        } else if FileManager.default.fileExists(atPath: base.appending(path: "CHERRY_PICK_HEAD").path) {
            value.sequencer = .cherryPick
            value.singleCommitRecovery = try singleCommitRecovery(for: value, operation: .cherryPick)
        } else if FileManager.default.fileExists(atPath: base.appending(path: "REVERT_HEAD").path) {
            value.sequencer = .revert
            value.singleCommitRecovery = try singleCommitRecovery(for: value, operation: .revert)
        } else if FileManager.default.fileExists(atPath: base.appending(path: "sequencer").path) {
            value.sequencer = .unknown
        }
        if value.sequencer == .rebase {
            do {
                value.rebaseRecovery = try await readRebaseRecovery(for: value)
                if value.rebaseRecovery == nil {
                    value.rebaseRecoveryUnavailable = L10n.text("此变基来源无法完整核对，请在 Terminal 中处理。")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch ProcessFailure.cancelled {
                throw ProcessFailure.cancelled
            } catch ModelFailure.repositoryReplaced {
                throw ModelFailure.repositoryReplaced
            } catch {
                // An unsupported/external todo must not hide the working files
                // and conflicts. It only disables automatic recovery controls.
                value.rebaseRecoveryUnavailable = error.localizedDescription
            }
        }
        return value
    }

    public func head() async throws -> String? {
        try location.validateIdentity()
        let result = try await engine.run(
            ["rev-parse", "--verify", "HEAD"], in: location.root, accepted: [0, 128])
        return result.exitCode == 0 ? result.text.removingLastNewline : nil
    }

    @concurrent
    public func diff(
        path: String, layer: DiffLayer, options: DiffReadOptions = DiffReadOptions(),
        outputLimit: Int = DiffReadBudget.patchBytes
    )
        async throws -> FileDiff
    {
        guard layer != .commit else { throw ModelFailure.unsupported(L10n.text("提交差异需要明确的提交和父提交。")) }
        guard (1...DiffReadBudget.patchBytes).contains(outputLimit) else {
            throw ModelFailure.unsupported(L10n.text("差异读取上限无效。"))
        }
        guard (0...200).contains(options.contextLines) else {
            throw ModelFailure.unsupported(L10n.text("上下文行数须在 0～200 之间。"))
        }
        try validate(path)
        let current = try await head()
        if layer == .untracked {
            let data = try await SnapshotIO.run { cancellation in
                let reader = try RepositoryFileReader(
                    location: location, path: path, cancellation: cancellation)
                var data = Data()
                try reader.read(limit: min(outputLimit, DiffReadBudget.previewBytes)) { data.append($0) }
                return data
            }
            try DiffReadBudget.validateLineCount(data)
            let text = data.contains(0) ? nil : String(data: data, encoding: .utf8)
            return FileDiff(
                options: options, path: path, layer: layer, raw: data, header: "", hunks: [],
                binary: text == nil,
                preview: text, head: current, indexTree: nil)
        }
        let raw = try await engine.run(
            diffArguments(path: path, layer: layer, options: options), in: location.root,
            outputLimit: outputLimit
        ).stdout
        return try DiffParser.parse(raw, path: path, layer: layer, head: current, options: options)
    }

    func diffArguments(
        path: String, layer: DiffLayer, options: DiffReadOptions, revisions: [String] = [],
        rootCommit: Bool = false, oldPath: String? = nil
    ) -> [String] {
        var args = rootCommit ? ["diff-tree", "--root", "--no-commit-id", "-r"] : ["diff"]
        args += [
            "--no-ext-diff", "--no-textconv", "--no-color", "--patch", "--find-renames",
            "--full-index",
            "--src-prefix=a/", "--dst-prefix=b/", "--output-indicator-new=+", "--output-indicator-old=-",
            "--output-indicator-context= ",
            "--unified=\(options.contextLines)",
        ]
        if layer == .staged { args.append("--cached") }
        if options.ignoreWhitespace { args.append("--ignore-all-space") }
        args += revisions + ["--"] + Array(Set([path] + [oldPath].compactMap { $0 })).sorted()
        return args
    }

    public func stage(paths: [String], expectedHead: String?) async throws {
        try await queue.perform {
            try await verifyHead(expectedHead)
            let state = try await status()
            guard !paths.contains(where: { path in state.conflicts.contains { $0.path == path } }) else {
                throw ModelFailure.unsupported(L10n.text("冲突文件必须通过“标记已解决”单独确认。"))
            }
            let expanded = expandingRenames(paths, in: state)
            try validateExactEntryScope(expanded, in: state)
            try await verifyHead(expectedHead)
            try await add(expanded)
        }
    }

    public func markResolved(path: String, expectedHead: String?) async throws {
        try await queue.perform {
            try await verifyHead(expectedHead)
            try await add([path])
        }
    }

    private func add(_ paths: [String]) async throws {
        try location.validateIdentity()
        guard !paths.isEmpty else { return }
        try paths.forEach(validate)
        _ = try await engine.run(
            ["add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"], in: location.root,
            input: nulPaths(paths))
    }

    public func unstage(paths: [String], expectedHead: String?) async throws {
        try await queue.perform {
            try await verifyHead(expectedHead)
            try paths.forEach(validate)
            guard !paths.isEmpty else { return }
            let state = try await status()
            guard !state.conflicts.contains(where: { paths.contains($0.path) }) else {
                throw ModelFailure.unsupported(L10n.text("请通过当前冲突流程处理未合并文件。"))
            }
            let expanded = expandingRenames(paths, in: state)
            try expanded.forEach(validate)
            try validateExactEntryScope(expanded, in: state, stagedOnly: true)
            let args =
                expectedHead == nil
                ? ["rm", "--cached", "-f", "--pathspec-from-file=-", "--pathspec-file-nul"]
                : ["restore", "--staged", "--pathspec-from-file=-", "--pathspec-file-nul"]
            try await verifyHead(expectedHead)
            // Git restore rejects a child path that is absent from HEAD even
            // when its selected parent already covers the whole replacement.
            let specifications = minimalPathspecs(expanded)
            _ = try await engine.run(args, in: location.root, input: nulPaths(specifications))
        }
    }

    public func apply(hunk: DiffHunk, from diff: FileDiff, discard: Bool = false) async throws {
        try await queue.perform {
            try await verifyHead(diff.head)
            guard !discard || diff.layer == .unstaged else {
                throw ModelFailure.unsupported(L10n.text("只能丢弃未暂存的差异块。"))
            }
            guard diff.canApplyHunk else { throw ModelFailure.unsupported(L10n.text("此差异只支持文件级操作。")) }
            let fresh = try await self.diff(path: diff.path, layer: diff.layer, options: diff.options)
            guard fresh.raw == diff.raw, fresh.head == diff.head else { throw ModelFailure.changed }
            guard fresh.hunks.contains(hunk) else { throw ModelFailure.changed }
            let patch = Data((fresh.header + hunk.raw).utf8)
            var args = ["apply"]
            if !discard { args += ["--cached"] }
            if discard || diff.layer == .staged { args += ["--reverse"] }
            try await verifyHead(diff.head)
            _ = try await engine.run(args + ["--check", "-"], in: location.root, input: patch)
            try await verifyHead(diff.head)
            _ = try await engine.run(args + ["-"], in: location.root, input: patch)
        }
    }

    public func discard(_ diff: FileDiff) async throws {
        try await queue.perform {
            try await verifyHead(diff.head)
            guard diff.layer == .unstaged && !diff.options.ignoreWhitespace else {
                throw ModelFailure.unsupported(L10n.text("此入口只丢弃未暂存的已跟踪文件改动。"))
            }
            let fresh = try await self.diff(path: diff.path, layer: diff.layer, options: diff.options)
            guard fresh.raw == diff.raw, fresh.head == diff.head else { throw ModelFailure.changed }
            try await verifyHead(diff.head)
            _ = try await engine.run(["restore", "--worktree", "--", diff.path], in: location.root)
        }
    }

    public func commit(message: String, amend: Bool, expectedHead: String?) async throws -> String {
        try await withSharedOperation {
            try await verifyHead(expectedHead)
            let state = try await status()
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ModelFailure.unsupported(L10n.text("请填写提交消息。"))
            }
            guard state.conflicts.isEmpty else { throw ModelFailure.unsupported(L10n.text("请先解决所有冲突。")) }
            guard state.sequencer == .none else { throw ModelFailure.unsupported(L10n.text("请使用当前操作的继续入口。")) }
            guard !amend || state.head != nil else {
                throw ModelFailure.unsupported(L10n.text("没有可以修改的上次提交。"))
            }
            var args = ["commit", "--file=-"]
            if amend { args.append("--amend") }
            try await verifyHead(expectedHead)
            do {
                _ = try await engine.run(args, in: location.root, input: Data(message.utf8), timeout: 120)
                guard let committed = try await head() else { throw ModelFailure.changed }
                return committed
            } catch {
                // A timeout/cancellation is not a rollback. Inspect in a fresh task,
                // but never infer that a changed HEAD must have been our commit.
                let observed = await Task.detached { try? await head() }.value
                if let observed, observed != expectedHead {
                    throw CommitOutcomeUnknown(
                        previousHead: expectedHead, observedHead: observed,
                        details: (error as? GitFailure)?.details ?? error.localizedDescription)
                }
                throw error
            }
        }
    }

    public func verifyHead(_ expected: String?) async throws {
        guard try await head() == expected else { throw ModelFailure.changed }
        if let expectedBranch {
            let actual = try await engine.run(
                ["symbolic-ref", "--quiet", "HEAD"], in: location.root, accepted: [0, 1]
            ).text.removingLastNewline
            guard
                actual == "refs/heads/" + expectedBranch || (actual.isEmpty && expectedBranch == "(detached)")
            else { throw ModelFailure.changed }
        }
    }

    /// Literal pathspecs still recurse into directories. A deleted file can share
    /// a name with a new directory, so reject a selection that would also touch
    /// changed descendants the user did not select.
    private func validateExactEntryScope(
        _ paths: [String], in state: RepositoryStatus, stagedOnly: Bool = false
    ) throws {
        let selected = Set(paths)
        for file in state.files
        where !selected.contains(file.path) && (!stagedOnly || file.staged || file.conflict) {
            var ancestor = (file.path as NSString).deletingLastPathComponent
            while !ancestor.isEmpty && ancestor != "." {
                guard !selected.contains(ancestor) else {
                    throw ModelFailure.unsupported(
                        L10n.text("文件与目录替换包含未选中的子路径，请分别处理差异或同时选择这些路径。"))
                }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
        }
    }

    private func minimalPathspecs(_ paths: [String]) -> [String] {
        let selected = Set(paths)
        return selected.filter { path in
            var ancestor = (path as NSString).deletingLastPathComponent
            while !ancestor.isEmpty && ancestor != "." {
                if selected.contains(ancestor) { return false }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            return true
        }.sorted()
    }

    private func expandingRenames(_ paths: [String], in state: RepositoryStatus) -> [String] {
        var expanded = paths
        for file in state.files where paths.contains(file.path) {
            if let original = file.oldPath, file.index == "R" || file.worktree == "R" {
                expanded.append(original)
            }
        }
        return Array(Set(expanded)).sorted()
    }

    func validate(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
            !path.split(separator: "/").contains("..")
        else { throw ModelFailure.invalidPath }
    }
    private func nulPaths(_ paths: [String]) -> Data { Data((paths.joined(separator: "\0") + "\0").utf8) }
}

extension String {
    var removingLastNewline: String { hasSuffix("\n") ? String(dropLast()) : self }
}
