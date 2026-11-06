import Foundation

extension RepositoryService {
    /// Every cross-repository operation acquires all distinct common scopes first,
    /// then all distinct private scopes. Recursion never reacquires an owned actor.
    func withSubmoduleOperation<T: Sendable>(
        child: RepositoryLocation?, operation: @Sendable () async throws -> T
    ) async throws -> T {
        let locations = [location] + (child.map { [$0] } ?? [])
        let common = locations.sorted { $0.commonDirectory.path < $1.commonDirectory.path }
            .map { RepositoryOperationQueue.shared(for: $0) }
        let local = locations.sorted { $0.gitDirectory.path < $1.gitDirectory.path }
            .map { $0 == location ? queue : RepositoryOperationQueue.worktree(for: $0) }
        var scopes: [RepositoryOperationQueue] = []
        for scope in common + local where !scopes.contains(where: { $0 === scope }) { scopes.append(scope) }
        return try await Self.acquireSubmoduleScopes(scopes, operation: operation)
    }

    private static func acquireSubmoduleScopes<T: Sendable>(
        _ scopes: [RepositoryOperationQueue], operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard let first = scopes.first else { return try await operation() }
        return try await first.perform {
            try await acquireSubmoduleScopes(Array(scopes.dropFirst()), operation: operation)
        }
    }
}
