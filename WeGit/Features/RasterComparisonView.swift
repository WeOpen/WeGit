import AppKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WeGitCore

enum RasterComparisonSource {
    case workspace(path: String, layer: DiffLayer, oldPath: String?)
    case commit(CommitFileChange, CommitComparison)
    var key: String {
        switch self {
        case .workspace(let path, let layer, let old): "work:\(layer.rawValue):\(path):\(old ?? "")"
        case .commit(let file, let comparison):
            "commit:\(comparison.commit.id):\(comparison.parent ?? ""):\(file.path)"
        }
    }
    func prepare(_ service: RepositoryService) async throws -> RasterComparisonInput {
        switch self {
        case .workspace(let path, let layer, let old):
            try await service.prepareRasterComparison(path: path, layer: layer, oldPath: old)
        case .commit(let file, let comparison):
            try await service.prepareRasterComparison(file: file, comparison: comparison)
        }
    }
}

private final class RasterMemoryGate: @unchecked Sendable {
    nonisolated static let shared = RasterMemoryGate()
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var used = 0
    nonisolated init() {}
    nonisolated func reserve(_ bytes: Int) throws -> RasterMemoryLease {
        try lock.withLock {
            // Leave room within the 512 MiB application budget for the workbench.
            guard bytes >= 0, bytes <= 384 * 1024 * 1024 - used else {
                throw ModelFailure.unsupported(L10n.text("图片内存预算已占用，请关闭原尺寸图片后重试。"))
            }
            used += bytes
            return RasterMemoryLease(gate: self, bytes: bytes)
        }
    }
    nonisolated func release(_ bytes: Int) { lock.withLock { used -= bytes } }
}

private final class RasterMemoryLease: @unchecked Sendable {
    nonisolated private let gate: RasterMemoryGate
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var bytes: Int
    nonisolated init(gate: RasterMemoryGate, bytes: Int) {
        self.gate = gate
        self.bytes = bytes
    }
    nonisolated func reduce(to value: Int) {
        let released = lock.withLock {
            let old = bytes
            bytes = min(old, value)
            return old - bytes
        }
        gate.release(released)
    }
    deinit { gate.release(bytes) }
}

private struct DecodedRaster: @unchecked Sendable {
    let id = UUID()
    let image: CGImage
    let width: Int
    let height: Int
    let orientedSize: CGSize
    let byteCount: Int64
    let original: Bool
    let leases: [RasterMemoryLease]
}

private enum RasterSideRead: @unchecked Sendable {
    case loading, absent, symbolicLink, cancelled
    case oversized(Int64)
    case image(DecodedRaster)
    case pointer(RasterLFSPointer)
    case failure(String)
    var image: DecodedRaster? { if case .image(let image) = self { image } else { nil } }
}

private enum RasterDecoder {
    @concurrent static func read(
        _ input: RasterInput, service: RepositoryService, original: Bool
    ) async -> RasterSideRead {
        switch input.kind {
        case .absent: return .absent
        case .oversized: return .oversized(input.byteCount)
        case .symbolicLink: return .symbolicLink
        case .image: break
        }
        do {
            let encodedLease = try RasterMemoryGate.shared.reserve(Int(input.byteCount))
            let data = try await input.readBytes()
            try Task.checkCancellation()
            if let pointer = service.rasterLFSPointer(data) { return .pointer(pointer) }
            let image = try await Task.detached(priority: .userInitiated) {
                try autoreleasepool {
                    try Task.checkCancellation()
                    guard
                        let source = CGImageSourceCreateWithData(
                            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                        let type = CGImageSourceGetType(source) as String?,
                        [UTType.png.identifier, UTType.jpeg.identifier, UTType.webP.identifier].contains(
                            type),
                        let properties = CGImageSourceCopyPropertiesAtIndex(
                            source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
                    else { throw ModelFailure.unsupported(L10n.text("图片损坏或不是支持的 PNG、JPEG、WebP 格式。")) }
                    func dimension(_ key: CFString) throws -> Int {
                        guard let value = (properties[key] as? NSNumber)?.doubleValue,
                            value.isFinite, value > 0, value <= Double(RasterReadBudget.pixels),
                            value.rounded() == value
                        else { throw ModelFailure.unsupported(L10n.text("图片尺寸无法可靠读取。")) }
                        return Int(value)
                    }
                    let width = try dimension(kCGImagePropertyPixelWidth)
                    let height = try dimension(kCGImagePropertyPixelHeight)
                    guard width <= RasterReadBudget.pixels / height else {
                        throw ModelFailure.unsupported(L10n.text("图片超过 6400 万像素上限。"))
                    }
                    let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
                    let pixelBytes = depth > 8 ? 8 : 4
                    func estimated(_ width: Int, _ height: Int) -> Int {
                        ((width * pixelBytes + 63) / 64 * 64) * height
                    }
                    let full = max(estimated(width, height), estimated(height, width))
                    guard full <= RasterReadBudget.decodedBytes else {
                        throw ModelFailure.unsupported(L10n.text("图片预计解码内存超过上限。"))
                    }
                    let edge = original ? max(width, height) : RasterReadBudget.thumbnailEdge
                    let thumbnail = estimated(min(edge, width), min(edge, height))
                    let decodedLease = try RasterMemoryGate.shared.reserve(full + (original ? 0 : thumbnail))
                    guard
                        let image = CGImageSourceCreateThumbnailAtIndex(
                            source, 0,
                            [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceThumbnailMaxPixelSize: edge,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceShouldCacheImmediately: true,
                            ] as CFDictionary)
                    else { throw ModelFailure.unsupported(L10n.text("图片无法解码。")) }
                    try Task.checkCancellation()
                    guard image.height > 0, image.bytesPerRow <= RasterReadBudget.decodedBytes / image.height,
                        original || max(image.width, image.height) <= RasterReadBudget.thumbnailEdge
                    else { throw ModelFailure.unsupported(L10n.text("图片解码结果超过上限。")) }
                    decodedLease.reduce(to: image.bytesPerRow * image.height)
                    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                    let rotates = (5...8).contains(orientation)
                    return DecodedRaster(
                        image: image, width: width, height: height,
                        orientedSize: CGSize(
                            width: rotates ? height : width, height: rotates ? width : height),
                        byteCount: input.byteCount, original: original, leases: [encodedLease, decodedLease])
                }
            }.value
            try Task.checkCancellation()
            return .image(image)
        } catch is CancellationError { return .failure(L10n.text("已取消读取")) } catch {
            return .failure(error.localizedDescription)
        }
    }
}

@Observable @MainActor
private final class RasterComparisonState {
    let source: RasterComparisonSource
    let service: RepositoryService
    var inputs: RasterComparisonInput?
    var sides: [RasterSideRead] = [.loading, .loading]
    var error: String?
    @ObservationIgnored private var tasks: [Task<Void, Never>?] = [nil, nil]
    @ObservationIgnored private var requests = [UUID(), UUID()]
    @ObservationIgnored private var generation = UUID()
    init(source: RasterComparisonSource, service: RepositoryService) {
        self.source = source
        self.service = service
    }
    func prepare() async {
        cancel()
        let token = UUID()
        generation = token
        sides = [.loading, .loading]
        error = nil
        do {
            let inputs = try await source.prepare(service)
            guard !Task.isCancelled, generation == token else { return }
            self.inputs = inputs
            load(0, original: false)
            load(1, original: false)
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            self.error = error.localizedDescription
        }
    }
    func load(_ index: Int, original: Bool) {
        guard let inputs else { return }
        tasks[index]?.cancel()
        let token = UUID()
        requests[index] = token
        let input = index == 0 ? inputs.before : inputs.after
        sides[index] = .loading
        tasks[index] = Task {
            let value = await RasterDecoder.read(input, service: service, original: original)
            guard !Task.isCancelled, requests[index] == token else { return }
            sides[index] = value
            tasks[index] = nil
        }
    }
    func cancel(showFeedback: Bool = false) {
        generation = UUID()
        for task in tasks { task?.cancel() }
        tasks = [nil, nil]
        requests = [UUID(), UUID()]
        inputs = nil
        sides = showFeedback ? [.cancelled, .cancelled] : [.absent, .absent]
    }
}

struct RasterComparisonView: View {
    let app: AppState
    let session: RepositorySession
    @Environment(\.themeColors) private var colors
    @State private var model: RasterComparisonState
    @State private var wipe = false
    @State private var position = 0.5
    @State private var zoom: CGFloat = 1
    @State private var fit = UUID()
    init(app: AppState, session: RepositorySession, source: RasterComparisonSource) {
        self.app = app
        self.session = session
        _model = State(initialValue: RasterComparisonState(source: source, service: session.service))
    }
    static func supports(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "webp"].contains((path as NSString).pathExtension.lowercased())
    }
    private var extent: CGSize {
        CGSize(
            width: max(
                model.sides[0].image?.orientedSize.width ?? 0, model.sides[1].image?.orientedSize.width ?? 0),
            height: max(
                model.sides[0].image?.orientedSize.height ?? 0, model.sides[1].image?.orientedSize.height ?? 0
            ))
    }
    private var canWipe: Bool {
        model.sides.contains { $0.image != nil }
            && model.sides.allSatisfy {
                if case .absent = $0 { true } else { $0.image != nil }
            }
    }
    private var reading: Bool { model.sides.contains { if case .loading = $0 { true } else { false } } }
    private var layoutPicker: some View {
        Picker(L10n.text("图片布局"), selection: $wipe) {
            Text(L10n.text("对照")).tag(false)
            Text(L10n.text("滑杆")).tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 120).disabled(!canWipe)
            .accessibilityIdentifier("raster-layout")
    }
    private var resolutionMenu: some View {
        Menu(L10n.text("原尺寸")) {
            ForEach(0..<2) { index in
                if let image = model.sides[index].image {
                    Toggle(
                        sideTitle(index),
                        isOn: Binding(
                            get: { image.original }, set: { model.load(index, original: $0) }))
                }
            }
        }.disabled(!model.sides.contains { $0.image != nil })
            .accessibilityIdentifier("raster-resolution")
    }
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    layoutPicker
                    Button {
                        zoom = max(0.001, zoom / 1.25)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .accessibilityLabel(L10n.text("缩小图片")).accessibilityIdentifier("raster-zoom-out")
                    Button {
                        zoom = min(16, zoom * 1.25)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .accessibilityLabel(L10n.text("放大图片")).accessibilityIdentifier("raster-zoom-in")
                    Button(L10n.text("适合窗口")) { fit = UUID() }.accessibilityIdentifier("raster-fit")
                    Spacer()
                    Text(Double(zoom).formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    resolutionMenu
                    if reading {
                        Button(L10n.text("取消读取")) { model.cancel(showFeedback: true) }
                    }
                }
                HStack(spacing: 8) {
                    layoutPicker
                    Menu {
                        Button(L10n.text("适合窗口")) { fit = UUID() }
                        Button(L10n.text("缩小图片")) { zoom = max(0.001, zoom / 1.25) }
                        Button(L10n.text("放大图片")) { zoom = min(16, zoom * 1.25) }
                        resolutionMenu
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(L10n.text("图片阅读选项"))
                    Spacer()
                    Text(Double(zoom).formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    if reading {
                        Button {
                            model.cancel(showFeedback: true)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .accessibilityLabel(L10n.text("取消读取"))
                    }
                }
            }.font(.caption).padding(10).background(colors.chrome)
            if let error = model.error {
                EmptyPanel(title: L10n.text("无法读取图片"), symbol: "photo", message: error)
                Button(L10n.text("重试")) { Task { await model.prepare() } }.padding(10)
            } else {
                HStack {
                    metadata(0).frame(maxWidth: .infinity, alignment: .leading)
                    metadata(1).frame(maxWidth: .infinity, alignment: .trailing)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("raster-metadata")
                    .font(.caption).padding(10)
                if wipe && canWipe {
                    RasterViewport(
                        before: model.sides[0].image, after: model.sides[1].image,
                        extent: extent, wipe: position, zoom: $zoom, fit: fit,
                        label: L10n.text("图片滑杆比较"))
                    Slider(value: $position, in: 0...1).accessibilityLabel(L10n.text("比较位置"))
                        .accessibilityIdentifier("raster-position").padding(12)
                } else {
                    HStack(spacing: 1) {
                        pane(0)
                        pane(1)
                    }
                }
            }
        }.background(colors.canvas).task(id: model.source.key) { await model.prepare() }
            .onDisappear { model.cancel() }.accessibilityElement(children: .contain)
            .accessibilityIdentifier("raster-comparison")
    }
    private func sideTitle(_ index: Int) -> String { index == 0 ? L10n.text("起点") : L10n.text("目标") }
    @ViewBuilder private func metadata(_ index: Int) -> some View {
        HStack {
            Text(sideTitle(index))
            if let image = model.sides[index].image {
                Text("\(image.width) × \(image.height)").monospacedDigit()
                Text(ByteCountFormatter.string(fromByteCount: image.byteCount, countStyle: .file))
                    .foregroundStyle(colors.secondaryText)
            }
        }
    }
    @ViewBuilder private func pane(_ index: Int) -> some View {
        switch model.sides[index] {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let image):
            RasterViewport(
                before: image, after: nil, extent: extent, wipe: nil,
                zoom: $zoom, fit: fit, label: sideTitle(index))
        case .absent:
            Text(L10n.text("此版本没有图片")).foregroundStyle(colors.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cancelled:
            VStack(spacing: 10) {
                Text(L10n.text("已取消读取")).foregroundStyle(colors.secondaryText)
                Button(L10n.text("重新读取")) { Task { await model.prepare() } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .symbolicLink:
            Text(L10n.text("符号链接")).foregroundStyle(colors.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .oversized(let bytes):
            VStack(spacing: 10) {
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                Text(L10n.text("图片超过 32 MiB 读取上限。")).foregroundStyle(colors.secondaryText)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .pointer(let pointer):
            VStack(spacing: 10) {
                Text(L10n.text("LFS 指针")).font(.headline)
                Text(pointer.oid).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3).help(
                    pointer.oid)
                Text(ByteCountFormatter.string(fromByteCount: pointer.bytes, countStyle: .file))
                Button(L10n.text("查看 LFS")) {
                    guard app.session === session else { return }
                    app.workspace.inspectorResourcesRequestID = UUID()
                    app.workspace.inspector = true
                    app.referenceComparisonRequest = nil
                    app.fileHistoryRequest = nil
                    app.blameRequest = nil
                }
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(let message):
            VStack(spacing: 10) {
                Text(message).foregroundStyle(colors.negative)
                Button(L10n.text("重试")) { model.load(index, original: false) }
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct RasterViewport: NSViewRepresentable {
    let before: DecodedRaster?
    let after: DecodedRaster?
    let extent: CGSize
    let wipe: Double?
    @Binding var zoom: CGFloat
    let fit: UUID
    let label: String
    func makeNSView(context: Context) -> RasterViewportView {
        let view = RasterViewportView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        return view
    }
    func updateNSView(_ view: RasterViewportView, context: Context) {
        view.before = before
        view.after = after
        if view.extent != extent {
            view.extent = extent
            view.needsFit = true
        }
        view.wipe = wipe
        if abs(view.zoom - zoom) > 0.0001, !view.needsFit { view.autoFit = false }
        view.zoom = zoom
        view.onZoom = { [weak view] value in
            DispatchQueue.main.async {
                guard let view, view.window != nil, abs(zoom - value) > 0.0001 else { return }
                zoom = value
            }
        }
        if view.fit != fit {
            view.fit = fit
            view.needsFit = true
            view.autoFit = true
        }
        view.setAccessibilityLabel(label)
        view.needsLayout = true
        view.needsDisplay = true
    }
}

// Core Animation can evaluate the pattern on its render queue.
private nonisolated func drawRasterCheckerboardPattern(
    _ info: UnsafeMutableRawPointer?, _ context: CGContext
) {
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    context.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
}

@MainActor private final class RasterViewportView: NSView {
    var before: DecodedRaster?
    var after: DecodedRaster?
    var extent = CGSize.zero
    var wipe: Double?
    var zoom: CGFloat = 1
    var fit: UUID?
    var needsFit = true
    var autoFit = true
    var pan = CGPoint.zero
    var onZoom: ((CGFloat) -> Void)?
    private var dragPoint: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed, autoFit {
            needsFit = true
            needsLayout = true
        }
    }
    override func layout() {
        super.layout()
        if needsFit, extent.width > 0, extent.height > 0, bounds.width > 0, bounds.height > 0 {
            zoom = max(0.001, min(16, min(bounds.width / extent.width, bounds.height / extent.height)))
            pan = .zero
            needsFit = false
            onZoom?(zoom)
            needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        checkerboard(context, rect: bounds)
        let origin = CGPoint(
            x: (bounds.width - extent.width * zoom) / 2 + pan.x,
            y: (bounds.height - extent.height * zoom) / 2 + pan.y)
        func draw(_ raster: DecodedRaster?) {
            guard let raster else { return }
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y + raster.orientedSize.height * zoom)
            context.scaleBy(x: zoom, y: -zoom)
            context.draw(raster.image, in: CGRect(origin: .zero, size: raster.orientedSize))
            context.restoreGState()
        }
        draw(before)
        if let wipe {
            context.saveGState()
            context.clip(
                to: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width * wipe, height: bounds.height))
            checkerboard(context, rect: bounds)
            draw(after)
            context.restoreGState()
            context.setStrokeColor(CGColor(gray: 0.4, alpha: 1))
            context.setLineWidth(1)
            context.move(to: CGPoint(x: bounds.width * wipe, y: 0))
            context.addLine(to: CGPoint(x: bounds.width * wipe, y: bounds.height))
            context.strokePath()
        }
    }
    private func checkerboard(_ context: CGContext, rect: CGRect) {
        var callbacks = CGPatternCallbacks(
            version: 0,
            drawPattern: drawRasterCheckerboardPattern, releaseInfo: nil)
        guard
            let pattern = CGPattern(
                info: nil, bounds: CGRect(x: 0, y: 0, width: 16, height: 16),
                matrix: .identity, xStep: 16, yStep: 16, tiling: .constantSpacing,
                isColored: true, callbacks: &callbacks),
            let space = CGColorSpace(patternBaseSpace: nil)
        else { return }
        context.saveGState()
        context.setFillColorSpace(space)
        var alpha: CGFloat = 1
        context.setFillPattern(pattern, colorComponents: &alpha)
        context.fill(rect)
        context.restoreGState()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragPoint = convert(event.locationInWindow, from: nil)
    }
    override func mouseDragged(with event: NSEvent) {
        autoFit = false
        let point = convert(event.locationInWindow, from: nil)
        if let previous = dragPoint {
            pan.x += point.x - previous.x
            pan.y += point.y - previous.y
        }
        dragPoint = point
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { dragPoint = nil }
    override func scrollWheel(with event: NSEvent) {
        autoFit = false
        pan.x -= event.scrollingDeltaX
        pan.y -= event.scrollingDeltaY
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        autoFit = false
        let point = convert(event.locationInWindow, from: nil)
        let oldOrigin = CGPoint(
            x: (bounds.width - extent.width * zoom) / 2 + pan.x,
            y: (bounds.height - extent.height * zoom) / 2 + pan.y)
        let anchor = CGPoint(x: (point.x - oldOrigin.x) / zoom, y: (point.y - oldOrigin.y) / zoom)
        zoom = max(0.001, min(16, zoom * (1 + event.magnification)))
        pan.x = point.x - anchor.x * zoom - (bounds.width - extent.width * zoom) / 2
        pan.y = point.y - anchor.y * zoom - (bounds.height - extent.height * zoom) / 2
        onZoom?(zoom)
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        autoFit = false
        switch event.keyCode {
        case 123: pan.x += 40
        case 124: pan.x -= 40
        case 125: pan.y -= 40
        case 126: pan.y += 40
        default:
            super.keyDown(with: event)
            return
        }
        needsDisplay = true
    }
}
