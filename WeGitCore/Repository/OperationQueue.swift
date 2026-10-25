import Foundation

/// Explicit FIFO ownership persists across await; actor isolation alone is not a mutex.
public actor RepositoryOperationQueue {
    private static let registry = RepositoryQueueRegistry()

    static func shared(for location: RepositoryLocation) -> RepositoryOperationQueue {
        registry.queue(for: location.commonIdentity)
    }
    private var held = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    public init() {}

    public func perform<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !held {
            held = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
    }

    private func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().1.resume() }
    }
}

/// All Git writes can update shared refs/configuration, including commit and checkout.
/// One common-directory queue avoids nested lock ordering. Independent reads remain
/// concurrent; consistent multi-command snapshots retain their existing permit.
/// Weak entries keep closed repositories from accumulating for the app's lifetime.
private final class RepositoryQueueRegistry: @unchecked Sendable {
    private final class Entry {
        weak var queue: RepositoryOperationQueue?
        init(_ queue: RepositoryOperationQueue) { self.queue = queue }
    }
    private let lock = NSLock()
    private var entries: [RepositoryNodeIdentity: Entry] = [:]

    func queue(for identity: RepositoryNodeIdentity) -> RepositoryOperationQueue {
        lock.withLock {
            entries = entries.filter { $0.value.queue != nil }
            if let queue = entries[identity]?.queue { return queue }
            let queue = RepositoryOperationQueue()
            entries[identity] = Entry(queue)
            return queue
        }
    }
}
