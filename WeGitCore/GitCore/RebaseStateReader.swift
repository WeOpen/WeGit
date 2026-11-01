import Foundation

extension RepositoryService {
    @concurrent
    public func rebaseRecovery() async throws -> RebaseRecovery? {
        try await queue.perform { try await status().rebaseRecovery }
    }

    @concurrent
    func readRebaseRecovery(for state: RepositoryStatus) async throws -> RebaseRecovery? {
        guard state.sequencer == .rebase, let head = state.head else { return nil }
        let snapshot = try await rebaseMetadataSnapshot()
        func text(_ name: String) -> String? {
            snapshot.files[name].flatMap { String(data: $0.bytes, encoding: .utf8)?.removingLastNewline }
        }
        guard let original = text("orig-head"), GitObjectID.valid(original),
            let branch = text("head-name"), branch.hasPrefix("refs/heads/"),
            Self.rebaseLabelValid(String(branch.dropFirst("refs/heads/".count))),
            let onto = text("onto"), GitObjectID.valid(onto)
        else { return nil }
        let stopped = text(snapshot.backend == .merge ? "stopped-sha" : "original-commit")
        guard stopped == nil || GitObjectID.valid(stopped!) else { return nil }
        let todo = text("git-rebase-todo") ?? ""
        let done = text("done") ?? ""
        func count(_ value: String) throws -> Int {
            let count = value.split(separator: "\n").filter {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return !line.isEmpty && !line.hasPrefix("#")
            }.count
            guard count <= RebaseBudget.steps else { throw RebaseBudget.exceeded }
            return count
        }
        let completed =
            snapshot.backend == .merge ? try count(done) : max(0, (Int(text("next") ?? "") ?? 1) - 1)
        var remainingCount =
            snapshot.backend == .merge ? try count(todo) : max(0, (Int(text("last") ?? "") ?? 0) - completed)
        guard completed + remainingCount <= RebaseBudget.steps else { throw RebaseBudget.exceeded }
        var restriction: String?
        var abortRestriction: String?
        var remaining: [RebaseStep] = []
        var originals: [String] = []
        var rescheduled: String?
        var interactiveSequence = false
        var interactiveEditPause = false
        var interactiveSession: InteractiveRebaseSessionDescriptor?
        var expectedCommitCount: Int?
        var completedReplay: [RebaseStep] = []
        if snapshot.backend == .merge {
            do {
                let completedSteps = try await rebaseTodoSteps(done)
                completedReplay = completedSteps
                remaining = try await rebaseTodoSteps(todo)
                let sequence = completedSteps + remaining
                interactiveSequence = sequence.contains(where: \.isInteractiveTransform)
                var commitCount = sequence.filter(\.createsCommit).count
                var seen: Set<String> = []
                originals = sequence.compactMap(\.object).filter {
                    seen.insert($0).inserted
                }
                if stopped == nil, let first = remaining.first, first == completedSteps.last {
                    // Git 2.54 leaves a failed pick in both done and todo.
                    // Newer Git records the same retry as stopped-sha and
                    // clears todo, so normalize both layouts here.
                    rescheduled = first.object
                    if first.createsCommit { commitCount -= 1 }
                } else if snapshot.files["gpg_sign_opt"] != nil, let stopped,
                    snapshot.markers["CHERRY_PICK_HEAD"].flatMap({
                        String(data: $0.bytes, encoding: .utf8)?.removingLastNewline
                    }) == stopped,
                    case .pick(let lastObject)? = completedSteps.last, lastObject == stopped
                {
                    // Git 2.56 records a failed signed pick in stopped-sha.
                    // A conflict can have the same marker, so only classify it
                    // as a retry when a read-only replay is clean.
                    let retry = try await rebaseReplayPreview(
                        steps: [.pick(lastObject)], head: head, onto: onto)
                    if retry.conflicts.isEmpty {
                        guard completed + remainingCount < RebaseBudget.steps else {
                            throw RebaseBudget.exceeded
                        }
                        rescheduled = lastObject
                        remainingCount += 1
                    }
                }
                expectedCommitCount = commitCount
                let history = Set(
                    try rebaseObjectIDs(
                        await singleCommitEngine.run(
                            ["rev-list", "--max-count=\(RebaseBudget.commits + 1)", original, "--"],
                            in: location.root, outputLimit: RebaseBudget.metadataBytes
                        ).stdout))
                guard originals.count <= RebaseBudget.commits, Set(originals).isSubset(of: history) else {
                    throw ModelFailure.unsupported(L10n.text("此序列包含原分支范围之外的提交，请在 Terminal 中继续。"))
                }
            } catch {
                restriction = error.localizedDescription
            }
        } else {
            restriction = L10n.text("此 Apply 后端序列请在 Terminal 中继续；可以核对后中止。")
        }
        if snapshot.files["autostash"] != nil || snapshot.files["update-refs"] != nil {
            restriction = L10n.text("此外部序列包含自动 Stash 或其他引用更新，请在 Terminal 中处理。")
            abortRestriction = restriction
        }
        if let script = snapshot.files["author-script"] {
            let sourceID = stopped ?? rescheduled ?? originals.last
            if let sourceID, let source = try await rebaseCommits([sourceID]).first {
                if !Self.rebaseAuthorScriptCompatible(script.bytes, source: source) {
                    restriction = L10n.text("此变基的作者信息或合并策略无法核对，请在 Terminal 中继续。")
                }
            } else {
                restriction = L10n.text("此变基的作者信息或合并策略无法核对，请在 Terminal 中继续。")
            }
        }
        if let strategy = text("strategy"), !["ort", "recursive", "resolve"].contains(strategy) {
            restriction = L10n.text("此变基的作者信息或合并策略无法核对，请在 Terminal 中继续。")
        }
        if let options = text("strategy_opts"), !options.isEmpty {
            restriction = L10n.text("此变基的作者信息或合并策略无法核对，请在 Terminal 中继续。")
        }
        var interactiveMessageEditor: InteractiveRebaseEditorDescriptor?
        if let marker = snapshot.files["wegit-interactive-session"] {
            do {
                let descriptor = try InteractiveRebaseSessionDescriptor.read(marker: marker.bytes)
                try descriptor.validate()
                guard descriptor.manifest.originalHead == original,
                    descriptor.manifest.branch == branch,
                    descriptor.manifest.upstream == onto
                else { throw ModelFailure.changed }
                interactiveSession = descriptor
                var confirmedSequence = completedReplay
                var pendingSequence = remaining
                if rescheduled != nil, pendingSequence.first == confirmedSequence.last {
                    pendingSequence.removeFirst()
                }
                confirmedSequence.append(contentsOf: pendingSequence)
                let commands = confirmedSequence.compactMap(\.interactiveCommand)
                guard commands.count == confirmedSequence.count,
                    InteractiveRebaseEditorDescriptor.digest(
                        Data((commands.joined(separator: "\n") + "\n").utf8)
                    ) == descriptor.manifest.sequenceDigest
                else { throw ModelFailure.changed }
                interactiveSequence = true
                expectedCommitCount = descriptor.manifest.expectedCommitCount
                if let stopped, completedReplay.last == .edit(stopped), state.conflicts.isEmpty,
                    snapshot.markers["CHERRY_PICK_HEAD"] == nil
                {
                    interactiveEditPause = true
                }
                if let editor = try descriptor.manifest.messageEditor() {
                    interactiveMessageEditor = editor
                }
            } catch {
                restriction = L10n.text("交互式变基的私有序列清单缺失，请在 Terminal 中核对。")
            }
        } else if interactiveSequence {
            restriction = L10n.text("交互式变基的私有序列清单缺失，请在 Terminal 中核对。")
        }
        let branchObject = try await singleCommitEngine.run(
            ["rev-parse", "--verify", branch], in: location.root, accepted: [0, 128]
        ).text.removingLastNewline
        if branchObject != original {
            restriction = L10n.text("原分支已被其他程序改变，请在 Terminal 中核对恢复。")
            abortRestriction = restriction
        }
        let labels = try await rebaseRewrittenLabels()
        let index = try await rebaseIndexSnapshot()
        guard try await rebaseMetadataSnapshot() == snapshot,
            try await rebaseRewrittenLabels() == labels,
            try await self.head() == head
        else { throw ModelFailure.changed }
        return RebaseRecovery(
            backend: snapshot.backend, originalHead: original, branchRef: branch, onto: onto,
            stoppedCommit: stopped, rescheduledCommit: rescheduled,
            completedSteps: completed, remainingSteps: remainingCount, head: head,
            continuationRestriction: restriction, abortRestriction: abortRestriction,
            interactiveSequence: interactiveSequence,
            interactiveEditPause: interactiveEditPause, expectedCommitCount: expectedCommitCount,
            interactiveSession: interactiveSession,
            interactiveMessageEditor: interactiveMessageEditor,
            location: location, directoryIdentity: snapshot.identity, files: snapshot.files,
            markers: snapshot.markers, rewritten: labels, remaining: remaining, originals: originals,
            index: index)
    }

    func rebaseTodoSteps(_ value: String) async throws -> [RebaseStep] {
        var steps: [RebaseStep] = []
        var tokens: Set<String> = []
        func object(_ token: String) throws -> String {
            guard (4...64).contains(token.count),
                token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else {
                throw ModelFailure.changed
            }
            tokens.insert(token)
            return token
        }
        func label(_ name: String) throws -> String {
            guard Self.rebaseLabelValid(name) else { throw ModelFailure.changed }
            return name
        }
        for line in value.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let command = fields.first, !command.hasPrefix("#") else { continue }
            switch command {
            case "pick", "p":
                guard fields.count >= 2 else { throw ModelFailure.changed }
                steps.append(.pick(try object(fields[1])))
            case "reword", "r":
                guard fields.count >= 2 else { throw ModelFailure.changed }
                steps.append(.reword(try object(fields[1])))
            case "edit", "e":
                guard fields.count >= 2 else { throw ModelFailure.changed }
                steps.append(.edit(try object(fields[1])))
            case "squash", "s":
                guard fields.count >= 2 else { throw ModelFailure.changed }
                steps.append(.squash(try object(fields[1])))
            case "fixup", "f":
                guard fields.count >= 2 else { throw ModelFailure.changed }
                steps.append(.fixup(try object(fields[1])))
            case "drop", "d":
                guard fields.count >= 2 else { throw ModelFailure.changed }
                steps.append(.drop(try object(fields[1])))
            case "label", "l":
                guard fields.count == 2 else { throw ModelFailure.changed }
                steps.append(.label(try label(fields[1])))
            case "reset", "t":
                guard fields.count == 2 || fields.dropFirst(2).first == "#" else {
                    throw ModelFailure.changed
                }
                steps.append(.reset(try label(fields[1])))
            case "merge", "m":
                guard fields.count >= 4, fields[1] == "-C" else {
                    throw ModelFailure.unsupported(L10n.text("此合并步骤需要编辑或选择父线，请在 Terminal 中处理。"))
                }
                let labels = fields.dropFirst(3).prefix { !$0.hasPrefix("#") }
                guard labels.count == 1 else { throw ModelFailure.changed }
                steps.append(.merge(try object(fields[2]), try labels.map(label)))
            case "noop":
                guard fields.count == 1 else { throw ModelFailure.changed }
                steps.append(.noop)
            default:
                throw ModelFailure.unsupported(L10n.text("此序列含尚未支持的交互动作或外部命令，请在 Terminal 中继续。"))
            }
        }
        guard steps.count <= RebaseBudget.steps else { throw RebaseBudget.exceeded }
        let selected = tokens.sorted()
        guard !selected.isEmpty else { return steps }
        let output = try await singleCommitEngine.run(
            ["cat-file", "--batch-check=%(objectname) %(objecttype)"], in: location.root,
            input: Data((selected.joined(separator: "\n") + "\n").utf8),
            outputLimit: RebaseBudget.metadataBytes
        ).text
        let rows = output.split(separator: "\n")
        guard rows.count == selected.count else { throw ModelFailure.changed }
        var full: [String: String] = [:]
        for (token, row) in zip(selected, rows) {
            let fields = row.split(separator: " ")
            guard fields.count == 2, fields[1] == "commit", GitObjectID.valid(String(fields[0])),
                fields[0].hasPrefix(token)
            else {
                throw ModelFailure.changed
            }
            full[token] = String(fields[0])
        }
        return steps.map { step in
            switch step {
            case .pick(let id): .pick(full[id]!)
            case .reword(let id): .reword(full[id]!)
            case .edit(let id): .edit(full[id]!)
            case .squash(let id): .squash(full[id]!)
            case .fixup(let id): .fixup(full[id]!)
            case .drop(let id): .drop(full[id]!)
            case .merge(let id, let labels): .merge(full[id]!, labels)
            default: step
            }
        }
    }

    func rebaseIndexSnapshot() async throws -> Data {
        try await singleCommitEngine.run(
            ["ls-files", "--stage", "-v", "-z"], in: location.root,
            outputLimit: RebaseBudget.metadataBytes
        ).stdout
    }

    func rebaseIndexPaths(_ bytes: Data) throws -> Set<String> {
        guard bytes.isEmpty || bytes.last == 0 else { throw ModelFailure.changed }
        var paths: Set<String> = []
        for row in bytes.split(separator: 0) {
            guard let tab = row.firstIndex(of: 9),
                let header = String(data: row[..<tab], encoding: .utf8),
                let path = String(data: row[row.index(after: tab)...], encoding: .utf8)
            else { throw ModelFailure.changed }
            let fields = header.split(separator: " ")
            guard fields.count == 4, ["H", "M"].contains(fields[0]),
                ["100644", "100755", "120000"].contains(fields[1]), GitObjectID.valid(String(fields[2])),
                ["0", "1", "2", "3"].contains(fields[3])
            else { throw ModelFailure.unsupported(L10n.text("请先处理特殊索引标记或子模块，再恢复变基。")) }
            try validate(path)
            paths.insert(path)
        }
        guard paths.count <= RebaseBudget.entries else { throw RebaseBudget.exceeded }
        return paths
    }
}
