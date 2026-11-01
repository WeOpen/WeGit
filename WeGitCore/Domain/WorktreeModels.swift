import CryptoKit
import Foundation

public struct GitWorktree: Identifiable, Hashable, Sendable {
    public let path: String
    public let reportedPath: String
    public let id: String
    public let head: String?
    public let branch: String?
    public let locked: String?
    public let prunable: String?
    public let bare: Bool
    public let primary: Bool
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var branchName: String? { branch.map { String($0.dropFirst("refs/heads/".count)) } }
}

public enum WorktreeCreationKind: Equatable, Sendable {
    case newBranch(String)
    case existingBranch(String)
    case detached
    var branch: String? {
        switch self {
        case .newBranch(let name), .existingBranch(let name): name
        case .detached: nil
        }
    }
}

public struct WorktreeCreationPlan: Sendable {
    public let destination: URL
    public let kind: WorktreeCreationKind
    public let target: String
    let location: RepositoryLocation
    let head: String
    let list: Data
    let parentIdentity: RepositoryNodeIdentity
}

public struct WorktreeRemovalPlan: Sendable {
    public let worktree: GitWorktree
    let location: RepositoryLocation
    let targetLocation: RepositoryLocation
    let head: String?
    let list: Data
    let index: Data?
}

public struct WorktreeCreationReceipt: Sendable {
    public let location: RepositoryLocation
}

public struct WorktreeRemovalReceipt: Sendable {
    public let preservedDirectory: URL
}

public struct WorktreeOutcomeUnknown: Error, LocalizedError, Sendable {
    public let preservedDirectory: URL
    public let details: String
    public var errorDescription: String? {
        L10n.text("工作树操作需核对。已保留目录，请先检查结果再操作。")
    }
}

enum WorktreeParser {
    static func parse(_ bytes: Data) throws -> [GitWorktree] {
        guard bytes.last == 0 else { throw ModelFailure.invalidOutput("worktree") }
        var result: [GitWorktree] = []
        var fields: [String: String] = [:]
        func append() throws {
            guard let path = fields["worktree"], path.hasPrefix("/"), path.utf8.count <= 8192 else {
                throw ModelFailure.invalidOutput("worktree path")
            }
            let head = fields["HEAD"]
            guard
                head == nil
                    || ((head!.count == 40 || head!.count == 64)
                        && head!.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }))
            else {
                throw ModelFailure.invalidOutput("worktree HEAD")
            }
            let branch = fields["branch"]
            guard branch == nil || branch!.hasPrefix("refs/heads/") else {
                throw ModelFailure.invalidOutput("worktree branch")
            }
            // Resolve path aliases once when reading a list, using the same
            // Foundation canonicalization as RepositoryService.discover.
            let normalized = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path
            let identifier = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }
                .joined()
            result.append(
                GitWorktree(
                    path: normalized, reportedPath: path, id: identifier,
                    head: head.flatMap { $0.allSatisfy({ $0 == "0" }) ? nil : $0 },
                    branch: branch, locked: fields["locked"], prunable: fields["prunable"],
                    bare: fields["bare"] != nil, primary: result.isEmpty))
            guard result.count <= 256 else { throw ModelFailure.unsupported(L10n.text("工作树列表超出读取上限。")) }
            fields = [:]
        }
        for part in bytes.split(separator: 0, omittingEmptySubsequences: false) {
            if part.isEmpty {
                if !fields.isEmpty { try append() }
                continue
            }
            guard let value = String(data: Data(part), encoding: .utf8) else {
                throw ModelFailure.invalidOutput("worktree encoding")
            }
            let pieces = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pieces[0])
            guard fields[key] == nil else { throw ModelFailure.invalidOutput("duplicate worktree field") }
            fields[key] = pieces.count == 2 ? String(pieces[1]) : ""
        }
        guard fields.isEmpty, !result.isEmpty else { throw ModelFailure.invalidOutput("worktree records") }
        return result
    }
}
