import Foundation

/// Explicit FIFO ownership persists across await; actor isolation alone is not a mutex.
public actor RepositoryOperationQueue {
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
