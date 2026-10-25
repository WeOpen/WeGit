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
