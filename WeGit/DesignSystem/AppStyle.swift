import AppKit
import SwiftUI
import WeGitCore

enum AppStyle {
    static let controlRadius: CGFloat = 8
    static let surfaceRadius: CGFloat = 14
    static let panelInset: CGFloat = 14
    static let controlHeight: CGFloat = 30
    static let compactControlHeight: CGFloat = 24
    static let smallControlHeight: CGFloat = 26
    static let largeControlHeight: CGFloat = 34
    static let actionMinimumWidth: CGFloat = 80
    /// One owned surface height for toolbar buttons, menus and the sidebar toggle.
    static let toolbarControlHeight: CGFloat = 36
    static let toolbarSymbolSize: CGFloat = 14
}

enum AppMotion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let feedback = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.16)
    static let reveal = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.28)
    static let selection = Animation.spring(response: 0.28, dampingFraction: 1)
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
            .progressViewStyle(YinYangLoadingStyle())
            .environment(\.loadingMotionEnabled, preferences.interfaceMotion)
            .toolbarBackground(.hidden, for: .windowToolbar)
            .background(
                ThemeWindowBridge(colors: palette).frame(width: 0, height: 0).accessibilityHidden(true)
            )
            .animation(nil, value: preferences.appearance)
            .animation(nil, value: palette)
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
                reduceMotion || !preferences.interfaceMotion ? nil : AppMotion.hover, value: hovering
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
    var body: some View {
        Image("BrandSymbol").resizable().interpolation(.high).scaledToFit().accessibilityHidden(true)
    }
}

struct WelcomeIdentity: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppPreferences.self) private var preferences
    @State private var revealed = false

    var body: some View {
        Image("BrandAppIcon").resizable().interpolation(.high).scaledToFit()
            .frame(width: 136, height: 136)
            .opacity(revealed || reduceMotion || !preferences.interfaceMotion ? 1 : 0)
            .scaleEffect(revealed || reduceMotion || !preferences.interfaceMotion ? 1 : 0.96)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
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

/// Categorical symbols add useful color while native row selection keeps its own readable state.
struct WorkbenchGlyph: View {
    @Environment(\.themeColors) private var colors
    let symbol: String
    var selected = false
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? colors.selectionText : colors.symbolTint(symbol))
            .frame(width: size, height: size)
            .background(
                selected ? Color.clear : colors.symbolTint(symbol).opacity(0.09), in: .rect(cornerRadius: 7)
            )
            .accessibilityHidden(true)
    }
}

struct SidebarIdentity: View {
    @Environment(\.themeColors) private var colors
    let repository: String

    var body: some View {
        HStack(spacing: 10) {
            HeritageBrandSeal(tint: colors.brand, size: 36)
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

struct WorkbenchEmblem: View {
    @Environment(\.themeColors) private var colors
    let symbol: String
    var tint: Color?

    private var artwork: HeritageArtwork.Kind? {
        switch symbol {
        case "checkmark.circle", "checkmark.circle.fill": .bamboo
        case "archivebox", "archivebox.fill": .scroll
        case "clock", "clock.arrow.circlepath": .mountain
        case "tag", "tag.fill", "doc", "doc.text", "doc.text.magnifyingglass": .folio
        default: nil
        }
    }

    @ViewBuilder
    var body: some View {
        if let artwork {
            HeritageArtwork(kind: artwork, tint: tint)
        } else {
            Image(systemName: symbol).font(.system(size: 23, weight: .regular))
                .foregroundStyle(tint ?? colors.text).frame(width: 48, height: 48)
                .background(colors.celadon.opacity(0.08), in: HeritageSeal(cornerRadius: 4))
                .overlay {
                    HeritageSeal(cornerRadius: 4).strokeBorder(colors.border, lineWidth: 0.7)
                }
                .frame(width: HeritageTokens.artworkSize.width, height: HeritageTokens.artworkSize.height)
                .accessibilityHidden(true).allowsHitTesting(false)
        }
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
