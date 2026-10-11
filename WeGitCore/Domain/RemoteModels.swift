import CryptoKit
import Foundation

public struct GitRemote: Identifiable, Hashable, Sendable {
    public let name: String
    public let fetchURL: String
    public let pushURLs: [String]
    let rawURLs: [String]
    let rawPushURLs: [String]
    let fetchRefspecs: [String]
    public var id: String { name }
    public var displayFetchURL: String { Redaction.text(fetchURL) }
    public var displayPushURLs: [String] { pushURLs.map(Redaction.text) }
}

public enum PullStrategy: String, CaseIterable, Sendable {
    case fastForwardOnly, merge, rebase
    public var title: String {
        switch self {
        case .fastForwardOnly: "仅快进"
        case .merge: "合并"
        case .rebase: "变基"
        }
    }
}

public struct PullPreference: Sendable {
    public let strategy: PullStrategy?
    public let preserveMerges: Bool
    public let source: String
    public let warning: String?
    public var createMergeCommit = false
}

public struct PushPlan: Sendable {
    public let remote: GitRemote
    public let pushURLIndex: Int
    public let targetRef: String
    public let localBranch: String
    public let head: String
    public let expectedRemoteOID: String?
    public let forceWithLease: Bool
    public let setUpstream: Bool
    let location: RepositoryLocation
}

public struct PushResult: Sendable {
    public let upstreamConfigured: Bool
    public let warning: String?
}

/// Durable verification data never contains a remote URL or credential.
public struct PushReceipt: Codable, Hashable, Sendable {
    public let repositoryID: String
    public let remoteName: String
    public let pushURLIndex: Int
    public let targetRef: String
    public let localBranch: String
    public let head: String
    public let expectedRemoteOID: String?
    public let forceWithLease: Bool
    public let setUpstream: Bool
    let destinationFingerprint: String?

    init(_ plan: PushPlan) {
        repositoryID = plan.location.persistenceID
        remoteName = plan.remote.name
        pushURLIndex = plan.pushURLIndex
        targetRef = plan.targetRef
        localBranch = plan.localBranch
        head = plan.head
        expectedRemoteOID = plan.expectedRemoteOID
        forceWithLease = plan.forceWithLease
        setUpstream = plan.setUpstream
        destinationFingerprint = Self.fingerprint(
            plan.remote.pushURLs[plan.pushURLIndex], in: plan.location.root)
    }

    static func fingerprint(_ destination: String, in root: URL) -> String? {
        // Do not persist a password-derived verifier. Credential-bearing addresses
        // can only be checked with the original in-memory plan, not reconstructed.
        let components = URLComponents(string: destination)
        guard Redaction.text(destination) == destination,
            components?.password == nil, components?.query == nil, components?.fragment == nil,
            !destination.contains("://") || components != nil
        else { return nil }
        let colon = destination.firstIndex(of: ":")
        let slash = destination.firstIndex(of: "/")
        let local = colon.map { colon in slash.map { $0 < colon } ?? false } ?? true
        let endpoint =
            local
            ? (destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination) : root.appending(path: destination))
                .standardizedFileURL.absoluteString
            : destination
        return SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct PushOutcomeUnknown: Error, LocalizedError, Sendable {
    public let plan: PushPlan
    public let receipt: PushReceipt
    public let details: String
    public var errorDescription: String? {
        "推送没有返回可核实的结果。远端可能已收到提交，请先核对确认时的目标。"
    }
}

public struct PushVerification: Sendable {
    public let receipt: PushReceipt
    public let observedOID: String?
    public var matches: Bool { observedOID == receipt.head }
    public var message: String {
        if matches {
            return "已核对：远端目标当前指向本次提交。"
                + (receipt.setUpstream ? "上游设置尚未核实，可在分支页面检查。" : "")
        }
        if let observedOID {
            return "远端目标当前为 \(observedOID.prefix(12))，与本次提交不同；无法据此判断此前是否曾推送成功。"
        }
        return "当前未找到该远端分支；无法据此判断此前是否曾推送成功。"
    }
}

public struct RemoteBranchTarget: Sendable {
    public let remote: String
    public let branch: String
}

public struct CommitPushResult: Sendable {
    public let commit: String
    public let push: PushResult?
    public let failure: (any Error)?
}

public struct PullPlan: Sendable {
    public let remote: GitRemote
    public let targetRef: String
    public let localBranch: String
    public let head: String
    public let strategy: PullStrategy
    public let preserveMerges: Bool
    public let createMergeCommit: Bool
    let location: RepositoryLocation
}

public struct PullFailure: Error, LocalizedError, Sendable {
    public let fetched: Bool
    public let message: String
    public let details: String
    public var errorDescription: String? { message }
}

public struct PullResult: Sendable {
    public let warning: String?
}
