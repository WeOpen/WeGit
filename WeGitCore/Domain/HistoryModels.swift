import Foundation

public enum HistoryScope: String, CaseIterable, Sendable { case all, currentBranch }

public enum HistorySearchField: String, CaseIterable, Sendable {
    case message, author, sha
    public var title: String {
        switch self {
        case .message: "消息"
        case .author: "作者"
        case .sha: "SHA"
        }
    }
}

public struct GitReference: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case localBranch, remoteBranch, tag, head }
    public let id: String
    public let target: String
    public let kind: Kind
    public var name: String {
        switch kind {
        case .head: "HEAD"
        case .localBranch: String(id.dropFirst("refs/heads/".count))
        case .remoteBranch: String(id.dropFirst("refs/remotes/".count))
        case .tag: String(id.dropFirst("refs/tags/".count))
        }
    }
}

public struct HistoryAnchor: Sendable {
    public let id: UUID
    public let location: RepositoryLocation
    public let head: String?
    public let scope: HistoryScope
    public let query: String
    public let searchField: HistorySearchField
    public let matchingOID: String?
    public let references: [GitReference]
    public let tips: [String]
    public let isShallow: Bool
}

public struct HistoryCursor: Sendable, Equatable {
    let anchorID: UUID
    let offset: Int
}

public struct HistoryPage: Sendable {
    public let commits: [GitCommit]
    public let next: HistoryCursor?
}

enum GitObjectID {
    static func valid(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count)
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct CommitGraphLayoutEngine: Sendable {
    public private(set) var lanes: [String] = []
    public init() {}

    public mutating func append(_ commits: [GitCommit]) -> [GraphRow] {
        commits.map { commit in
            let incoming = Array(lanes.indices)
            if !lanes.contains(commit.id) { lanes.append(commit.id) }
            let before = lanes
            let column = lanes.firstIndex(of: commit.id)!
            lanes.remove(at: column)
            let parents = commit.shallowBoundary ? [] : commit.parents
            for parent in parents.reversed() where !lanes.contains(parent) {
                lanes.insert(parent, at: min(column, lanes.count))
            }
            var connections: [(Int, Int)] = []
            for (index, oid) in before.enumerated() where oid != commit.id {
                if let destination = lanes.firstIndex(of: oid) { connections.append((index, destination)) }
            }
            for parent in parents {
                if let destination = lanes.firstIndex(of: parent) {
                    connections.append((column, destination))
                }
            }
            return GraphRow(
                column: column, connections: connections, width: max(before.count, lanes.count),
                incomingColumns: incoming)
        }
    }
}
