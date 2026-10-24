import SwiftUI

/// The complete symbol rotates once per cycle at a constant speed.
struct YinYangLoadingMotion {
    static let duration: TimeInterval = 2.8

    let rotation: Double

    init(phase: Double) {
        let phase = phase - floor(phase)
        rotation = phase * .pi * 2
    }
}

/// Complementary closed silhouettes meet exactly along the same S curve.
struct YinYangLoadingGlyph: View {
    var phase: Double
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas { context, size in
            let motion = YinYangLoadingMotion(phase: phase)
            let side = min(size.width, size.height)
            let diameter = side * 0.74
            let radius = diameter / 2
            let dark = Color(white: 0.08)
            let light = Color(white: 0.98)
            let edge = colorScheme == .dark ? Color.white : Color.black
            let edgeOpacity = contrast == .increased ? 0.8 : 0.32
            let edgeWidth: CGFloat = contrast == .increased ? 0.9 : 0.5
            let eyeDiameter = max(1.2, diameter * 0.17)
            let eye = Path(
                ellipseIn: CGRect(
                    x: -eyeDiameter / 2, y: -radius / 2 - eyeDiameter / 2,
                    width: eyeDiameter, height: eyeDiameter))
            let fish = Self.fish(radius: radius)

            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: .radians(motion.rotation))
            for index in 0..<2 {
                var fishContext = context
                fishContext.rotate(by: .radians(Double(index) * .pi))
                fishContext.fill(fish, with: .color(index == 0 ? dark : light))
                fishContext.stroke(fish, with: .color(edge.opacity(edgeOpacity)), lineWidth: edgeWidth)
                fishContext.fill(eye, with: .color(index == 0 ? light : dark))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func fish(radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -radius))
        path.addArc(
            center: .zero, radius: radius,
            startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addArc(
            center: CGPoint(x: 0, y: radius / 2), radius: radius / 2,
            startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
        path.addArc(
            center: CGPoint(x: 0, y: -radius / 2), radius: radius / 2,
            startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: false)
        path.closeSubpath()
        return path
    }
}
