import AppKit
import SwiftUI

/// Native button styles keep default actions, roles, focus and pressed feedback intact.
private struct GlassControlFamily: ViewModifier {
    @Environment(\.themeColors) private var colors
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var toolbar = false

    func body(content: Content) -> some View {
        content.buttonStyle(
            NeutralGlassButton(solid: reduceTransparency || contrast == .increased, inToolbar: toolbar))
    }
}

/// The glass style sizes its background from the label, so the label has to be
/// the one that reserves the height. A frame outside the button style only pads
/// the layout cell and leaves the capsule drawn at the text height. Glass also
/// insets the label by a size-dependent amount, so ask for the label height that
/// lands the whole control on the shared target instead of the target itself.
///
/// Unified toolbar controls own a shared 36pt surface. Using a native glass
/// button alongside a custom glass menu otherwise sizes each from a different
/// label, and adding a counter changes the native capsule's height.
private struct GlassMetrics {
    let controlSize: ControlSize?

    /// Outer heights the rest of the interface already uses: 30pt toolbar
    /// controls, the 26pt inline action and the 24pt compact icon button.
    private var outerHeight: CGFloat {
        switch controlSize {
        case .mini: AppStyle.compactControlHeight
        case .small: AppStyle.smallControlHeight
        case .large: AppStyle.largeControlHeight
        default: AppStyle.controlHeight
        }
    }

    /// Measured padding the system glass style adds around the label.
    private var inset: CGFloat {
        switch controlSize {
        case .mini: 2
        case .small: 6
        case .large: 12
        default: 8
        }
    }

    var labelHeight: CGFloat { outerHeight - inset }
    var labelMinimumWidth: CGFloat {
        switch controlSize {
        case .mini: 16
        case .small: 48
        case .large: 96
        default: AppStyle.actionMinimumWidth - 16
        }
    }
}

/// Keep secondary buttons neutral without clearing the accent of switches and primary actions.
private struct NeutralGlassButton: PrimitiveButtonStyle {
    let solid: Bool
    var inToolbar = false
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let metrics = GlassMetrics(controlSize: controlSize)
        let label = configuration.label.frame(
            minWidth: metrics.labelMinimumWidth, minHeight: metrics.labelHeight)
        return Group {
            if inToolbar {
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label.font(.system(size: AppStyle.toolbarSymbolSize))
                        .padding(.horizontal, 12).frame(height: AppStyle.toolbarControlHeight)
                        .contentShape(Capsule())
                }.buttonStyle(ToolbarGlassButtonStyle(solid: solid))
            } else if solid {
                Button(role: configuration.role, action: configuration.trigger) { label }
                    .buttonStyle(.bordered)
            } else {
                Button(role: configuration.role, action: configuration.trigger) { label }
                    .buttonStyle(.glass)
            }
        }.buttonBorderShape(.capsule).tint(nil)
    }
}

private struct GlassPrimaryAction: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.buttonStyle(PrimaryGlassButton(solid: reduceTransparency || contrast == .increased))
    }
}

/// Primary and secondary controls reserve the same label metrics before native styling.
private struct PrimaryGlassButton: PrimitiveButtonStyle {
    let solid: Bool
    @Environment(\.themeColors) private var colors
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let metrics = GlassMetrics(controlSize: controlSize)
        let label = configuration.label
            .frame(minWidth: metrics.labelMinimumWidth, minHeight: metrics.labelHeight)
            .foregroundStyle(enabled ? colors.selectionText : colors.secondaryText)
        return Group {
            if solid {
                Button(role: configuration.role, action: configuration.trigger) { label }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(role: configuration.role, action: configuration.trigger) { label }
                    .buttonStyle(.glassProminent)
            }
        }.buttonBorderShape(.capsule).tint(colors.primaryAction)
    }
}

/// Circular actions hit the same trap as the capsule buttons: a frame outside the
/// button style pads the cell while the glass circle stays at the glyph's size.
private struct GlassIconButton: PrimitiveButtonStyle {
    let solid: Bool
    var inToolbar = false
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let side = GlassMetrics(controlSize: controlSize).labelHeight
        let label = configuration.label.labelStyle(.iconOnly).frame(width: side, height: side)
        return Group {
            if inToolbar {
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label.labelStyle(.iconOnly).font(.system(size: AppStyle.toolbarSymbolSize))
                        .frame(width: AppStyle.toolbarControlHeight, height: AppStyle.toolbarControlHeight)
                        .contentShape(Circle())
                }.buttonStyle(ToolbarGlassButtonStyle(solid: solid))
            } else if solid {
                Button(role: configuration.role, action: configuration.trigger) { label }
                    .buttonStyle(.bordered)
            } else {
                Button(role: configuration.role, action: configuration.trigger) { label }
                    .buttonStyle(.glass)
            }
        }.buttonBorderShape(.circle).tint(nil)
    }
}

private struct GlassMenuSurface: ViewModifier {
    @Environment(\.themeColors) private var colors
    let icon: Bool
    var toolbar = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        // Match the same owned surface used by toolbar buttons and the sidebar toggle.
        let height = toolbar ? AppStyle.toolbarControlHeight : AppStyle.controlHeight
        return Group {
            if icon {
                content.menuIndicator(.hidden).labelStyle(.iconOnly)
                    .frame(width: height, height: height)
            } else {
                content.padding(.horizontal, 10).frame(
                    minWidth: AppStyle.actionMinimumWidth, minHeight: height)
            }
        }
        .menuStyle(.borderlessButton)
        .modifier(ToolbarLabelFont(enabled: toolbar))
        .tint(nil)
        .modifier(GlassCapsuleSurface(solid: reduceTransparency || contrast == .increased))
    }
}

private struct ToolbarLabelFont: ViewModifier {
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.font(.system(size: AppStyle.toolbarSymbolSize))
        } else {
            content
        }
    }
}

/// ButtonStyle reads the native pressed state; it never replaces Button's input gesture.
private struct ToolbarGlassButtonStyle: ButtonStyle {
    let solid: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppPreferences.self) private var preferences

    func makeBody(configuration: Configuration) -> some View {
        let pressed = enabled && configuration.isPressed
        let motion = enabled && preferences.interfaceMotion && !reduceMotion
        return configuration.label
            .modifier(GlassCapsuleSurface(solid: solid, pressed: pressed))
            .scaleEffect(pressed && motion ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.52)
            .animation(motion ? AppMotion.feedback : nil, value: pressed)
    }
}

private struct GlassCapsuleSurface: ViewModifier {
    @Environment(\.themeColors) private var colors
    let solid: Bool
    var pressed = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(AppPreferences.self) private var preferences
    @State private var hovering = false

    func body(content: Content) -> some View {
        Group {
            if solid {
                content.background {
                    Capsule().fill(colors.surface)
                        .overlay { Capsule().fill(colors.celadon.opacity(0.08)) }
                }
                .overlay {
                    Capsule().strokeBorder(colors.controlBorder, lineWidth: contrast == .increased ? 2 : 1)
                        .allowsHitTesting(false)
                }
            } else {
                content.glassEffect(.regular.tint(colors.celadon.opacity(0.1)).interactive(), in: .capsule)
            }
        }
        .overlay {
            Capsule().fill(colors.text.opacity(enabled ? (pressed ? 0.09 : hovering ? 0.04 : 0) : 0))
                .allowsHitTesting(false)
        }
        .onHover { hovering = enabled && $0 }
        .animation(reduceMotion || !preferences.interfaceMotion ? nil : AppMotion.hover, value: hovering)
    }
}

private struct GlassIconFamily: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var toolbar = false

    func body(content: Content) -> some View {
        content.buttonStyle(
            GlassIconButton(solid: reduceTransparency || contrast == .increased, inToolbar: toolbar))
    }
}

private struct WorkbenchSheetSurface: ViewModifier {
    @Environment(\.themeColors) private var colors
    func body(content: Content) -> some View { content.background(colors.canvas) }
}

extension View {
    /// A sheet is a native presentation boundary: install its styles explicitly.
    func workbenchSheet(_ preferences: AppPreferences) -> some View {
        modifier(WorkbenchSheetSurface()).workbenchControlFamily().workbenchAppearance(preferences)
    }
}

extension View {
    func workbenchControlFamily(toolbar: Bool = false) -> some View {
        modifier(GlassControlFamily(toolbar: toolbar))
    }
    func workbenchPrimaryAction() -> some View { modifier(GlassPrimaryAction()) }
    func workbenchIconButton(toolbar: Bool = false) -> some View {
        modifier(GlassIconFamily(toolbar: toolbar))
    }
    func workbenchGlassMenu(icon: Bool = false, toolbar: Bool = false) -> some View {
        modifier(GlassMenuSurface(icon: icon, toolbar: toolbar))
    }
}

struct GlassTab<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var symbol: String?
    var id: Value { value }
}

private enum SegmentInputSource: Equatable {
    case immediate, pointer, keyboard
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
    @State private var lensSelection: Value? = nil
    @State private var immediateLensRevision = 0

    private var motionEnabled: Bool { enabled && preferences.interfaceMotion && !reduceMotion }
    private var lensNeedsSync: Bool { lensSelection.map { $0 != selection } ?? false }
    private var presentedSelection: Value {
        if let lensSelection, lensSelection == selection { return lensSelection }
        return selection
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    Color.clear.frame(maxWidth: .infinity).frame(height: height - 8)
                        .background {
                            if presentedSelection == tab.value {
                                if motionEnabled {
                                    tabLens.matchedGeometryEffect(id: "selection", in: lens)
                                } else {
                                    tabLens
                                }
                            }
                        }
                }
            }
            .padding(4).accessibilityHidden(true).allowsHitTesting(false)
            .id(immediateLensRevision)
            .transaction {
                if !motionEnabled || lensNeedsSync {
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
            }
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    HStack(spacing: 5) {
                        if let symbol = tab.symbol {
                            Image(systemName: symbol).foregroundStyle(colors.symbolTint(symbol))
                        }
                        Text(tab.title).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: selection == tab.value ? .semibold : .medium))
                    .foregroundStyle(selection == tab.value ? colors.text : colors.secondaryText)
                    .frame(maxWidth: .infinity).frame(height: height - 8)
                }
            }.padding(4).accessibilityHidden(true).allowsHitTesting(false)
                .transaction {
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
            GlassSegmentInteraction(
                title: title, labels: tabs.map(\.title),
                selection: tabs.firstIndex { $0.value == selection } ?? -1,
                enabled: enabled, identifier: identifier, onSelection: select,
                onKeyboardInput: stopLens)
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
        .onAppear { synchronizeLens() }
        .onChange(of: selection) { synchronizeLens() }
        .onChange(of: tabs.map(\.value)) { synchronizeLens() }
        .onChange(of: motionEnabled) { synchronizeLens() }
    }

    private func select(_ index: Int, _ source: SegmentInputSource) {
        guard enabled, tabs.indices.contains(index) else { return }
        let value = tabs[index].value
        var immediate = Transaction(animation: nil)
        immediate.disablesAnimations = true
        withTransaction(immediate) { selection = value }
        if source == .pointer, motionEnabled {
            withAnimation(AppMotion.selection) { lensSelection = value }
        } else {
            synchronizeLensImmediately(to: value)
        }
    }

    private func synchronizeLens() {
        // The pointer callback sets its target in the same call stack as the model.
        // Do not overwrite that local spring when the binding's onChange arrives.
        guard lensSelection != selection else { return }
        synchronizeLensImmediately(to: selection)
    }

    private func stopLens() { synchronizeLensImmediately(to: selection) }

    private func synchronizeLensImmediately(to value: Value) {
        var immediate = Transaction(animation: nil)
        immediate.disablesAnimations = true
        withTransaction(immediate) {
            lensSelection = value
            // Recreate only the decorative track to cancel a pointer spring even
            // when a keyboard action selects the same endpoint. Native identity stays stable.
            immediateLensRevision &+= 1
        }
    }

    @ViewBuilder private var tabLens: some View {
        if reduceTransparency || contrast == .increased {
            Capsule().fill(colors.text.opacity(0.08))
                .overlay { Capsule().strokeBorder(colors.controlBorder, lineWidth: 1) }
        } else {
            Capsule().fill(colors.text.opacity(0.04))
                .glassEffect(.regular.tint(colors.celadon.opacity(0.08)), in: .capsule)
        }
    }
}

private struct GlassSegmentInteraction: NSViewRepresentable {
    @Environment(\.themeColors) private var colors
    let title: String
    let labels: [String]
    let selection: Int
    let enabled: Bool
    let identifier: String?
    let onSelection: (Int, SegmentInputSource) -> Void
    let onKeyboardInput: () -> Void

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
        view.onKeyboardInput = { [weak coordinator = context.coordinator] in
            coordinator?.keyboardInput()
        }
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TransparentSegments, context: Context) {
        view.focusStroke = NSColor(colors.controlBorder)
        context.coordinator.parent = self
        if view.segmentCount != labels.count { view.segmentCount = labels.count }
        for (index, label) in labels.enumerated() where view.label(forSegment: index) != label {
            view.setLabel(label, forSegment: index)
        }
        if view.selectedSegment != selection { view.selectedSegment = selection }
        view.isEnabled = enabled
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier(identifier)
        view.needsLayout = true
        view.needsDisplay = true
    }

    @MainActor final class Coordinator: NSObject {
        var parent: GlassSegmentInteraction
        init(_ parent: GlassSegmentInteraction) { self.parent = parent }
        @objc func select(_ sender: NSSegmentedControl) {
            let source = (sender as? TransparentSegments)?.inputSource ?? .immediate
            parent.onSelection(sender.selectedSegment, source)
        }
        func keyboardInput() { parent.onKeyboardInput() }
    }
}

private final class TransparentSegments: NSSegmentedControl {
    var focusStroke = NSColor.labelColor.withAlphaComponent(0.5)
    private(set) var inputSource = SegmentInputSource.immediate
    var onKeyboardInput: (() -> Void)?
    private var showsKeyboardFocus = false
    override var acceptsFirstResponder: Bool { isEnabled }

    override func mouseDown(with event: NSEvent) {
        let previous = inputSource
        inputSource = .pointer
        defer { inputSource = previous }
        window?.makeFirstResponder(self)
        showsKeyboardFocus = false
        needsDisplay = true
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let previous = inputSource
        inputSource = .keyboard
        defer { inputSource = previous }
        onKeyboardInput?()
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
