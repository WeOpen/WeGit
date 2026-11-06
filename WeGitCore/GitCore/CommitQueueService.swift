import Foundation

extension RepositoryService {
    @concurrent public func commitQueue() async throws -> CommitQueueRecord? {
        try await SnapshotIO.run { _ in try CommitQueueStore.existingRecord(location: location) }
    }

    @concurrent public func prepareCommitQueue(
        _ operation: SingleCommitOperation, selections: [CommitQueueSelection]
    ) async throws -> CommitQueuePlan {
        try await queue.perform {
            guard (1...100).contains(selections.count), try await commitQueue() == nil else {
                throw ModelFailure.unsupported(L10n.text("请关闭已有队列，并选择 1～100 个提交。"))
            }
            let reader = RepositoryService(location: location, engine: singleCommitEngine, queue: queue)
            var items: [CommitQueueItem] = []
            for selection in selections {
                try Task.checkCancellation()
                let commit = try await reader.readCommit(selection.target)
                guard commit.subject.utf8.count <= 4096, commit.parents.count <= 64 else {
                    throw SingleCommitBudget.exceeded
                }
                if commit.parents.count > 1 {
                    guard let parent = selection.mainline, (1...commit.parents.count).contains(parent) else {
                        throw ModelFailure.unsupported(L10n.text("请为合并提交选择主线父提交。"))
                    }
                } else if selection.mainline != nil {
                    throw ModelFailure.invalidPath
                }
                items.append(
                    CommitQueueItem(
                        objectID: commit.id, subject: commit.subject, mainline: selection.mainline,
                        state: .pending, result: nil))
            }
            guard Set(items.map(\.objectID)).count == items.count else {
                throw ModelFailure.unsupported(L10n.text("同一提交不能在队列中重复出现。"))
            }
            let first = try await singleCommitPlan(
                operation, target: items[0].objectID, mainline: items[0].mainline)
            return CommitQueuePlan(operation: operation, items: items, first: first, location: location)
        }
    }

    public func executeCommitQueue(_ plan: CommitQueuePlan) async throws -> CommitQueueRecord {
        try await withSharedOperation {
            guard plan.location == location, try await commitQueue() == nil else {
                throw ModelFailure.changed
            }
            let fresh = try await singleCommitPlan(
                plan.operation, target: plan.items[0].objectID, mainline: plan.items[0].mainline)
            guard fresh.head == plan.first.head, fresh.branch == plan.first.branch,
                fresh.index == plan.first.index, fresh.resultTree == plan.first.resultTree
            else { throw ModelFailure.changed }
            let store = try CommitQueueStore(location: location)
            let record = CommitQueueRecord(
                format: 1, id: UUID(), workspaceID: location.persistenceID, operation: plan.operation,
                originalHead: fresh.head, branch: fresh.branch, createdAt: Date(), items: plan.items,
                next: 0, currentHead: fresh.head, phase: .ready, expectedTree: nil,
                expectedIndexSHA256: nil, details: nil)
            try store.save(record, expected: nil)
            do {
                var commands = [
                    "start", "create " + queueReference(record, suffix: "head") + " " + record.originalHead,
                ]
                for (index, item) in record.items.enumerated() {
                    commands.append(
                        "create " + queueReference(record, suffix: String(index)) + " " + item.objectID)
                }
                commands += ["prepare", "commit"]
                _ = try await singleCommitEngine.run(
                    ["update-ref", "--no-deref", "--stdin"], in: location.root,
                    input: Data((commands.joined(separator: "\n") + "\n").utf8))
                return try await runCommitQueue(record, store: store)
            } catch {
                if error is CommitQueueOutcomeUnknown { throw error }
                return try await failCommitQueue(record, store: store, error: error)
            }
        }
    }

    public func continueCommitQueue(_ expected: CommitQueueRecord, confirmObservedCommit: Bool = false)
        async throws -> CommitQueueRecord
    {
        try await withSharedOperation {
            let store = try CommitQueueStore(location: location)
            guard try store.record() == expected, expected.phase.pending, let item = expected.current else {
                throw ModelFailure.changed
            }
            var record = expected
            let state = try await status()
            guard state.branch == record.branch else { throw ModelFailure.changed }
            if let recovery = state.singleCommitRecovery {
                guard recovery.operation == record.operation, recovery.target == item.objectID,
                    recovery.head == record.currentHead
                else { throw ModelFailure.changed }
                do {
                    try await recoverSingleCommitUnderPermit(continueOperation: true, expected: recovery)
                } catch { return try await failCommitQueue(record, store: store, error: error) }
                let head = try await head()
                guard let head else { throw ModelFailure.changed }
                let commit = try await readCommit(head)
                guard commit.parents == [record.currentHead] else { throw ModelFailure.changed }
                record.items[record.next].state = .committed
                record.items[record.next].result = head
                record.currentHead = head
                record.next += 1
            } else if record.phase == .running || record.phase == .needsVerification {
                guard state.sequencer == .none, state.files.isEmpty, let head = state.head else {
                    throw ModelFailure.changed
                }
                if head == record.currentHead {
                    let index = try await singleCommitIndex()
                    guard
                        record.expectedIndexSHA256 == nil
                            || record.expectedIndexSHA256 == RecoveryFileIO.hash(index.raw)
                    else {
                        throw ModelFailure.changed
                    }
                } else {
                    guard confirmObservedCommit, let tree = record.expectedTree else {
                        throw ModelFailure.unsupported(L10n.text("HEAD 已变化，请先核对本项结果再确认继续。"))
                    }
                    let commit = try await readCommit(head)
                    guard commit.parents == [record.currentHead],
                        try await singleCommitTree(head, engine: singleCommitEngine) == tree
                    else {
                        throw ModelFailure.changed
                    }
                    record.items[record.next].state = .committed
                    record.items[record.next].result = head
                    record.currentHead = head
                    record.next += 1
                }
            } else {
                guard record.phase == .ready, state.head == record.currentHead, state.files.isEmpty,
                    state.sequencer == .none
                else {
                    throw ModelFailure.unsupported(L10n.text("本项尚未完成，请解决冲突、核对失败或明确跳过。"))
                }
            }
            record.expectedTree = nil
            record.expectedIndexSHA256 = nil
            record.details = nil
            record.phase = record.next == record.items.count ? .completed : .ready
            try store.save(record, expected: expected)
            return try await runCommitQueue(record, store: store)
        }
    }

    public func skipCommitQueueItem(_ expected: CommitQueueRecord) async throws -> CommitQueueRecord {
        try await withSharedOperation {
            let store = try CommitQueueStore(location: location)
            guard try store.record() == expected, expected.phase.pending, let item = expected.current else {
                throw ModelFailure.changed
            }
            let state = try await status()
            guard state.branch == expected.branch, state.head == expected.currentHead else {
                throw ModelFailure.changed
            }
            if let recovery = state.singleCommitRecovery {
                guard recovery.operation == expected.operation, recovery.target == item.objectID else {
                    throw ModelFailure.changed
                }
                try await backupCommitQueueChanges(state)
                try await recoverSingleCommitUnderPermit(continueOperation: false, expected: recovery)
            } else {
                guard state.sequencer == .none, state.files.isEmpty else { throw ModelFailure.changed }
            }
            var record = expected
            record.items[record.next].state = .skipped
            record.next += 1
            record.phase = record.next == record.items.count ? .completed : .ready
            record.expectedTree = nil
            record.expectedIndexSHA256 = nil
            record.details = nil
            try store.save(record, expected: expected)
            return try await runCommitQueue(record, store: store)
        }
    }

    public func abortCommitQueue(_ expected: CommitQueueRecord) async throws -> CommitQueueRecord {
        try await withSharedOperation {
            let store = try CommitQueueStore(location: location)
            guard try store.record() == expected, expected.phase.pending else { throw ModelFailure.changed }
            let state = try await status()
            guard state.branch == expected.branch else { throw ModelFailure.changed }
            if let recovery = state.singleCommitRecovery, let item = expected.current {
                guard recovery.operation == expected.operation, recovery.target == item.objectID,
                    recovery.head == expected.currentHead
                else { throw ModelFailure.changed }
                try await backupCommitQueueChanges(state)
                try await recoverSingleCommitUnderPermit(continueOperation: false, expected: recovery)
            }
            var record = expected
            record.phase = .aborted
            try store.save(record, expected: expected)
            return record
        }
    }

    public func closeCommitQueue(_ expected: CommitQueueRecord) async throws {
        try await withSharedOperation {
            let store = try CommitQueueStore(location: location)
            guard !expected.phase.pending, try store.record() == expected else { throw ModelFailure.changed }
            let refs = try await queueReferences(expected)
            let wanted = expectedQueueReferences(expected)
            guard refs.allSatisfy({ wanted[$0.key] == $0.value }) else { throw ModelFailure.changed }
            if !refs.isEmpty {
                var commands =
                    ["start"] + refs.sorted { $0.key < $1.key }.map { "delete " + $0.key + " " + $0.value }
                commands += ["prepare", "commit"]
                _ = try await singleCommitEngine.run(
                    ["update-ref", "--no-deref", "--stdin"], in: location.root,
                    input: Data((commands.joined(separator: "\n") + "\n").utf8))
            }
            try store.remove(expected)
        }
    }

    private func runCommitQueue(_ initial: CommitQueueRecord, store: CommitQueueStore) async throws
        -> CommitQueueRecord
    {
        var record = initial
        while let item = record.current {
            guard record.phase == .ready else { return record }
            do {
                try Task.checkCancellation()
                let observedRefs = try await queueReferences(record)
                guard observedRefs == expectedQueueReferences(record) else { throw ModelFailure.changed }
                let plan = try await singleCommitPlan(
                    record.operation, target: item.objectID, mainline: item.mainline)
                guard plan.head == record.currentHead, plan.branch == record.branch else {
                    throw ModelFailure.changed
                }
                var running = record
                running.expectedTree = plan.resultTree
                running.expectedIndexSHA256 = RecoveryFileIO.hash(plan.index)
                running.phase = plan.hasChanges ? .running : .waiting
                running.details = plan.hasChanges ? nil : L10n.text("本项没有可应用的改动，请明确跳过。")
                try store.save(running, expected: record)
                record = running
                if !plan.hasChanges { return record }
                switch try await executeSingleCommitUnderPermit(plan) {
                case .committed(let head):
                    var completed = record
                    completed.items[completed.next].state = .committed
                    completed.items[completed.next].result = head
                    completed.currentHead = head
                    completed.next += 1
                    completed.phase = completed.next == completed.items.count ? .completed : .ready
                    completed.expectedTree = nil
                    completed.expectedIndexSHA256 = nil
                    try store.save(completed, expected: record)
                    record = completed
                case .conflicts, .pending:
                    var waiting = record
                    waiting.phase = .waiting
                    waiting.details = L10n.text("解决本项冲突或提交失败后继续，已完成提交保持不变。")
                    try store.save(waiting, expected: record)
                    return waiting
                }
            } catch { return try await failCommitQueue(record, store: store, error: error) }
        }
        return record
    }

    private func failCommitQueue(_ record: CommitQueueRecord, store: CommitQueueStore, error: any Error)
        async throws -> CommitQueueRecord
    {
        var failed = record
        failed.phase = .needsVerification
        failed.details = String(
            Redaction.text((error as? GitFailure)?.details ?? error.localizedDescription).prefix(8192))
        let saved = failed
        try? await Task.detached { try store.save(saved, expected: record) }.value
        throw CommitQueueOutcomeUnknown(recordID: record.id, details: failed.details ?? "")
    }

    private func queueReference(_ record: CommitQueueRecord, suffix: String) -> String {
        "refs/wegit/commit-queue/" + record.id.uuidString.lowercased() + "/" + suffix
    }

    private func expectedQueueReferences(_ record: CommitQueueRecord) -> [String: String] {
        var refs = [queueReference(record, suffix: "head"): record.originalHead]
        for (index, item) in record.items.enumerated() {
            refs[queueReference(record, suffix: String(index))] = item.objectID
        }
        return refs
    }

    private func queueReferences(_ record: CommitQueueRecord) async throws -> [String: String] {
        let prefix = "refs/wegit/commit-queue/" + record.id.uuidString.lowercased() + "/"
        let data = try await singleCommitEngine.run(
            ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)", prefix],
            in: location.root, outputLimit: 32 * 1024
        ).stdout
        var refs: [String: String] = [:]
        for row in data.split(separator: 10) {
            let fields = row.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 3, fields[2].isEmpty,
                let name = String(data: fields[0], encoding: .utf8), name.hasPrefix(prefix),
                let object = String(data: fields[1], encoding: .utf8), GitObjectID.valid(object),
                refs[name] == nil
            else { throw ModelFailure.changed }
            refs[name] = object
        }
        return refs
    }

    private func backupCommitQueueChanges(_ state: RepositoryStatus) async throws {
        try await preserveInterruptedChanges(operation: "commit-queue-interruption-backup", state: state)
    }
}
