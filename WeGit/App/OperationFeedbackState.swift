import Foundation
import WeGitCore

/// Presentation is explicit: a returned warning does not imply that a write failed.
enum OperationFeedbackResult: Equatable, Sendable {
    enum Kind: String, Sendable {
        case success
        case needsReview = "needs-review"
        case failure
        case cancelled
    }

    case success(message: String)
    case needsReview(message: String, details: String?)
    case failure(message: String, details: String?)
    case cancelled(message: String)

    var kind: Kind {
        switch self {
        case .success: .success
        case .needsReview: .needsReview
        case .failure: .failure
        case .cancelled: .cancelled
        }
    }

    var message: String {
        switch self {
        case .success(let message), .needsReview(let message, _), .failure(let message, _),
            .cancelled(let message):
            message
        }
    }

    var details: String? {
        switch self {
        case .needsReview(_, let details), .failure(_, let details):
            details.flatMap { $0.isEmpty ? nil : $0 }
        case .success, .cancelled: nil
        }
    }

    var fullText: String {
        message + (details.map { "\n\n" + $0 } ?? "")
    }

    var accessibilityStatus: String {
        switch self {
        case .success: L10n.text("完成")
        case .needsReview: L10n.text("需要核对")
        case .failure: L10n.text("失败")
        case .cancelled: L10n.text("已取消")
        }
    }

    /// A command that changed state without a reliable receipt remains unconfirmed,
    /// even when its underlying error was cancellation or timeout.
    static func from(_ error: any Error) -> Self {
        switch error {
        case let unknown as TagPushOutcomeUnknown:
            .needsReview(
                message: unknown.localizedDescription,
                details: unknown.plan.feedbackTargetDetails + "\n\n" + unknown.details)
        case let unknown as CommitOutcomeUnknown:
            .needsReview(
                message: unknown.localizedDescription,
                details: unknown.observedHead + "\n\n" + unknown.details)
        case let unknown as SingleCommitOutcomeUnknown:
            .needsReview(
                message: unknown.localizedDescription,
                details: [unknown.observedHead, unknown.details].compactMap { $0 }.joined(separator: "\n\n"))
        case let unknown as RebaseOutcomeUnknown:
            .needsReview(
                message: unknown.localizedDescription,
                details: [
                    unknown.previousHead, unknown.observedHead, unknown.originalReference, unknown.details,
                ]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        case let unknown as PushOutcomeUnknown:
            .needsReview(
                message: unknown.localizedDescription,
                details: unknown.plan.feedbackTargetDetails + "\n\n" + unknown.details)
        case is CancellationError, ProcessFailure.cancelled, AuthenticationFailure.cancelled:
            .cancelled(message: L10n.text("已取消"))
        default:
            .failure(
                message: error.localizedDescription,
                details: (error as? GitFailure)?.details ?? (error as? PullFailure)?.details)
        }
    }
}

extension RebaseOutcome {
    var feedback: OperationFeedbackOutcome {
        switch self {
        case .completed: .completed(message: L10n.text("变基完成"))
        case .aborted: .completed(message: L10n.text("已中止变基并恢复原分支"))
        case .unchanged: .completed(message: L10n.text("当前分支已包含目标提交"))
        case .conflicts(_, let count):
            .needsReview(message: L10n.text("产生 \(count) 个冲突，请在更改页面解决后继续或中止。"))
        case .paused(let recovery, let details):
            .needsReview(
                message: L10n.text("变基已暂停，请核对错误和暂存区，再继续或中止。"),
                details: [recovery.originalHead, recovery.onto, recovery.originalReference, details].joined(
                    separator: "\n\n"))
        }
    }
}

/// Success decoration is tied to the actual operation, never to translated copy.
enum OperationFeedbackContext: String, Equatable, Sendable {
    case standard, commit, stashSave
}

/// Business completion and presentation tone are independent. A push can complete
/// with an upstream warning; an unmatched verification must keep its recovery flow.
struct OperationFeedbackOutcome: Equatable, Sendable {
    let feedback: OperationFeedbackResult
    let didComplete: Bool

    static func completed(message: String, warning: String? = nil) -> Self {
        Self(
            feedback: warning.map { .needsReview(message: $0, details: nil) }
                ?? .success(message: message),
            didComplete: true)
    }

    static func needsReview(message: String, details: String? = nil) -> Self {
        Self(feedback: .needsReview(message: message, details: details), didComplete: false)
    }
}

extension TagPushPlan {
    var feedbackTargetDetails: String {
        [tag.reference, tag.objectID, remote.name, remote.displayPushURLs[pushURLIndex]]
            .joined(separator: "\n")
    }
}

extension PushPlan {
    var feedbackTargetDetails: String {
        [targetRef, head, remote.name, remote.displayPushURLs[pushURLIndex]]
            .joined(separator: "\n")
    }
}
