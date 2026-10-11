import Foundation

extension RepositoryService {
    public func remotes() async throws -> [String] {
        try location.validateIdentity()
        return try await engine.run(["remote"], in: location.root).text.split(separator: "\n").map(
            String.init)
    }

    public func fetch(remote: String) async throws {
        try await queue.perform {
            let target = try await remoteDetails(name: remote)
            try location.validateIdentity()
            _ = try await engine.run(
                ["fetch", "--progress", "--", remote], in: location.root, timeout: 300,
                configuration: try pinnedRemote(target))
        }
    }
}
