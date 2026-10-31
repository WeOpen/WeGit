import Foundation

extension RepositoryService {
    public func prepareInteractiveRebase(upstream: GitBranch) async throws -> InteractiveRebasePlan {
        try await queue.perform {
            try await self.prepareInteractiveRebaseDirect(upstream: upstream)
        }
    }

    public func executeInteractiveRebase(_ plan: InteractiveRebasePlan) async throws
        -> InteractiveRebaseOutcome
    {
        try await withSharedOperation {
            guard plan.location == self.location else { throw ModelFailure.changed }
            let fresh = try await self.prepareInteractiveRebaseDirect(upstream: plan.upstream)
            guard fresh.branch == plan.branch, fresh.head == plan.head,
                fresh.upstream == plan.upstream, fresh.index == plan.index,
                fresh.writePaths == plan.writePaths
            else { throw ModelFailure.changed }
            try self.validateInteractiveSteps(plan.steps, sourceIDs: Set(fresh.steps.map(\.id)))
            guard !plan.steps.isEmpty else { return .unchanged }

            let directory = try self.interactiveDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let todo = directory.appending(path: "todo")
            let sequenceEditor = directory.appending(path: "sequence-editor.sh")
            let messageEditor = directory.appending(path: "message-editor.sh")
            try self.writeInteractiveTodo(plan.steps, to: todo)
            try self.writeInteractiveScript(
                """
                #!/bin/sh
                set -eu
                test "$#" -eq 1
                test -f "$1"
                cp "\(todo.path)" "$1"
                """, to: sequenceEditor)

            var commandEngine = self.singleCommitEngine
            commandEngine.environment["GIT_SEQUENCE_EDITOR"] = sequenceEditor.path
            if plan.steps.contains(where: { $0.action == .reword && $0.message != nil }) {
                let messages = directory.appending(path: "messages")
                try self.writeInteractiveMessages(plan.steps, to: messages)
                try self.writeInteractiveScript(
                    """
                    #!/bin/sh
                    set -eu
                    test "$#" -eq 1
                    counter="\(directory.appending(path: "message-counter").path)"
                    if test ! -f "$counter"; then printf '1' > "$counter"; fi
                    n=$(cat "$counter")
                    source=$(sed -n "${n}p" "\(messages.path)")
                    test -n "$source"
                    cp "$source" "$1"
                    printf '%s' "$((n + 1))" > "$counter"
                    """, to: messageEditor)
                commandEngine.environment["GIT_EDITOR"] = messageEditor.path
            } else {
                commandEngine.environment["GIT_EDITOR"] = "/usr/bin/true"
            }

            let result: ProcessResult
            let originalReference = try await self.protectRebaseOriginal(plan.head)
            try await StashWorktreeGuard.validate(
                paths: plan.writePaths, tracked: try self.rebaseIndexPaths(plan.index),
                location: self.location)
            do {
                result = try await commandEngine.run(
                    [
                        "rebase", "--interactive", "--no-autostash", "--no-update-refs",
                        "--no-fork-point", "--reapply-cherry-picks", "--empty=keep", "--keep-empty",
                        "--no-autosquash", "--no-rerere-autoupdate", "--strategy=ort",
                        "--onto", plan.upstream.oid, plan.upstream.oid,
                    ], in: self.location.root, accepted: [0, 1], timeout: 120)
            } catch {
                let observed = try await self.status()
                if let recovery = try await self.readRebaseRecovery(for: observed) {
                    if !observed.conflicts.isEmpty {
                        return .conflicts(recovery, observed.conflicts.count)
                    }
                    return .paused(recovery)
                }
                if observed.sequencer == .none, observed.head == plan.head,
                    observed.branch == plan.branch, observed.files.isEmpty,
                    try await self.singleCommitIndex().raw == plan.index
                {
                    throw error
                }
                throw RebaseOutcomeUnknown(
                    previousHead: plan.head, observedHead: observed.head,
                    details: error.localizedDescription, originalReference: originalReference)
            }
            let state = try await self.status()
            if let recovery = try await self.readRebaseRecovery(for: state) {
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
        try await StashWorktreeGuard.validate(paths: paths, tracked: index.paths, location: location)
        let steps = commits.map {
            InteractiveRebaseStep(id: $0.id, subject: $0.message, author: $0.author)
        }
        return InteractiveRebasePlan(
            branch: state.branch, head: head, upstream: freshUpstream, steps: steps,
            location: location, index: index.raw, writePaths: paths)
    }

    private func validateInteractiveSteps(
        _ steps: [InteractiveRebaseStep], sourceIDs: Set<String>
    ) throws {
        guard !steps.isEmpty, steps.count <= InteractiveRebaseBudget.commits,
            steps.allSatisfy({ GitObjectID.valid($0.id) }),
            Set(steps.map(\.id)) == sourceIDs, Set(steps.map(\.id)).count == steps.count
        else { throw ModelFailure.changed }
        for step in steps {
            if step.action == .reword {
                guard let message = step.message, !message.isEmpty,
                    !message.utf8.contains(0), message.utf8.count <= 1024 * 1024
                else { throw ModelFailure.unsupported(L10n.text("请提供有限大小且有效的提交说明。")) }
            } else if step.message != nil {
                throw ModelFailure.changed
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
    }

    private func writeInteractiveMessages(_ steps: [InteractiveRebaseStep], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        var paths: [String] = []
        for (index, step) in steps.enumerated() where step.action == .reword {
            guard let message = step.message else { continue }
            let path = directory.appending(path: "message-\(index)")
            try Data(message.utf8).write(to: path, options: .atomic)
            paths.append(path.path)
        }
        try Data((paths.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }

    private func writeInteractiveScript(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
