import Foundation

public enum InteractiveRebaseAction: String, CaseIterable, Sendable {
    case pick
    case reword
    case drop

    var gitCommand: String { rawValue }
}

public struct InteractiveRebaseStep: Identifiable, Hashable, Sendable {
    public let id: String
    public let subject: String
    public let author: String
    public let action: InteractiveRebaseAction
    public let message: String?

    public init(
        id: String, subject: String, author: String, action: InteractiveRebaseAction = .pick,
        message: String? = nil
    ) {
        self.id = id
        self.subject = subject
        self.author = author
        self.action = action
        self.message = message
    }
}

public struct InteractiveRebasePlan: Sendable {
    public let branch: String
    public let head: String
    public let upstream: GitBranch
    public let steps: [InteractiveRebaseStep]

    let location: RepositoryLocation
    let index: Data
    let writePaths: Set<String>

    public func replacing(steps: [InteractiveRebaseStep]) -> InteractiveRebasePlan {
        InteractiveRebasePlan(
            branch: branch, head: head, upstream: upstream, steps: steps,
            location: location, index: index, writePaths: writePaths)
    }
}

public enum InteractiveRebaseOutcome: Sendable {
    case completed(String)
    case paused(RebaseRecovery)
    case conflicts(RebaseRecovery, Int)
    case unchanged
}

enum InteractiveRebaseBudget {
    static let commits = 2_000
    static let bytes = 32 * 1024 * 1024
}
