import AppKit
import SwiftUI
import WeGitCore

enum AppStyle {
    static let controlRadius: CGFloat = 8
    static let surfaceRadius: CGFloat = 14
    static let panelInset: CGFloat = 14
    static let controlHeight: CGFloat = 30
    /// Frame height for controls living in the unified toolbar. Measured against
    /// the system sidebar toggle: a 36pt cell draws a 34.5pt surface, and an
    /// unconstrained glass button in a toolbar cell lands on the same 36/34.5.
    static let toolbarControlHeight: CGFloat = 36
}

enum AppMotion {
    static let feedback = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.16)
    static let reveal = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.28)
}

private struct WorkbenchAppearance: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(AppPreferences.self) private var preferences

    private var palette: AppColors {
        var value = preferences.themeColors
        value.increasedContrast = contrast == .increased
        return value
    }

    func body(content: Content) -> some View {
        let palette = palette
        // Resolve System from the unmodified app appearance. Clearing a window's
        // preference can leave its hosting content on the last explicit scheme.
        content.preferredColorScheme(palette.dark ? .dark : .light)
            .environment(\.themeColors, palette)
            .environment(
                \.locale,
                preferences.language == .system
                    ? L10n.locale : Locale(identifier: preferences.language.rawValue)
            )
            .foregroundStyle(palette.text)
            .tint(palette.accent)
            .toolbarBackground(.hidden, for: .windowToolbar)
            .background(
                ThemeWindowBridge(colors: palette).frame(width: 0, height: 0).accessibilityHidden(true)
            )
            .animation(nil, value: preferences.appearance)
            .onAppear { preferences.observeSystemAppearance() }
    }
}

struct WorkbenchSurface: ViewModifier {
    @Environment(\.themeColors) private var colors
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(colors.surface, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(colors.border, lineWidth: contrast == .increased ? 2 : 0.5)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func workbenchAppearance(_ preferences: AppPreferences) -> some View {
        modifier(WorkbenchAppearance()).environment(preferences)
    }
    func workbenchSurface(radius: CGFloat = AppStyle.surfaceRadius) -> some View {
        modifier(WorkbenchSurface(radius: radius))
    }
    func workbenchHoverRow() -> some View { modifier(WorkbenchHoverRow()) }
}

private struct WorkbenchHoverRow: ViewModifier {
    @Environment(\.themeColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppPreferences.self) private var preferences
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                colors.text.opacity(hovering ? 0.045 : 0),
                in: .rect(cornerRadius: AppStyle.controlRadius)
            )
            .contentShape(.rect(cornerRadius: AppStyle.controlRadius))
            .onHover { hovering = $0 }
            .animation(
                reduceMotion || !preferences.interfaceMotion ? nil : .easeOut(duration: 0.12), value: hovering
            )
    }
}

/// A shared filled silhouette keeps the sidebar, welcome view and status item consistent.
struct BrandGlyph: Shape {
    var optical = false

    func path(in rect: CGRect) -> Path {
        Path(BrandGeometry.path(in: rect, optical: optical))
    }
}

struct BrandMark: View {
    @Environment(\.themeColors) private var colors
    var tint: Color?

    var body: some View {
        BrandGlyph().fill(tint ?? colors.text).accessibilityHidden(true)
    }
}

struct WelcomeIdentity: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppPreferences.self) private var preferences
    @State private var revealed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(colors.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 30).strokeBorder(colors.border, lineWidth: 0.5)
                }
            BrandMark(tint: colors.brandBlue).frame(width: 112, height: 112)
                .opacity(revealed || reduceMotion ? 1 : 0)
                .scaleEffect(revealed || reduceMotion ? 1 : 0.96)
        }
        .frame(width: 112, height: 112)
        .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
        .accessibilityHidden(true)
        .onAppear {
            guard !revealed else { return }
            if reduceMotion || !preferences.interfaceMotion {
                revealed = true
            } else {
                withAnimation(AppMotion.reveal) { revealed = true }
            }
        }
    }
}

/// Neutral symbols let native row selection and typography define the hierarchy.
struct WorkbenchGlyph: View {
    @Environment(\.themeColors) private var colors
    let symbol: String
    var selected = false
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? colors.selectionText : colors.text)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SidebarIdentity: View {
    @Environment(\.themeColors) private var colors
    let repository: String

    var body: some View {
        HStack(spacing: 10) {
            BrandMark().frame(width: 60, height: 60).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("WeGit").font(.system(size: 17, weight: .medium))
                Text(repository).font(.caption).foregroundStyle(colors.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14).padding(.vertical, 13)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.text("WeGit，当前仓库：") + repository)
    }
}

private struct BranchEcho: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.1, y: rect.height * 0.24))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.midY),
            control1: CGPoint(x: rect.width * 0.34, y: rect.height * 0.24),
            control2: CGPoint(x: rect.width * 0.3, y: rect.midY))
        for end in [0.24, 0.76] {
            path.move(to: CGPoint(x: rect.midX, y: rect.midY))
            path.addCurve(
                to: CGPoint(x: rect.width * 0.9, y: rect.height * end),
                control1: CGPoint(x: rect.width * 0.74, y: rect.midY),
                control2: CGPoint(x: rect.width * 0.66, y: rect.height * end))
        }
        return path
    }
}

struct WorkbenchEmblem: View {
    @Environment(\.themeColors) private var colors
    let symbol: String
    var tint: Color?

    var body: some View {
        ZStack {
            BranchEcho().stroke(colors.graphLine, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            ForEach(0..<3) { index in
                Circle().fill(tint ?? colors.text).frame(width: 5, height: 5)
                    .position(x: index == 0 ? 11 : 101, y: index == 2 ? 65 : 21)
            }
            Image(systemName: symbol).font(.system(size: 23, weight: .regular))
                .foregroundStyle(tint ?? colors.text).frame(width: 52, height: 52)
                .background(colors.surface, in: .rect(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(
                        (tint ?? colors.text).opacity(0.18), lineWidth: 0.5)
                }
        }.frame(width: 112, height: 86).accessibilityHidden(true)
    }
}

struct WorkflowStep: View {
    @Environment(\.themeColors) private var colors
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.medium))
            .foregroundStyle(colors.secondaryText)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(colors.surface, in: .capsule)
    }
}
