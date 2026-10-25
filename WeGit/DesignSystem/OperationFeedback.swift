import SwiftUI
import WeGitCore

/// The fixed icon slot and text own their fades. The surrounding composer and
/// neighboring layout receive no animation transaction.
struct OperationFeedback: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppPreferences.self) private var preferences
    let busy: Bool
    let activity: String
    let result: OperationFeedbackResult?
    var context: OperationFeedbackContext = .standard
    let fallback: String
    @State private var showingDetails = false

    private var animation: Animation? {
        reduceMotion || !preferences.interfaceMotion ? nil : AppMotion.feedback
    }
    private var text: String { busy ? activity + "…" : result?.message ?? fallback }
    private var phase: String { busy ? "busy" : result?.kind.rawValue ?? "idle" }
    private var iconIdentity: String { phase + ":" + context.rawValue }
    private var accessibleText: String {
        if busy { return L10n.text("正在执行 \(activity)") }
        guard let result else { return fallback }
        return result.accessibilityStatus + ": " + result.fullText
    }
    private var tint: Color {
        guard !busy, let result else { return colors.secondaryText }
        switch result {
        case .success: return colors.positive
        case .needsReview: return colors.modified
        case .failure: return colors.negative
        case .cancelled: return colors.secondaryText
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                icon.id(iconIdentity).transition(
                    context == .commit && result?.kind == .success
                        ? .opacity.combined(with: .scale(scale: 0.96)) : .opacity)
            }.frame(width: 12, height: 12)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
                .animation(animation, value: iconIdentity)
            // A stable text identity lets busy/result changes fade without changing
            // the parent layout. Only a finished result offers the native detail action.
            Button {
                showingDetails = true
            } label: {
                Text(text).lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(animation, value: text)
            }.buttonStyle(.plain).disabled(busy || result == nil)
                .accessibilityLabel(accessibleText)
                .accessibilityHint(busy || result == nil ? "" : L10n.text("查看详情"))
                .accessibilityIdentifier("operation-feedback-message")
                .help(!busy ? result?.fullText ?? fallback : text)
                .popover(isPresented: $showingDetails) {
                    if let result {
                        ScrollView {
                            Text(result.fullText).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityValue(result.fullText)
                                .accessibilityIdentifier("operation-feedback-details")
                        }.padding(16).frame(width: 440).frame(maxHeight: 360)
                            .foregroundStyle(colors.text)
                    }
                }
        }.font(.caption).foregroundStyle(colors.secondaryText)
            .accessibilityElement(children: busy || result == nil ? .ignore : .contain)
            .accessibilityLabel(accessibleText)
            .accessibilityValue(phase)
            .accessibilityIdentifier("operation-feedback")
            .transaction { $0.animation = nil }
            .onChange(of: busy) { _, busy in if busy { showingDetails = false } }
            .onChange(of: result) { _, _ in showingDetails = false }
    }

    @ViewBuilder private var icon: some View {
        if busy {
            ProgressView().controlSize(.mini)
        } else if let result {
            switch result {
            case .success where context == .commit:
                HeritageKuStamp(size: 18)
            case .success where context == .stashSave:
                Image(systemName: "scroll")
            case .success:
                Image(systemName: "checkmark.circle.fill")
            case .needsReview:
                Image(systemName: "exclamationmark.triangle.fill")
            case .failure:
                Image(systemName: "xmark.circle.fill")
            case .cancelled:
                Image(systemName: "xmark.circle")
            }
        }
    }
}
