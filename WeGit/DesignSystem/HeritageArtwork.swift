import SwiftUI

/// Decorative dimensions do not add roles to the version-one theme format.
enum HeritageTokens {
    static let artworkSize = CGSize(width: 112, height: 86)
    static let inkLineWidth: CGFloat = 1.1
    static let sealRadius: CGFloat = 2
    static let referenceRadius: CGFloat = 4
    static let referenceHeight: CGFloat = 22
    static let referenceCut: CGFloat = 1.5
    static let cornerSize: CGFloat = 14
}

/// A fine square boundary. The caller supplies the actual brand or result symbol.
struct HeritageSeal: InsettableShape {
    var cornerRadius: CGFloat
    private var insetAmount: CGFloat = 0

    init(cornerRadius: CGFloat = HeritageTokens.sealRadius) {
        self.cornerRadius = cornerRadius
    }

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        return Path(
            roundedRect: bounds,
            cornerRadius: min(
                max(0, cornerRadius - insetAmount), max(0, min(bounds.width, bounds.height) / 8)))
    }

    func inset(by amount: CGFloat) -> HeritageSeal {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Uses the production R4 cinnabar symbol, including its compact Ku impression.
struct HeritageBrandSeal: View {
    @Environment(\.themeColors) private var colors
    var tint: Color?
    var size: CGFloat = 36

    var body: some View {
        BrandMark().frame(width: size, height: size)
            .accessibilityHidden(true).allowsHitTesting(false)
    }

}

/// A real brand impression reserved for a verified completion context.
struct HeritageKuStamp: View {
    @Environment(\.themeColors) private var colors
    var size: CGFloat = 20
    var body: some View {
        Path(BrandGeometry.seal(in: CGRect(x: 0, y: 0, width: size, height: size)))
            .fill(colors.brand, style: FillStyle(eoFill: true))
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Two small turns of a lattice corner, reserved for identity surfaces.
struct HeritageCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.26))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.26))
        return path
    }
}

/// A short paper signature with a shallow cut; no invented status dots.
struct HeritageReferenceShape: InsettableShape {
    private var insetAmount: CGFloat = 0

    init() {}

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = min(max(0, HeritageTokens.referenceRadius - insetAmount), max(0, bounds.height / 4))
        let cut = bounds.height < 18 ? 0 : HeritageTokens.referenceCut
        var path = Path()
        path.move(to: CGPoint(x: bounds.minX + radius, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX - radius - cut, y: bounds.minY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.maxX - cut, y: bounds.minY + radius),
            control: CGPoint(x: bounds.maxX - cut, y: bounds.minY))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY + radius + cut))
        path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: bounds.maxX - radius, y: bounds.maxY),
            control: CGPoint(x: bounds.maxX, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX + radius, y: bounds.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bounds.minX, y: bounds.maxY - radius),
            control: CGPoint(x: bounds.minX, y: bounds.maxY))
        path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: bounds.minX + radius, y: bounds.minY),
            control: CGPoint(x: bounds.minX, y: bounds.minY))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> HeritageReferenceShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Static line work for infrequent empty states; status and actions remain ordinary UI.
struct HeritageArtwork: View {
    enum Kind: Hashable, Sendable {
        case bamboo, mountain, scroll, folio, tally
    }

    @Environment(\.themeColors) private var colors
    let kind: Kind
    var tint: Color?

    var body: some View {
        Canvas { context, size in
            context.scaleBy(
                x: size.width / HeritageTokens.artworkSize.width,
                y: size.height / HeritageTokens.artworkSize.height)
            let drawing = HeritageDrawing.paths(for: kind)
            let ink = tint ?? colors.secondaryText
            let wash =
                tint.map { $0.opacity(0.08) } ?? colors.celadon.opacity(colors.increasedContrast ? 0.12 : 0.2)
            context.fill(drawing.wash, with: .color(wash))
            context.stroke(
                drawing.softLines, with: .color(ink.opacity(colors.increasedContrast ? 0.8 : 0.48)),
                style: StrokeStyle(lineWidth: HeritageTokens.inkLineWidth, lineCap: .round, lineJoin: .round))
            context.stroke(
                drawing.lines, with: .color(ink),
                style: StrokeStyle(lineWidth: HeritageTokens.inkLineWidth, lineCap: .round, lineJoin: .round))
            context.fill(drawing.details, with: .color(ink.opacity(0.82)))
        }
        .frame(width: HeritageTokens.artworkSize.width, height: HeritageTokens.artworkSize.height)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Logical 112 × 86 pt paths are built once and reused by the Canvas.
private struct HeritageDrawing {
    var lines = Path()
    var softLines = Path()
    var wash = Path()
    var details = Path()

    static func paths(for kind: HeritageArtwork.Kind) -> HeritageDrawing {
        switch kind {
        case .bamboo: bamboo
        case .mountain: mountain
        case .scroll: scroll
        case .folio: folio
        case .tally: tally
        }
    }

    // A tied bamboo tally: a physical label in the same quiet ink line vocabulary.
    private static let tally: HeritageDrawing = {
        var drawing = HeritageDrawing()
        var slip = Path()
        slip.move(to: CGPoint(x: 42, y: 24))
        slip.addLine(to: CGPoint(x: 65, y: 20))
        slip.addQuadCurve(to: CGPoint(x: 70, y: 25), control: CGPoint(x: 69, y: 20))
        slip.addLine(to: CGPoint(x: 76, y: 68))
        slip.addQuadCurve(to: CGPoint(x: 72, y: 73), control: CGPoint(x: 77, y: 72))
        slip.addLine(to: CGPoint(x: 48, y: 77))
        slip.addQuadCurve(to: CGPoint(x: 44, y: 73), control: CGPoint(x: 44, y: 78))
        slip.addLine(to: CGPoint(x: 38, y: 30))
        slip.addQuadCurve(to: CGPoint(x: 42, y: 24), control: CGPoint(x: 37, y: 25))
        slip.closeSubpath()
        drawing.lines = slip
        drawing.wash = slip
        drawing.lines.addEllipse(in: CGRect(x: 50, y: 28, width: 5, height: 5))
        drawing.lines.move(to: CGPoint(x: 53, y: 30))
        drawing.lines.addCurve(
            to: CGPoint(x: 65, y: 8), control1: CGPoint(x: 41, y: 10), control2: CGPoint(x: 70, y: 3))
        drawing.lines.addCurve(
            to: CGPoint(x: 53, y: 30), control1: CGPoint(x: 63, y: 17), control2: CGPoint(x: 49, y: 21))
        for y in [43.0, 51, 59] {
            drawing.softLines.move(to: CGPoint(x: 49, y: y))
            drawing.softLines.addLine(to: CGPoint(x: 65, y: y - 3))
        }
        drawing.softLines.move(to: CGPoint(x: 28, y: 77))
        drawing.softLines.addQuadCurve(to: CGPoint(x: 85, y: 77), control: CGPoint(x: 59, y: 82))
        return drawing
    }()

    private static let bamboo: HeritageDrawing = {
        var drawing = HeritageDrawing()
        drawing.lines.move(to: CGPoint(x: 44, y: 72))
        drawing.lines.addQuadCurve(to: CGPoint(x: 44, y: 31), control: CGPoint(x: 41, y: 53))
        drawing.lines.addLine(to: CGPoint(x: 47, y: 15))
        drawing.lines.move(to: CGPoint(x: 68, y: 72))
        drawing.lines.addQuadCurve(to: CGPoint(x: 63, y: 36), control: CGPoint(x: 69, y: 52))
        drawing.lines.addLine(to: CGPoint(x: 61, y: 20))
        for (x, y) in [(43.0, 57.0), (43, 43), (45, 29), (67, 57), (64, 41)] {
            drawing.lines.move(to: CGPoint(x: x - 2.5, y: y))
            drawing.lines.addLine(to: CGPoint(x: x + 2.5, y: y - 0.5))
        }
        for (root, tip, width) in [
            (CGPoint(x: 43, y: 44), CGPoint(x: 27, y: 34), 3.5),
            (CGPoint(x: 43, y: 43), CGPoint(x: 32, y: 49), 2.8),
            (CGPoint(x: 45, y: 29), CGPoint(x: 56, y: 19), 2.7),
            (CGPoint(x: 45, y: 30), CGPoint(x: 35, y: 23), 3.2),
            (CGPoint(x: 64, y: 42), CGPoint(x: 80, y: 30), 3.4),
            (CGPoint(x: 64, y: 42), CGPoint(x: 83, y: 46), 3.2),
            (CGPoint(x: 67, y: 56), CGPoint(x: 82, y: 58), 3.0),
        ] {
            let midpoint = CGPoint(x: (root.x + tip.x) / 2, y: (root.y + tip.y) / 2)
            drawing.details.move(to: root)
            drawing.details.addQuadCurve(to: tip, control: CGPoint(x: midpoint.x, y: midpoint.y - width))
            drawing.details.addQuadCurve(to: root, control: CGPoint(x: midpoint.x, y: midpoint.y + width))
            drawing.details.closeSubpath()
        }
        drawing.softLines.move(to: CGPoint(x: 30, y: 75))
        drawing.softLines.addQuadCurve(to: CGPoint(x: 83, y: 75), control: CGPoint(x: 57, y: 73))
        return drawing
    }()

    private static let mountain: HeritageDrawing = {
        var drawing = HeritageDrawing()
        drawing.lines.move(to: CGPoint(x: 12, y: 59))
        for point in [
            CGPoint(x: 27, y: 45), CGPoint(x: 35, y: 48), CGPoint(x: 48, y: 28),
            CGPoint(x: 57, y: 38), CGPoint(x: 62, y: 37), CGPoint(x: 81, y: 57),
        ] { drawing.lines.addLine(to: point) }
        drawing.softLines.move(to: CGPoint(x: 64, y: 43))
        drawing.softLines.addLine(to: CGPoint(x: 76, y: 35))
        drawing.softLines.addLine(to: CGPoint(x: 100, y: 59))
        drawing.softLines.move(to: CGPoint(x: 22, y: 67))
        drawing.softLines.addQuadCurve(to: CGPoint(x: 91, y: 67), control: CGPoint(x: 56, y: 64))
        drawing.softLines.move(to: CGPoint(x: 42, y: 74))
        drawing.softLines.addLine(to: CGPoint(x: 74, y: 74))
        drawing.wash = drawing.lines
        drawing.wash.addLine(to: CGPoint(x: 92, y: 63))
        drawing.wash.addLine(to: CGPoint(x: 12, y: 63))
        drawing.wash.closeSubpath()
        return drawing
    }()

    private static let scroll: HeritageDrawing = {
        var drawing = HeritageDrawing()
        drawing.wash.addRoundedRect(
            in: CGRect(x: 29, y: 28, width: 59, height: 31), cornerSize: CGSize(width: 5, height: 5))
        drawing.lines.move(to: CGPoint(x: 33, y: 27))
        drawing.lines.addLine(to: CGPoint(x: 81, y: 27))
        drawing.lines.addQuadCurve(to: CGPoint(x: 89, y: 43), control: CGPoint(x: 91, y: 27))
        drawing.lines.addQuadCurve(to: CGPoint(x: 81, y: 60), control: CGPoint(x: 91, y: 60))
        drawing.lines.addLine(to: CGPoint(x: 33, y: 60))
        drawing.lines.addEllipse(in: CGRect(x: 23, y: 27, width: 18, height: 33))
        drawing.softLines.addEllipse(in: CGRect(x: 28, y: 33, width: 8, height: 21))
        drawing.lines.move(to: CGPoint(x: 59, y: 28))
        drawing.lines.addQuadCurve(to: CGPoint(x: 59, y: 60), control: CGPoint(x: 62, y: 44))
        drawing.softLines.move(to: CGPoint(x: 57, y: 44))
        drawing.softLines.addQuadCurve(to: CGPoint(x: 68, y: 38), control: CGPoint(x: 65, y: 44))
        drawing.softLines.move(to: CGPoint(x: 61, y: 44))
        drawing.softLines.addQuadCurve(to: CGPoint(x: 68, y: 50), control: CGPoint(x: 65, y: 44))
        drawing.softLines.move(to: CGPoint(x: 24, y: 70))
        drawing.softLines.addLine(to: CGPoint(x: 89, y: 70))
        return drawing
    }()

    private static let folio: HeritageDrawing = {
        var drawing = HeritageDrawing()
        drawing.wash.addRoundedRect(
            in: CGRect(x: 33, y: 20, width: 44, height: 49), cornerSize: CGSize(width: 3, height: 3))
        drawing.lines.addRoundedRect(
            in: CGRect(x: 33, y: 20, width: 44, height: 49), cornerSize: CGSize(width: 3, height: 3))
        drawing.softLines.move(to: CGPoint(x: 38, y: 73))
        drawing.softLines.addLine(to: CGPoint(x: 81, y: 73))
        drawing.softLines.addLine(to: CGPoint(x: 81, y: 26))
        drawing.lines.move(to: CGPoint(x: 41, y: 21))
        drawing.lines.addLine(to: CGPoint(x: 41, y: 68))
        for y in [32.0, 44, 56] {
            drawing.softLines.move(to: CGPoint(x: 30, y: y))
            drawing.softLines.addQuadCurve(to: CGPoint(x: 37, y: y), control: CGPoint(x: 33, y: y - 3))
        }
        drawing.lines.move(to: CGPoint(x: 60, y: 20))
        drawing.lines.addLine(to: CGPoint(x: 60, y: 42))
        drawing.lines.addLine(to: CGPoint(x: 65, y: 38))
        drawing.lines.addLine(to: CGPoint(x: 70, y: 42))
        drawing.lines.addLine(to: CGPoint(x: 70, y: 20))
        return drawing
    }()
}
