import Foundation

extension RepositoryService {
    @concurrent public func hasShallowHistory() async throws -> Bool {
        try location.validateIdentity()
        let value = try await engine.run(["rev-parse", "--is-shallow-repository"], in: location.root).text
            .removingLastNewline
        guard value == "true" || value == "false" else { throw ModelFailure.changed }
        return value == "true"
    }

    public func prepareHistoryDepth(remote: GitRemote, change: HistoryDepthChange) async throws
        -> HistoryDepthPlan
    {
        try await withSharedOperation {
            try await verifyRemote(remote)
            if case .deepen(let count) = change {
                guard (1...Int(Int32.max)).contains(count) else { throw ModelFailure.invalidPath }
            }
            guard try await hasShallowHistory(),
                let shallow = try RepositoryNodeIdentity.readIfPresent(
                    location.commonDirectory.appending(path: "shallow")),
                shallow.kind == UInt16(S_IFREG)
            else { throw ModelFailure.unsupported(L10n.text("此仓库已有完整历史，不需要补深。")) }
            let state = try await status()
            guard state.sequencer == .none, state.conflicts.isEmpty else { throw ModelFailure.changed }
            try await verifyHead(state.head)
            return HistoryDepthPlan(
                id: UUID(), remote: remote, change: change, head: state.head,
                branch: state.branch, location: location, shallowVersion: shallow)
        }
    }

    public func fetchHistoryDepth(_ plan: HistoryDepthPlan) async throws -> HistoryDepthResult {
        try await withSharedOperation {
            guard plan.location == location,
                try RepositoryNodeIdentity.readIfPresent(location.commonDirectory.appending(path: "shallow"))
                    == plan.shallowVersion
            else { throw ModelFailure.changed }
            try await verifyRemote(plan.remote)
            try await verifyHead(plan.head)
            let before = try await status()
            let index = try SelectedIndexSnapshot.read(location: location)
            guard before.branch == plan.branch, before.sequencer == .none else { throw ModelFailure.changed }
            let depth: String
            switch plan.change {
            case .complete: depth = "--unshallow"
            case .deepen(let count): depth = "--deepen=\(count)"
            }
            _ = try await engine.run(
                ["fetch", "--progress", "--no-recurse-submodules", depth, "--", plan.remote.name]
                    + plan.remote.fetchRefspecs, in: location.root, timeout: 300,
                configuration: try pinnedRemote(plan.remote))
            try await verifyHead(plan.head)
            let after = try await status()
            guard after.branch == plan.branch, try SelectedIndexSnapshot.read(location: location) == index
            else { throw ModelFailure.changed }
            return HistoryDepthResult(isShallow: try await hasShallowHistory())
        }
    }

    public func remotes() async throws -> [String] {
        try location.validateIdentity()
        return try await engine.run(["remote"], in: location.root).text.split(separator: "\n").map(
            String.init)
    }

    public func fetch(remote: String) async throws {
        try await withSharedOperation {
            let target = try await remoteDetails(name: remote)
            try location.validateIdentity()
            _ = try await engine.run(
                ["fetch", "--progress", "--", remote], in: location.root, timeout: 300,
                configuration: try pinnedRemote(target))
        }
    }
}
