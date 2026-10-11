import Foundation

extension RepositoryService {
    /// Local commit and remote push have independent outcomes. A push error never
    /// rolls back the commit, and callers retry using preparePush/push only.
    public func commitAndPush(
        message: String, amend: Bool, remote: GitRemote, branch: String,
        pushURLIndex: Int = 0, setUpstream: Bool = false, expectedHead: String?,
        onCommit: @Sendable (String) async -> Void = { _ in }
    ) async throws -> CommitPushResult {
        let localBranch = try await queue.perform {
            try await verifyHead(expectedHead)
            try await validateBranchName(branch)
            guard remote.pushURLs.indices.contains(pushURLIndex) else { throw ModelFailure.invalidPath }
            try await verifyRemote(remote)
            let state = try await status()
            guard !state.isDetached else {
                throw ModelFailure.unsupported("提交并推送前请切换到本地分支。")
            }
            return state.branch
        }
        let pinned = expectingBranch(localBranch)
        let committed = try await pinned.commit(message: message, amend: amend, expectedHead: expectedHead)
        await onCommit(committed)
        do {
            try await verifyRemote(remote)
            let plan = try await pinned.preparePush(
                remote: remote.name, branch: branch, pushURLIndex: pushURLIndex,
                setUpstream: setUpstream, expectedHead: committed)
            guard plan.remote == remote else { throw ModelFailure.changed }
            let result = try await pinned.push(plan)
            return CommitPushResult(commit: committed, push: result, failure: nil)
        } catch {
            return CommitPushResult(commit: committed, push: nil, failure: error)
        }
    }

    public func preparePush(
        remote name: String, branch: String, pushURLIndex: Int = 0,
        forceWithLease: Bool = false, setUpstream: Bool = false, expectedHead: String?
    ) async throws -> PushPlan {
        try await queue.perform {
            try await verifyHead(expectedHead)
            let state = try await status()
            guard let head = state.head, !state.isDetached, state.sequencer == .none, state.conflicts.isEmpty
            else {
                throw ModelFailure.unsupported("推送前请回到本地分支并完成当前 Git 操作。")
            }
            try await validateBranchName(branch)
            let remote = try await remoteDetails(name: name)
            guard remote.pushURLs.indices.contains(pushURLIndex) else { throw ModelFailure.invalidPath }
            let target = "refs/heads/" + branch
            let expected = try await remoteOID(remote, index: pushURLIndex, ref: target)
            try await verifyHead(expectedHead)
            return PushPlan(
                remote: remote, pushURLIndex: pushURLIndex, targetRef: target, localBranch: state.branch,
                head: head, expectedRemoteOID: expected, forceWithLease: forceWithLease,
                setUpstream: setUpstream, location: location)
        }
    }

    private func remoteOID(_ remote: GitRemote, index: Int, ref: String) async throws -> String? {
        let configuration = try pinnedRemote(remote, pushIndex: index)
        let output = try await engine.run(
            ["ls-remote", "--heads", "--", remote.name, ref], in: location.root,
            timeout: 120, outputLimit: 64 * 1024, configuration: configuration)
        guard output.stdout.isEmpty || output.stdout.last == 10,
            let text = String(data: output.stdout, encoding: .utf8)
        else {
            throw ModelFailure.invalidOutput("远端引用查询被截断")
        }
        var result: String?
        for row in text.split(separator: "\n") {
            let fields = row.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1] == ref, GitObjectID.valid(String(fields[0])), result == nil
            else {
                throw ModelFailure.invalidOutput("远端引用查询结果不匹配")
            }
            result = String(fields[0])
        }
        return result
    }

    public func push(_ plan: PushPlan) async throws -> PushResult {
        try await queue.perform {
            guard plan.location == location else { throw ModelFailure.repositoryReplaced }
            try await verifyHead(plan.head)
            let state = try await status()
            guard state.branch == plan.localBranch, state.sequencer == .none, state.conflicts.isEmpty else {
                throw ModelFailure.changed
            }
            try await verifyRemote(plan.remote)
            var arguments = ["push", "--porcelain", "--recurse-submodules=no"]
            if plan.forceWithLease {
                arguments.append("--force-with-lease=\(plan.targetRef):\(plan.expectedRemoteOID ?? "")")
            }
            let refspec = "\(plan.head):\(plan.targetRef)"
            arguments += ["--", plan.remote.name, refspec]
            var configuration = try pinnedRemote(plan.remote, pushIndex: plan.pushURLIndex)
            configuration += [("push.followTags", "false"), ("remote.\(plan.remote.name).mirror", "false")]
            try await verifyHead(plan.head)
            do {
                _ = try await engine.run(
                    arguments, in: location.root, timeout: 300, configuration: configuration)
            } catch {
                if case ProcessFailure.launch = error { throw error }
                if let failure = error as? GitFailure, failure.rejectedPushRefspec == refspec { throw error }
                let details = (error as? GitFailure)?.details ?? Redaction.text(error.localizedDescription)
                throw PushOutcomeUnknown(plan: plan, receipt: PushReceipt(plan), details: details)
            }
            guard plan.setUpstream else { return PushResult(upstreamConfigured: false, warning: nil) }
            do {
                try location.validateIdentity()
                let localRef = "refs/heads/" + plan.localBranch
                let current = try await engine.run(
                    ["rev-parse", "--verify", "--end-of-options", localRef], in: location.root
                ).text.removingLastNewline
                guard current == plan.head,
                    let tracking = trackingRef(for: plan.targetRef, remote: plan.remote)
                else {
                    return PushResult(upstreamConfigured: false, warning: "推送已完成；本地分支或跟踪映射已变化，上游未修改。")
                }
                _ = try await engine.run(
                    ["branch", "--set-upstream-to=" + tracking, "--", plan.localBranch], in: location.root)
                return PushResult(upstreamConfigured: true, warning: nil)
            } catch {
                return PushResult(
                    upstreamConfigured: false, warning: "推送已完成，上游设置未完成：\(error.localizedDescription)")
            }
        }
    }

    /// Reconstruct only an unchanged destination, without persisting URL credentials.
    public func restorePushPlan(_ receipt: PushReceipt) async throws -> PushPlan {
        try await queue.perform {
            try location.validateIdentity()
            guard receipt.repositoryID == location.persistenceID,
                GitObjectID.valid(receipt.head), receipt.targetRef.hasPrefix("refs/heads/"),
                receipt.expectedRemoteOID.map(GitObjectID.valid) ?? true
            else { throw ModelFailure.repositoryReplaced }
            try await validateBranchName(String(receipt.targetRef.dropFirst("refs/heads/".count)))
            try await validateBranchName(receipt.localBranch)
            guard let fingerprint = receipt.destinationFingerprint else {
                throw ModelFailure.unsupported(
                    "此前地址包含凭据或查询参数，无法从保存记录恢复。请手动核对原目标后标记已处理。")
            }
            let remote = try await remoteDetails(name: receipt.remoteName)
            guard remote.pushURLs.indices.contains(receipt.pushURLIndex),
                PushReceipt.fingerprint(remote.pushURLs[receipt.pushURLIndex], in: location.root)
                    == fingerprint
            else {
                throw ModelFailure.unsupported("此前推送地址已变化。请恢复原地址后核对，或手动核对原目标后标记已处理。")
            }
            return PushPlan(
                remote: remote, pushURLIndex: receipt.pushURLIndex, targetRef: receipt.targetRef,
                localBranch: receipt.localBranch, head: receipt.head,
                expectedRemoteOID: receipt.expectedRemoteOID,
                forceWithLease: receipt.forceWithLease, setUpstream: receipt.setUpstream, location: location)
        }
    }

    /// Only read the originally confirmed endpoint and ref. Local HEAD may have moved.
    public func verifyPushOutcome(_ plan: PushPlan) async throws -> PushVerification {
        try await queue.perform {
            guard plan.location == location else { throw ModelFailure.repositoryReplaced }
            try location.validateIdentity()
            let observed = try await remoteOID(plan.remote, index: plan.pushURLIndex, ref: plan.targetRef)
            try location.validateIdentity()
            return PushVerification(receipt: PushReceipt(plan), observedOID: observed)
        }
    }

    private func trackingRef(for ref: String, remote: GitRemote) -> String? {
        var destinations: Set<String> = []
        for raw in remote.fetchRefspecs where !raw.hasPrefix("^") {
            let value = raw.hasPrefix("+") ? String(raw.dropFirst()) : raw
            let pair = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if pair[0] == ref {
                destinations.insert(pair[1])
                continue
            }
            let source = pair[0].components(separatedBy: "*")
            let target = pair[1].components(separatedBy: "*")
            if source.count == 2, target.count == 2, ref.hasPrefix(source[0]), ref.hasSuffix(source[1]),
                ref.count >= source[0].count + source[1].count
            {
                let middle = ref.dropFirst(source[0].count).dropLast(source[1].count)
                destinations.insert(target[0] + middle + target[1])
            }
        }
        return destinations.count == 1 ? destinations.first : nil
    }

    public func preparePull(
        remote name: String, branch: String, strategy: PullStrategy, preserveMerges: Bool = false,
        createMergeCommit: Bool = false,
        expectedHead: String?
    ) async throws -> PullPlan {
        try await queue.perform {
            try await verifyHead(expectedHead)
            let state = try await status()
            guard let head = state.head, !state.isDetached, state.sequencer == .none, state.conflicts.isEmpty
            else {
                throw ModelFailure.unsupported("拉取前请回到本地分支并完成当前 Git 操作。")
            }
            try await validateBranchName(branch)
            let remote = try await remoteDetails(name: name)
            return PullPlan(
                remote: remote, targetRef: "refs/heads/" + branch, localBranch: state.branch,
                head: head, strategy: strategy, preserveMerges: preserveMerges,
                createMergeCommit: createMergeCommit, location: location)
        }
    }

    public func pull(_ plan: PullPlan) async throws -> PullResult {
        try await queue.perform {
            guard plan.location == location else { throw ModelFailure.repositoryReplaced }
            try await verifyHead(plan.head)
            let state = try await status()
            guard state.branch == plan.localBranch, state.sequencer == .none, state.conflicts.isEmpty else {
                throw ModelFailure.changed
            }
            try await verifyRemote(plan.remote)
            let configuration = try pinnedRemote(plan.remote)
            // FETCH_HEAD is shared with Terminal and other clients. A unique temporary
            // ref keeps this pull's fetched commit stable even if another fetch runs.
            let temporaryRef = "refs/wegit/pull/" + UUID().uuidString.lowercased()
            var fetched = false
            do {
                _ = try await engine.run(
                    [
                        "fetch", "--no-tags", "--no-write-fetch-head", "--", plan.remote.name,
                        plan.targetRef + ":" + temporaryRef,
                    ], in: location.root,
                    timeout: 300, configuration: configuration)
                fetched = true
                try await verifyHead(plan.head)
                let current = try await status()
                guard current.branch == plan.localBranch, current.sequencer == .none,
                    current.conflicts.isEmpty
                else { throw ModelFailure.changed }
                let fetchedOID = try await engine.run(
                    ["rev-parse", "--verify", "--end-of-options", temporaryRef + "^{commit}"],
                    in: location.root
                ).text.removingLastNewline
                guard GitObjectID.valid(fetchedOID) else { throw ModelFailure.invalidOutput("获取结果不是有效提交") }
                let arguments: [String]
                switch plan.strategy {
                case .fastForwardOnly:
                    arguments = ["merge", "--ff-only", "--no-edit", "--no-autostash", fetchedOID]
                case .merge:
                    arguments = [
                        "merge", plan.createMergeCommit ? "--no-ff" : "--ff", "--no-edit", "--no-autostash",
                        fetchedOID,
                    ]
                case .rebase:
                    arguments =
                        [
                            "rebase", "--no-autostash",
                            plan.preserveMerges ? "--rebase-merges" : "--no-rebase-merges", fetchedOID,
                        ]
                }
                try await verifyHead(plan.head)
                _ = try await engine.run(
                    arguments, in: location.root, timeout: 300,
                    configuration: [("rebase.updateRefs", "false")])
            } catch {
                let cleanupWarning = await removePullReference(temporaryRef)
                throw PullFailure(
                    fetched: fetched,
                    message: (fetched ? "获取已完成，整合未完成：" : "获取未完成：") + error.localizedDescription,
                    details: [(error as? GitFailure)?.details, cleanupWarning].compactMap { $0 }.joined(
                        separator: "\n"))
            }
            return PullResult(warning: await removePullReference(temporaryRef))
        }
    }

    private func removePullReference(_ ref: String) async -> String? {
        // The repository queue remains owned while cleanup runs. A fresh task is
        // intentionally not cancelled with the network operation it is cleaning up.
        await Task.detached {
            do {
                try location.validateIdentity()
                let current = try await engine.run(
                    ["rev-parse", "--verify", "--end-of-options", ref], in: location.root, accepted: [0, 128])
                guard current.exitCode == 0 else { return nil as String? }
                let oid = current.text.removingLastNewline
                guard GitObjectID.valid(oid) else { throw ModelFailure.invalidOutput("临时引用无效") }
                try location.validateIdentity()
                _ = try await engine.run(["update-ref", "-d", ref, oid], in: location.root)
                return nil
            } catch {
                return "临时拉取引用未清理（\(ref)）：\(error.localizedDescription)"
            }
        }.value
    }
}
