import WeGitCore

/// Counts compare HEAD with the locally fetched upstream, never an unqueried server.
struct RepositorySyncCounts: Equatable {
    let ahead: Int?
    let behind: Int?

    init(status: RepositoryStatus, hasLoaded: Bool, isStale: Bool) {
        if hasLoaded, !isStale, status.head != nil, !status.isDetached,
            status.upstream != nil, let ahead = status.ahead, let behind = status.behind,
            ahead >= 0, behind >= 0
        {
            self.ahead = ahead
            self.behind = behind
        } else {
            ahead = nil
            behind = nil
        }
    }
}
