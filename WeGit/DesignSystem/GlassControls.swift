import AppKit
import SwiftUI

/// Native button styles keep default actions, roles, focus and pressed feedback intact.
private struct GlassControlFamily: ViewModifier {
    @Environment(\.themeColors) private var colors
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.buttonStyle(NeutralGlassButton(solid: reduceTransparency || contrast == .increased))
    }
}

/// Keep secondary buttons neutral without clearing the accent of switches and primary actions.
private struct NeutralGlassButton: PrimitiveButtonStyle {
    let solid: Bool

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if solid {
                Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                    .buttonStyle(.bordered)
            } else {
                Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                    .buttonStyle(.glass)
            }
        }.buttonBorderShape(.capsule).tint(nil)
    }
}

private struct GlassPrimaryAction: ViewModifier {
    @Environment(\.themeColors) private var colors
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.foregroundStyle(enabled ? colors.selectionText : colors.secondaryText).buttonStyle(
                .borderedProminent
            ).buttonBorderShape(
                .capsule)
        } else {
            content.foregroundStyle(enabled ? colors.selectionText : colors.secondaryText).buttonStyle(
                .glassProminent
            ).buttonBorderShape(
                .capsule)
        }
    }
}

private struct GlassIconAction: ViewModifier {
    @Environment(\.themeColors) private var colors
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency || contrast == .increased {
                content.buttonStyle(.bordered)
            } else {
                content.buttonStyle(.glass)
            }
        }.buttonBorderShape(.circle).labelStyle(.iconOnly).tint(nil)
    }
}

private struct GlassMenuSurface: ViewModifier {
    @Environment(\.themeColors) private var colors
    let icon: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        Group {
            if icon {
                content.menuIndicator(.hidden).labelStyle(.iconOnly)
                    .frame(width: AppStyle.controlHeight, height: AppStyle.controlHeight)
            } else {
                content.padding(.horizontal, 10).frame(minHeight: AppStyle.controlHeight)
            }
        }
        .menuStyle(.borderlessButton)
        .tint(nil)
        .modifier(GlassCapsuleSurface(solid: reduceTransparency || contrast == .increased))
    }
}

private struct GlassCapsuleSurface: ViewModifier {
    @Environment(\.themeColors) private var colors
    let solid: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if solid {
            content.background(colors.surface, in: .capsule)
                .overlay {
                    Capsule().strokeBorder(colors.border, lineWidth: contrast == .increased ? 2 : 1)
                        .allowsHitTesting(false)
                }
        } else {
            content.glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}

extension View {
    func workbenchControlFamily() -> some View { modifier(GlassControlFamily()) }
    func workbenchPrimaryAction() -> some View { modifier(GlassPrimaryAction()) }
    func workbenchIconButton() -> some View { modifier(GlassIconAction()) }
    func workbenchGlassMenu(icon: Bool = false) -> some View { modifier(GlassMenuSurface(icon: icon)) }
}

struct GlassTab<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var symbol: String?
    var id: Value { value }
}

/// The transparent native control owns hit testing, focus, arrow keys and AX radio buttons.
/// SwiftUI draws one material track and one moving glass lens beneath it.
struct WorkbenchGlassTabs<Value: Hashable>: View {
    @Environment(\.themeColors) private var colors
    let title: String
    @Binding var selection: Value
    let tabs: [GlassTab<Value>]
    var height: CGFloat = AppStyle.controlHeight
    var identifier: String?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(AppPreferences.self) private var preferences
    @Namespace private var lens

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    HStack(spacing: 5) {
                        if let symbol = tab.symbol { Image(systemName: symbol) }
                        Text(tab.title).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: selection == tab.value ? .semibold : .medium))
                    .foregroundStyle(selection == tab.value ? colors.text : colors.secondaryText)
                    .frame(maxWidth: .infinity).frame(height: height - 8)
                    .background {
                        if selection == tab.value {
                            tabLens.matchedGeometryEffect(id: "selection", in: lens)
                        }
                    }
                }
            }.padding(4).accessibilityHidden(true).allowsHitTesting(false)
            GlassSegmentInteraction(
                title: title, labels: tabs.map(\.title),
                selection: Binding(
                    get: { tabs.firstIndex { $0.value == selection } ?? -1 },
                    set: { if tabs.indices.contains($0) { selection = tabs[$0].value } }),
                enabled: enabled, identifier: identifier)
        }
        .frame(height: height)
        .background {
            if reduceTransparency || contrast == .increased {
                Capsule().fill(colors.surface)
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay {
            Capsule().strokeBorder(colors.border, lineWidth: contrast == .increased ? 2 : 0.5)
                .allowsHitTesting(false)
        }
        .opacity(enabled ? 1 : 0.5)
        .animation(
            reduceMotion || !preferences.interfaceMotion ? nil : .spring(response: 0.28, dampingFraction: 1),
            value: selection)
    }

    @ViewBuilder private var tabLens: some View {
        if reduceTransparency || contrast == .increased {
            Capsule().fill(colors.text.opacity(0.1))
                .overlay { Capsule().strokeBorder(colors.border, lineWidth: 1) }
        } else {
            Capsule().fill(colors.text.opacity(0.045)).glassEffect(.regular, in: .capsule)
        }
    }
}

private struct GlassSegmentInteraction: NSViewRepresentable {
    @Environment(\.themeColors) private var colors
    let title: String
    let labels: [String]
    @Binding var selection: Int
    let enabled: Bool
    let identifier: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TransparentSegments, context: Context) -> CGSize?
    {
        CGSize(
            width: proposal.width ?? nsView.intrinsicContentSize.width,
            height: proposal.height ?? AppStyle.controlHeight)
    }

    func makeNSView(context: Context) -> TransparentSegments {
        let view = TransparentSegments()
        view.focusRingType = .none
        view.cell?.focusRingType = .none
        view.trackingMode = .selectOne
        view.target = context.coordinator
        view.action = #selector(Coordinator.select(_:))
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TransparentSegments, context: Context) {
        view.focusStroke = colors.resolvedNSColor(.text).withAlphaComponent(0.5)
        context.coordinator.parent = self
        if view.segmentCount != labels.count { view.segmentCount = labels.count }
        for (index, label) in labels.enumerated() where view.label(forSegment: index) != label {
            view.setLabel(label, forSegment: index)
        }
        view.selectedSegment = selection
        view.isEnabled = enabled
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier(identifier)
        view.needsLayout = true
    }

    @MainActor final class Coordinator: NSObject {
        var parent: GlassSegmentInteraction
        init(_ parent: GlassSegmentInteraction) { self.parent = parent }
        @objc func select(_ sender: NSSegmentedControl) { parent.selection = sender.selectedSegment }
    }
}

private final class TransparentSegments: NSSegmentedControl {
    var focusStroke = NSColor.labelColor.withAlphaComponent(0.5)
    private var showsKeyboardFocus = false
    override var acceptsFirstResponder: Bool { isEnabled }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        showsKeyboardFocus = false
        needsDisplay = true
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        showsKeyboardFocus = true
        needsDisplay = true
        // NSSegmentedControl normally moves AX focus before Space selects. Tabs
        // activate immediately with arrows so focus, lens and visible page agree.
        guard isEnabled, segmentCount > 0,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            event.keyCode == 123 || event.keyCode == 124
        else {
            super.keyDown(with: event)
            return
        }
        let delta = event.keyCode == 123 ? -1 : 1
        let next = min(segmentCount - 1, max(0, selectedSegment + delta))
        guard next != selectedSegment else { return }
        selectedSegment = next
        sendAction(action, to: target)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard segmentCount > 0 else { return }
        let width = max(0, bounds.width - 8) / CGFloat(segmentCount)
        for index in 0..<segmentCount where self.width(forSegment: index) != width {
            setWidth(width, forSegment: index)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self, showsKeyboardFocus {
            focusStroke.setStroke()
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2,
                yRadius: bounds.height / 2)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { showsKeyboardFocus = NSApp.currentEvent?.type == .keyDown }
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }
}
