import Foundation
import Observation
import WeGitCore

enum SyncKind { case push, pull, commitAndPush }

extension AppState {
    func presentSync(_ kind: SyncKind) {
        guard let session,
            kind == .commitAndPush
                ? session.canCommitAndPush
                : session.canSync || kind == .push && session.canVerifyPendingPush
        else { return }
        if kind == .commitAndPush && session.amend,
            !confirm(
                title: L10n.text("修改上次提交并推送？"),
                message: L10n.text("将改写 \(session.status.head?.prefix(12) ?? "")，然后尝试普通推送。远端拒绝时本地新提交仍会保留。"),
                action: L10n.text("选择推送目标"))
        {
            return
        }
        syncRequest = SyncRequest(kind: kind, session: session)
    }
}

struct SyncRequest: Identifiable {
    let id = UUID()
    let kind: SyncKind
    let session: RepositorySession
}

@Observable @MainActor
final class SyncState {
    let session: RepositorySession
    let kind: SyncKind
    let localBranch: String
    let initialHead: String?
    let commitMessage: String
    let amend: Bool
    let stagedCount: Int
    var remotes: [GitRemote] = []
    var remoteName = ""
    var branch: String
    var pushIndex = 0
    var setUpstream = false
    var forceWithLease = false
    var leaseAcknowledged = false
    var strategy: PullStrategy?
    var preserveMerges = false
    var createMergeCommit = false
    var preference: PullPreference?
    var pushPlan: PushPlan?
    var verificationReceipt: PushReceipt?
    var verificationResult: PushVerification?
    var completionTitle: String?
    private var verificationPlan: PushPlan?
    var committedOID: String?
    var isLoading = true
    var isPreparing = false
    var completed = false
    var warning: String?
    var error: String?
    var details = ""
    private var preparation: Task<Void, Never>?

    init(request: SyncRequest) {
        session = request.session
        kind = request.kind
        localBranch = session.status.branch
        branch = localBranch
        initialHead = session.status.head
        commitMessage = session.message
        amend = session.amend
        stagedCount = session.status.files.filter(\.staged).count
    }

    var selectedRemote: GitRemote? { remotes.first { $0.name == remoteName } }
    var committing: Bool { kind == .commitAndPush && committedOID == nil }
    var isWorking: Bool { isPreparing || session.isBusy }
    var fieldsLocked: Bool {
        isLoading || isWorking || pushPlan != nil || verificationReceipt != nil || completed
    }
    var targetValid: Bool {
        selectedRemote != nil && !branch.isEmpty
            && (kind == .pull || selectedRemote?.pushURLs.indices.contains(pushIndex) == true)
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        if kind == .push, let receipt = session.pendingPush?.verification {
            verificationReceipt = receipt
            remoteName = receipt.remoteName
            branch = String(receipt.targetRef.dropFirst("refs/heads/".count))
            pushIndex = receipt.pushURLIndex
            return
        }
        let service = session.service.expectingBranch(localBranch)
        do {
            let head = committedOID ?? initialHead
            let values = try await service.queue.perform {
                try await service.verifyHead(head)
                let remotes = try await service.remoteDetails()
                let upstream = try await service.upstreamTarget()
                let preference = try await service.pullPreference()
                return (remotes, upstream, preference)
            }
            try Task.checkCancellation()
            remotes = values.0
            if let upstream = values.1, remotes.contains(where: { $0.name == upstream.remote }) {
                remoteName = upstream.remote
                branch = upstream.branch
            } else if remotes.count == 1 {
                remoteName = remotes[0].name
            }
            setUpstream = values.1 == nil
            if kind == .push, let pending = session.pendingPush,
                pending.commit == initialHead, pending.localBranch == localBranch,
                remotes.contains(where: { $0.name == pending.remote })
            {
                remoteName = pending.remote
                branch = pending.branch
                pushIndex =
                    selectedRemote?.pushURLs.indices.contains(pending.pushIndex) == true
                    ? pending.pushIndex : 0
            }
            preference = values.2
            strategy = values.2.strategy
            preserveMerges = values.2.preserveMerges
            createMergeCommit = values.2.createMergeCommit
            if remotes.isEmpty { error = L10n.text("尚未配置远端，请先在 Git 中添加 Remote。") }
        } catch is CancellationError {} catch { show(error) }
    }

    func checkPush() {
        guard targetValid, !isWorking, verificationReceipt == nil else { return }
        isPreparing = true
        error = nil
        details = ""
        pushPlan = nil
        leaseAcknowledged = false
        let remote = remoteName
        let branch = branch
        let index = pushIndex
        let force = forceWithLease
        let upstream = setUpstream
        let head = committedOID ?? initialHead
        let service = session.service.expectingBranch(localBranch)
        preparation = Task {
            defer {
                isPreparing = false
                preparation = nil
            }
            do {
                let plan = try await service.preparePush(
                    remote: remote, branch: branch, pushURLIndex: index, forceWithLease: force,
                    setUpstream: upstream, expectedHead: head)
                try Task.checkCancellation()
                pushPlan = plan
            } catch { show(error) }
        }
    }

    func push() {
        guard let plan = pushPlan, !isWorking, verificationReceipt == nil,
            !plan.forceWithLease || leaseAcknowledged
        else { return }
        error = nil
        session.performResult(
            L10n.text("推送"), onSuccess: { self.completed = true },
            operation: { service in
                do {
                    let result = try await service.push(plan)
                    await MainActor.run {
                        self.warning = result.warning
                        if self.session.pendingPushCommit == plan.head {
                            self.session.pendingPush = nil
                        }
                    }
                    return .completed(message: L10n.text("推送完成"), warning: result.warning)
                } catch {
                    await MainActor.run {
                        self.pushPlan = nil
                        self.show(error)
                    }
                    throw error
                }
            })
    }

    func verifyPush() {
        guard let receipt = verificationReceipt, !isLoading, !isWorking else { return }
        error = nil
        details = ""
        let originalPlan = verificationPlan
        session.performResult(L10n.text("核对远端结果")) { service in
            do {
                let plan: PushPlan
                if let originalPlan {
                    plan = originalPlan
                } else {
                    plan = try await service.restorePushPlan(receipt)
                }
                let result = try await service.verifyPushOutcome(plan)
                await MainActor.run {
                    self.verificationPlan = plan
                    self.verificationResult = result
                    self.warning = result.message
                    if result.matches {
                        self.completed = true
                        self.completionTitle = L10n.text("远端目标已确认")
                        if self.session.pendingPush?.verification == receipt {
                            self.session.pendingPush = nil
                        }
                    }
                }
                if result.matches { return .completed(message: result.message) }
                return .needsReview(message: result.message, details: plan.feedbackTargetDetails)
            } catch {
                await MainActor.run { self.show(error) }
                throw error
            }
        }
    }

    var canPrepareNewPush: Bool {
        verificationResult != nil && verificationResult?.matches == false && session.canSync
            && session.status.head == (committedOID ?? initialHead) && session.status.branch == localBranch
    }

    func prepareNewPush() async {
        guard canPrepareNewPush else { return }
        if session.pendingPush?.verification == verificationReceipt {
            session.pendingPush?.verification = nil
        }
        verificationReceipt = nil
        verificationResult = nil
        verificationPlan = nil
        forceWithLease = false
        leaseAcknowledged = false
        warning = nil
        await load()
    }

    func commitAndPush() {
        guard let remote = selectedRemote, targetValid, committing, !isWorking else { return }
        error = nil
        let branch = branch
        let index = pushIndex
        let upstream = setUpstream
        let text = commitMessage
        let amend = amend
        let head = initialHead
        let localBranch = localBranch
        session.performResult(
            L10n.text("提交并推送"), context: .commit, onSuccess: { self.completed = true },
            operation: { service in
                do {
                    let result = try await service.expectingBranch(localBranch).commitAndPush(
                        message: text, amend: amend, remote: remote, branch: branch,
                        pushURLIndex: index, setUpstream: upstream, expectedHead: head
                    ) { oid in
                        await MainActor.run {
                            self.committedOID = oid
                            self.session.pendingPush = PendingPushRecord(
                                commit: oid, localBranch: localBranch,
                                remote: remote.name, branch: branch, pushIndex: index)
                            self.session.completeCommit(message: text)
                            self.session.activityLabel = L10n.text("推送")
                        }
                    }
                    if let failure = result.failure { throw failure }
                    await MainActor.run {
                        self.warning = result.push?.warning
                        self.session.pendingPush = nil
                    }
                    return .completed(
                        message: L10n.text("\(L10n.text("提交并推送"))完成"), warning: result.push?.warning)
                } catch {
                    await MainActor.run { self.show(error) }
                    throw error
                }
            })
    }

    func pull() {
        guard let strategy, targetValid, !isWorking else { return }
        error = nil
        let remote = remoteName
        let branch = branch
        let head = initialHead
        let localBranch = localBranch
        let preserve = preserveMerges
        let mergeCommit = createMergeCommit
        session.performResult(
            L10n.text("拉取（\(strategy.title)）"), onSuccess: { self.completed = true },
            operation: { service in
                do {
                    let pinned = service.expectingBranch(localBranch)
                    let plan = try await pinned.preparePull(
                        remote: remote, branch: branch, strategy: strategy,
                        preserveMerges: preserve, createMergeCommit: mergeCommit, expectedHead: head)
                    let result = try await pinned.pull(plan)
                    await MainActor.run { self.warning = result.warning }
                    return .completed(message: L10n.text("拉取完成"), warning: result.warning)
                } catch {
                    await MainActor.run { self.show(error) }
                    throw error
                }
            })
    }

    func cancel() {
        if isPreparing { preparation?.cancel() } else { session.cancel() }
    }

    func stopPreparation() { preparation?.cancel() }

    private func show(_ failure: any Error) {
        error = failure.localizedDescription
        details = OperationFeedbackResult.from(failure).details ?? ""
        if let unknown = failure as? PushOutcomeUnknown {
            pushPlan = nil
            verificationPlan = unknown.plan
            verificationReceipt = unknown.receipt
            verificationResult = nil
            let receipt = unknown.receipt
            session.pendingPush = PendingPushRecord(
                commit: receipt.head, localBranch: receipt.localBranch, remote: receipt.remoteName,
                branch: String(receipt.targetRef.dropFirst("refs/heads/".count)),
                pushIndex: receipt.pushURLIndex,
                verification: receipt)
        }
    }
}
