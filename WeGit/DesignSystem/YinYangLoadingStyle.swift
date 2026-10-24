import SwiftUI
import WeGitCore

private struct LoadingMotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var loadingMotionEnabled: Bool {
        get { self[LoadingMotionEnabledKey.self] }
        set { self[LoadingMotionEnabledKey.self] = newValue }
    }
}

/// One indeterminate style for windows, sheets, toolbars and the menu-bar panel.
struct YinYangLoadingStyle: ProgressViewStyle {
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        if let fraction = configuration.fractionCompleted {
            ProgressView(value: fraction) {
                configuration.label
            } currentValueLabel: {
                configuration.currentValueLabel
            }
            .progressViewStyle(.linear)
        } else {
            if configuration.label == nil {
                indicator(configuration)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("读取中…"))
            } else {
                indicator(configuration)
            }
        }
    }

    private func indicator(_ configuration: Configuration) -> some View {
        HStack(spacing: controlSize == .mini ? 5 : 8) {
            YinYangLoadingIndicator(side: side)
            configuration.label
            configuration.currentValueLabel
        }
        .accessibilityElement(children: .combine)
    }

    private var side: CGFloat {
        switch controlSize {
        case .mini: 12
        case .small: 16
        case .regular: 28
        case .large: 32
        case .extraLarge: 40
        @unknown default: 28
        }
    }
}

private struct YinYangLoadingIndicator: View {
    let side: CGFloat
    @Environment(\.loadingMotionEnabled) private var motionEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var startedAt = Date.now

    var body: some View {
        Group {
            if motionEnabled && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: !visible || scenePhase != .active)) {
                    timeline in
                    YinYangLoadingGlyph(
                        phase: timeline.date.timeIntervalSince(startedAt) / YinYangLoadingMotion.duration)
                }
            } else {
                YinYangLoadingGlyph(phase: 0.5)
            }
        }
        .frame(width: side, height: side)
        .onAppear {
            startedAt = .now
            visible = true
        }
        .onDisappear { visible = false }
    }
}
