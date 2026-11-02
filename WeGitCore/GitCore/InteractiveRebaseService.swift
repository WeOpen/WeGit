import CryptoKit
import Darwin
import Foundation

struct InteractiveRebaseEditorDescriptor: Hashable, Sendable {
    let url: URL
    let digest: String
    let directoryIdentity: RepositoryNodeIdentity
    let fileIdentity: RepositoryNodeIdentity

    static func read(manifest: Data) throws -> Self {
        guard let text = String(data: manifest, encoding: .utf8) else { throw ModelFailure.changed }
        let fields = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard fields.count == 2, GitObjectID.valid(String(fields[1])) else { throw ModelFailure.changed }
        let url = URL(fileURLWithPath: String(fields[0])).standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let directory = url.deletingLastPathComponent()
        guard
            directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == temporary,
            directory.lastPathComponent.hasPrefix("wegit-interactive-"),
            url.lastPathComponent == "message-editor.sh"
        else { throw ModelFailure.changed }
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
            directoryInfo.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR), directoryInfo.st_uid == getuid(),
            directoryInfo.st_mode & 0o777 == 0o700
        else { throw ModelFailure.changed }
        let directoryIdentity = try RepositoryNodeIdentity.read(directory, directory: true)
        var fileInfo = stat()
        guard lstat(url.path, &fileInfo) == 0, fileInfo.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            fileInfo.st_uid == getuid(), fileInfo.st_nlink == 1, fileInfo.st_mode & 0o777 == 0o700,
            fileInfo.st_size > 0, fileInfo.st_size <= 64 * 1024
        else { throw ModelFailure.changed }
        let fileIdentity = try RepositoryNodeIdentity.read(url)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == fileInfo.st_dev,
            opened.st_ino == fileInfo.st_ino, opened.st_nlink == 1
        else { throw ModelFailure.changed }
        let script = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard script.count == fileInfo.st_size, digest(script) == String(fields[1]),
            try RepositoryNodeIdentity.read(directory, directory: true) == directoryIdentity,
            try RepositoryNodeIdentity.read(url) == fileIdentity
        else { throw ModelFailure.changed }
        return Self(
            url: url, digest: String(fields[1]), directoryIdentity: directoryIdentity,
            fileIdentity: fileIdentity)
    }

    func validate() throws {
        let current = try Self.read(manifest: Data((url.path + "\n" + digest + "\n").utf8))
        guard current == self else { throw ModelFailure.changed }
    }

    static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }

    func removeOwnedDirectory() {
        do { try validate() } catch { return }
        InteractiveRebasePrivateDirectory.remove(
            url: url, directoryIdentity: directoryIdentity, fileIdentity: fileIdentity)
    }
}

struct InteractiveRebaseSessionManifest: Codable, Hashable, Sendable {
    let originalHead: String
    let branch: String
    let upstream: String
    let sequenceDigest: String
    let contentDigest: String
    let expectedCommitCount: Int?
    let editorURL: String?
    let editorDigest: String?

    var containsEdit: Bool { expectedCommitCount == nil }

    func messageEditor() throws -> InteractiveRebaseEditorDescriptor? {
        guard let editorURL, let editorDigest else { return nil }
        return try InteractiveRebaseEditorDescriptor.read(
            manifest: Data((editorURL + "\n" + editorDigest + "\n").utf8))
    }
}

struct InteractiveRebaseSessionDescriptor: Hashable, Sendable {
    let url: URL
    let digest: String
    let directoryIdentity: RepositoryNodeIdentity
    let fileIdentity: RepositoryNodeIdentity
    let manifest: InteractiveRebaseSessionManifest

    static func read(marker: Data) throws -> Self {
        guard let text = String(data: marker, encoding: .utf8) else { throw ModelFailure.changed }
        let fields = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard fields.count == 2, GitObjectID.valid(String(fields[1])) else { throw ModelFailure.changed }
        let url = URL(fileURLWithPath: String(fields[0])).standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let directory = url.deletingLastPathComponent()
        guard
            directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == temporary,
            directory.lastPathComponent.hasPrefix("wegit-interactive-"),
            url.lastPathComponent == "sequence.json"
        else { throw ModelFailure.changed }
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
            directoryInfo.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR), directoryInfo.st_uid == getuid(),
            directoryInfo.st_mode & 0o777 == 0o700
        else { throw ModelFailure.changed }
        let directoryIdentity = try RepositoryNodeIdentity.read(directory, directory: true)
        var fileInfo = stat()
        guard lstat(url.path, &fileInfo) == 0, fileInfo.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG),
            fileInfo.st_uid == getuid(), fileInfo.st_nlink == 1, fileInfo.st_mode & 0o777 == 0o600,
            fileInfo.st_size > 0, fileInfo.st_size <= 64 * 1024
        else { throw ModelFailure.changed }
        let fileIdentity = try RepositoryNodeIdentity.read(url)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ModelFailure.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == fileInfo.st_dev,
            opened.st_ino == fileInfo.st_ino, opened.st_nlink == 1
        else { throw ModelFailure.changed }
        let bytes = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard bytes.count == fileInfo.st_size,
            InteractiveRebaseEditorDescriptor.digest(bytes) == String(fields[1]),
            try RepositoryNodeIdentity.read(directory, directory: true) == directoryIdentity,
            try RepositoryNodeIdentity.read(url) == fileIdentity
        else { throw ModelFailure.changed }
        let manifest = try JSONDecoder().decode(InteractiveRebaseSessionManifest.self, from: bytes)
        guard GitObjectID.valid(manifest.originalHead), GitObjectID.valid(manifest.upstream),
            !manifest.branch.isEmpty, manifest.branch.hasPrefix("refs/heads/"),
            GitObjectID.valid(manifest.sequenceDigest),
            GitObjectID.valid(manifest.contentDigest),
            manifest.expectedCommitCount.map({ $0 >= 0 && $0 <= InteractiveRebaseBudget.commits }) ?? true,
            (manifest.editorURL == nil) == (manifest.editorDigest == nil)
        else { throw ModelFailure.changed }
        guard try InteractiveRebasePrivateDirectory.contentDigest(directory) == manifest.contentDigest else {
            throw ModelFailure.changed
        }
        _ = try manifest.messageEditor()
        return Self(
            url: url, digest: String(fields[1]), directoryIdentity: directoryIdentity,
            fileIdentity: fileIdentity, manifest: manifest)
    }

    func validate() throws {
        let current = try Self.read(marker: Data((url.path + "\n" + digest + "\n").utf8))
        guard current == self else { throw ModelFailure.changed }
    }

    func removeOwnedDirectory() {
        do { try validate() } catch { return }
        InteractiveRebasePrivateDirectory.remove(
            url: url, directoryIdentity: directoryIdentity, fileIdentity: fileIdentity)
    }
}

private enum InteractiveRebasePrivateDirectory {
    static func contentDigest(_ directory: URL) throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0 == "todo" || $0 == "messages"
                || ($0.hasPrefix("message-") && Int($0.dropFirst("message-".count)) != nil)
        }.sorted()
        guard names.contains("todo"), names.count <= InteractiveRebaseBudget.commits + 2 else {
            throw ModelFailure.changed
        }
        var total = 0
        var digest = SHA256()
        for name in names {
            let url = directory.appending(path: name)
            var before = stat()
            guard lstat(url.path, &before) == 0,
                before.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), before.st_uid == getuid(),
                before.st_nlink == 1, before.st_mode & 0o777 == 0o600,
                before.st_size >= 0, before.st_size <= InteractiveRebaseBudget.bytes - total
            else { throw ModelFailure.changed }
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ModelFailure.changed }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_dev == before.st_dev,
                opened.st_ino == before.st_ino, opened.st_size == before.st_size
            else { throw ModelFailure.changed }
            let bytes = try handle.read(upToCount: Int(before.st_size) + 1) ?? Data()
            guard bytes.count == before.st_size else { throw ModelFailure.changed }
            total += bytes.count
            digest.update(data: Data((name + "\0").utf8))
            digest.update(data: Data((InteractiveRebaseEditorDescriptor.digest(bytes) + "\n").utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func remove(
        url: URL, directoryIdentity: RepositoryNodeIdentity, fileIdentity: RepositoryNodeIdentity
    ) {
        let directory = url.deletingLastPathComponent()
        let parentPath = directory.deletingLastPathComponent()
        let parent = Darwin.open(parentPath.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return }
        defer { Darwin.close(parent) }
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0, parentInfo.st_uid == getuid() else { return }
        let name = directory.lastPathComponent
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            named.st_dev == directoryIdentity.device, named.st_ino == directoryIdentity.inode,
            named.st_birthtimespec.tv_sec == directoryIdentity.bornSeconds,
            named.st_birthtimespec.tv_nsec == directoryIdentity.bornNanoseconds,
            named.st_uid == getuid(), named.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR)
        else { return }
        let tomb = ".wegit-editor-cleanup-\(UUID().uuidString)"
        guard renameatx_np(parent, name, parent, tomb, UInt32(RENAME_EXCL)) == 0 else { return }
        var removed = false
        defer {
            if !removed, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT {
                _ = renameatx_np(parent, tomb, parent, name, UInt32(RENAME_EXCL))
            }
        }
        var moved = stat()
        guard fstatat(parent, tomb, &moved, AT_SYMLINK_NOFOLLOW) == 0,
            moved.st_dev == directoryIdentity.device, moved.st_ino == directoryIdentity.inode
        else { return }
        let directoryFD = openat(parent, tomb, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return }
        defer { Darwin.close(directoryFD) }
        var openedDirectory = stat()
        guard fstat(directoryFD, &openedDirectory) == 0,
            openedDirectory.st_dev == directoryIdentity.device,
            openedDirectory.st_ino == directoryIdentity.inode
        else { return }
        let tombURL = parentPath.appending(path: tomb, directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tombURL.path) else { return }
        func isOwnedEntry(_ value: String) -> Bool {
            switch value {
            case "todo", "sequence-editor.sh", "message-editor.sh", "messages", "message-counter",
                "sequence.json":
                true
            default: value.hasPrefix("message-")
            }
        }
        guard names.allSatisfy(isOwnedEntry), names.contains(url.lastPathComponent) else { return }
        for value in names {
            var info = stat()
            guard fstatat(directoryFD, value, &info, AT_SYMLINK_NOFOLLOW) == 0,
                info.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), info.st_uid == getuid(), info.st_nlink == 1,
                value != url.lastPathComponent
                    || (info.st_dev == fileIdentity.device && info.st_ino == fileIdentity.inode)
            else { return }
        }
        for value in names where unlinkat(directoryFD, value, 0) != 0 { return }
        removed = unlinkat(parent, tomb, AT_REMOVEDIR) == 0
    }
}

extension RepositoryService {
    @concurrent
    public func prepareInteractiveRebase(upstream: GitBranch) async throws -> InteractiveRebasePlan {
        try await queue.perform {
            try await self.prepareInteractiveRebaseDirect(upstream: upstream)
        }
    }

    @concurrent
    public func executeInteractiveRebase(_ plan: InteractiveRebasePlan, timeout: TimeInterval = 120)
        async throws
        -> InteractiveRebaseOutcome
    {
        guard timeout.isFinite, timeout > 0, timeout <= 120 else { throw ModelFailure.changed }
        return try await withSharedOperation {
            guard plan.location == self.location else { throw ModelFailure.changed }
            let fresh = try await self.prepareInteractiveRebaseDirect(upstream: plan.upstream)
            guard fresh.branch == plan.branch, fresh.head == plan.head,
                fresh.upstream == plan.upstream, fresh.index == plan.index,
                fresh.writePaths == plan.writePaths, fresh.publishedCommits == plan.publishedCommits
            else { throw ModelFailure.changed }
            if plan.steps.isEmpty, fresh.steps.isEmpty { return .unchanged }
            try self.validateInteractiveSteps(plan.steps, sourceIDs: Set(fresh.steps.map(\.id)))
            let previewSteps = plan.steps.map { step -> RebaseStep in
                switch step.action {
                case .pick: .pick(step.id)
                case .reword: .reword(step.id)
                case .edit: .edit(step.id)
                case .squash: .squash(step.id)
                case .fixup: .fixup(step.id)
                case .drop: .drop(step.id)
                }
            }
            let preview = try await self.rebaseReplayPreview(
                steps: previewSteps, head: plan.upstream.oid, onto: plan.upstream.oid)
            let guardedPaths = plan.writePaths.union(preview.paths)
            guard guardedPaths.count <= RebaseBudget.entries else { throw RebaseBudget.exceeded }

            let directory = try self.interactiveDirectory()
            var keepDirectoryForRecovery = false
            var sessionDescriptor: InteractiveRebaseSessionDescriptor?
            defer {
                if !keepDirectoryForRecovery {
                    if let sessionDescriptor {
                        sessionDescriptor.removeOwnedDirectory()
                    } else {
                        try? FileManager.default.removeItem(at: directory)
                    }
                }
            }
            let todo = directory.appending(path: "todo")
            let sequenceEditor = directory.appending(path: "sequence-editor.sh")
            let messageEditor = directory.appending(path: "message-editor.sh")
            try self.writeInteractiveTodo(plan.steps, to: todo)
            var commandEngine = self.singleCommitEngine
            let usesPrivateMessageEditor = plan.steps.contains(where: {
                ($0.action == .reword || $0.action == .squash) && $0.message != nil
            })
            var editorDigest: String?
            var editorIdentity: InteractiveRebaseEditorDescriptor?
            if usesPrivateMessageEditor {
                let messages = directory.appending(path: "messages")
                try self.writeInteractiveMessages(plan.steps, to: messages)
                try self.writeInteractiveScript(
                    """
                    #!/bin/sh
                    set -eu
                    test "$#" -eq 1
                    done=\(Self.shellLiteral(self.location.gitDirectory.appending(path: "rebase-merge/done").path))
                    test -f "$done"
                    object=$(awk '$1 !~ /^#/ && NF >= 2 { object=$2 } END { print object }' "$done")
                    test -n "$object"
                    source=$(awk -F '\\t' -v object="$object" \
                      '$1 == object { print $2; found=1; exit } END { if (!found) print "-" }' \
                      \(Self.shellLiteral(messages.path)))
                    if test "$source" != "-"; then
                      test -f "$source"
                      cp "$source" "$1"
                    fi
                    """, to: messageEditor)
                commandEngine.environment["GIT_EDITOR"] = messageEditor.path
                let script = try Data(contentsOf: messageEditor)
                editorDigest = InteractiveRebaseEditorDescriptor.digest(script)
                editorIdentity = try InteractiveRebaseEditorDescriptor.read(
                    manifest: Data((messageEditor.path + "\n" + editorDigest! + "\n").utf8))
            } else {
                commandEngine.environment["GIT_EDITOR"] = "/usr/bin/true"
            }
            let todoBytes = try Data(contentsOf: todo)
            let expectedCommitCount =
                plan.steps.contains(where: { $0.action == .edit })
                ? nil
                : plan.steps.reduce(into: 0) { count, step in
                    if [.pick, .reword].contains(step.action) { count += 1 }
                }
            let manifest = InteractiveRebaseSessionManifest(
                originalHead: plan.head, branch: "refs/heads/" + plan.branch, upstream: plan.upstream.oid,
                sequenceDigest: InteractiveRebaseEditorDescriptor.digest(todoBytes),
                contentDigest: try InteractiveRebasePrivateDirectory.contentDigest(directory),
                expectedCommitCount: expectedCommitCount,
                editorURL: editorIdentity?.url.path, editorDigest: editorIdentity?.digest)
            let manifestURL = directory.appending(path: "sequence.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            let manifestBytes = try Data(contentsOf: manifestURL)
            let manifestDigest = InteractiveRebaseEditorDescriptor.digest(manifestBytes)
            sessionDescriptor = try InteractiveRebaseSessionDescriptor.read(
                marker: Data((manifestURL.path + "\n" + manifestDigest + "\n").utf8))
            let sequenceEditorBody =
                """
                #!/bin/sh
                set -eu
                test "$#" -eq 1
                test -f "$1"
                cp \(Self.shellLiteral(todo.path)) "$1"
                marker="$(dirname "$1")/wegit-interactive-session"
                pending="$marker.pending"
                test ! -e "$marker"
                test ! -e "$pending"
                umask 077
                printf '%s\\n%s\\n' \(Self.shellLiteral(manifestURL.path)) \\
                  \(Self.shellLiteral(manifestDigest)) > "$pending"
                mv "$pending" "$marker"
                """
            try self.writeInteractiveScript(sequenceEditorBody, to: sequenceEditor)
            commandEngine.environment["GIT_SEQUENCE_EDITOR"] = sequenceEditor.path

            let result: ProcessResult
            let ready = try await self.status()
            guard ready.head == plan.head, ready.branch == plan.branch, ready.files.isEmpty,
                ready.sequencer == .none, try await self.singleCommitIndex().raw == plan.index,
                try await self.freshBranch(plan.upstream) == plan.upstream
            else { throw ModelFailure.changed }
            try self.location.validateIdentity()
            try Task.checkCancellation()
            let originalReference = try await self.protectRebaseOriginal(plan.head)
            keepDirectoryForRecovery = true
            do {
                try await StashWorktreeGuard.validate(
                    paths: guardedPaths, tracked: try self.rebaseIndexPaths(plan.index),
                    location: self.location)
                result = try await commandEngine.run(
                    [
                        "rebase", "--interactive", "--no-autostash", "--no-update-refs",
                        "--no-fork-point", "--reapply-cherry-picks", "--empty=keep", "--keep-empty",
                        "--no-autosquash", "--no-rerere-autoupdate", "--strategy=ort",
                        "--onto", plan.upstream.oid, plan.upstream.oid,
                    ], in: self.location.root, accepted: [0, 1], timeout: timeout,
                    configuration: self.rebaseCommandConfiguration)
            } catch {
                let observation = try await Task.detached {
                    (try await self.status(), try await self.singleCommitIndex().raw)
                }.value
                let observed = observation.0
                if let recovery = observed.rebaseRecovery {
                    keepDirectoryForRecovery = true
                    if !observed.conflicts.isEmpty {
                        return .conflicts(recovery, observed.conflicts.count)
                    }
                    return .paused(recovery)
                }
                if observed.sequencer == .none, observed.head == plan.head,
                    observed.branch == plan.branch, observed.files.isEmpty,
                    observation.1 == plan.index
                {
                    keepDirectoryForRecovery = false
                    throw error
                }
                keepDirectoryForRecovery = true
                throw RebaseOutcomeUnknown(
                    previousHead: plan.head, observedHead: observed.head,
                    details: error.localizedDescription, originalReference: originalReference)
            }
            let state = try await Task.detached { try await self.status() }.value
            if let recovery = state.rebaseRecovery {
                keepDirectoryForRecovery = true
                if !state.conflicts.isEmpty { return .conflicts(recovery, state.conflicts.count) }
                return .paused(recovery)
            }
            guard state.sequencer == .none, state.branch == plan.branch,
                state.files.isEmpty, let head = state.head
            else { throw ModelFailure.changed }
            guard result.exitCode == 0 else {
                throw GitFailure(
                    message: L10n.text("交互式变基未完成"),
                    details: String(
                        decoding: result.stderr + Data("\n".utf8) + result.stdout, as: UTF8.self),
                    exitCode: result.exitCode)
            }
            let actualTree = try await self.singleCommitTree(head, engine: self.singleCommitEngine)
            let actualExpectedCommitCount = plan.steps.reduce(into: 0) { count, step in
                if [.pick, .reword, .edit].contains(step.action) { count += 1 }
            }
            let actualCount = try await self.singleCommitEngine.run(
                ["rev-list", "--count", plan.upstream.oid + ".." + head], in: self.location.root,
                outputLimit: 1024
            ).text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard preview.conflicts.isEmpty, actualTree == preview.resultTree,
                Int(actualCount) == actualExpectedCommitCount
            else {
                throw RebaseOutcomeUnknown(
                    previousHead: plan.head, observedHead: head,
                    details: L10n.text("交互式变基完成后的树或提交数量与预览不一致。"),
                    originalReference: originalReference)
            }
            keepDirectoryForRecovery = false
            return .completed(head)
        }
    }

    private func prepareInteractiveRebaseDirect(upstream: GitBranch) async throws
        -> InteractiveRebasePlan
    {
        try location.validateIdentity()
        let state = try await status()
        guard let head = state.head, !state.isDetached, state.files.isEmpty, state.sequencer == .none else {
            throw ModelFailure.unsupported(L10n.text("交互式变基前请回到本地分支并保持工作区干净。"))
        }
        let freshUpstream = try await freshBranch(upstream)
        let ancestor = try await singleCommitEngine.run(
            ["merge-base", "--is-ancestor", freshUpstream.oid, head], in: location.root, accepted: [0, 1])
        guard ancestor.exitCode == 0 else {
            throw ModelFailure.unsupported(L10n.text("目标提交不是当前分支的祖先，请选择线性范围。"))
        }
        let merges = try await singleCommitEngine.run(
            ["rev-list", "--merges", freshUpstream.oid + ".." + head], in: location.root,
            accepted: [0], outputLimit: InteractiveRebaseBudget.bytes)
        guard merges.stdout.isEmpty else {
            throw ModelFailure.unsupported(L10n.text("交互式变基首版只支持线性提交序列。"))
        }
        let ids = try rebaseObjectIDs(
            await singleCommitEngine.run(
                [
                    "rev-list", "--reverse", "--topo-order",
                    "--max-count=\(InteractiveRebaseBudget.commits + 1)",
                    freshUpstream.oid + ".." + head, "--",
                ], in: location.root,
                outputLimit: InteractiveRebaseBudget.bytes
            ).stdout)
        guard ids.count <= InteractiveRebaseBudget.commits else { throw RebaseBudget.exceeded }
        let commits = try await rebaseCommits(ids)
        var paths: Set<String> = []
        for revision in [freshUpstream.oid] + ids {
            paths.formUnion(try await rebaseTreePaths(revision))
        }
        let index = try await singleCommitIndex()
        let unpublished = Set(
            try rebaseObjectIDs(
                await singleCommitEngine.run(
                    [
                        "rev-list", "--max-count=\(InteractiveRebaseBudget.commits + 1)", head, "--not",
                        freshUpstream.oid, "--remotes", "--",
                    ],
                    in: location.root, outputLimit: InteractiveRebaseBudget.bytes
                ).stdout))
        try await StashWorktreeGuard.validate(paths: paths, tracked: index.paths, location: location)
        let steps = commits.map {
            InteractiveRebaseStep(id: $0.id, subject: $0.message, author: $0.author)
        }
        return InteractiveRebasePlan(
            branch: state.branch, head: head, upstream: freshUpstream, steps: steps,
            publishedCommits: Set(ids).subtracting(unpublished),
            location: location, index: index.raw, writePaths: paths)
    }

    public func validateInteractiveSteps(
        _ steps: [InteractiveRebaseStep], sourceIDs: Set<String>
    ) throws {
        guard !steps.isEmpty, steps.count <= InteractiveRebaseBudget.commits,
            steps.allSatisfy({ GitObjectID.valid($0.id) }),
            Set(steps.map(\.id)) == sourceIDs, Set(steps.map(\.id)).count == steps.count
        else { throw ModelFailure.changed }
        var hasPreviousKeptCommit = false
        var messageBytes = 0
        for step in steps {
            messageBytes += step.message?.utf8.count ?? 0
            guard messageBytes <= InteractiveRebaseBudget.bytes / 2 else { throw RebaseBudget.exceeded }
            switch step.action {
            case .reword:
                guard let message = step.message, !message.isEmpty,
                    !message.utf8.contains(0), message.utf8.count <= 1024 * 1024
                else { throw ModelFailure.unsupported(L10n.text("请提供有限大小且有效的提交说明。")) }
                hasPreviousKeptCommit = true
            case .squash:
                guard hasPreviousKeptCommit else {
                    throw ModelFailure.unsupported(L10n.text("压缩提交必须跟在一个保留的提交之后。"))
                }
                if let message = step.message {
                    guard !message.isEmpty, !message.utf8.contains(0), message.utf8.count <= 1024 * 1024
                    else {
                        throw ModelFailure.unsupported(L10n.text("请提供有限大小且有效的合并提交说明。"))
                    }
                }
            case .fixup:
                guard hasPreviousKeptCommit else {
                    throw ModelFailure.unsupported(L10n.text("修正提交必须跟在一个保留的提交之后。"))
                }
                guard step.message == nil else { throw ModelFailure.changed }
            case .pick, .edit:
                guard step.message == nil else { throw ModelFailure.changed }
                hasPreviousKeptCommit = true
            case .drop:
                guard step.message == nil else { throw ModelFailure.changed }
            }
        }
        guard steps.contains(where: { $0.action != .drop }) else {
            throw ModelFailure.unsupported(L10n.text("至少保留一个提交。"))
        }
    }

    private func interactiveDirectory() throws -> URL {
        var template = Array(
            (FileManager.default.temporaryDirectory.appending(path: "wegit-interactive-XXXXXX").path + "\0")
                .utf8
        ).map { CChar($0) }
        guard let path = mkdtemp(&template) else { throw ProcessFailure.outputWrite(errno) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private func writeInteractiveTodo(_ steps: [InteractiveRebaseStep], to url: URL) throws {
        let lines = steps.map { "\($0.action.gitCommand) \($0.id)" }.joined(separator: "\n")
        try Data((lines + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeInteractiveMessages(_ steps: [InteractiveRebaseStep], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        var paths: [String] = []
        func messagePath(_ message: String, index: Int) throws -> URL {
            let path = directory.appending(path: "message-\(index)")
            try Data(message.utf8).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return path
        }
        for (index, step) in steps.enumerated() where step.action == .reword {
            guard let message = step.message else { throw ModelFailure.changed }
            paths.append(step.id + "\t" + (try messagePath(message, index: index)).path)
        }
        var index = 0
        while index < steps.count {
            guard steps[index].action == .squash || steps[index].action == .fixup else {
                index += 1
                continue
            }
            let start = index
            var message: String?
            while index < steps.count, steps[index].action == .squash || steps[index].action == .fixup {
                if steps[index].action == .squash, let value = steps[index].message { message = value }
                index += 1
            }
            guard let message else { continue }
            let path = try messagePath(message, index: start)
            for step in steps[start..<index] { paths.append(step.id + "\t" + path.path) }
        }
        try Data((paths.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeInteractiveScript(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}
