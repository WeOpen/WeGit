import CoreGraphics

/// Matches branding/wegit-v2/source/render-brand.swift, including its optical small-size variant.
enum BrandGeometry {
    static func path(in rect: CGRect, optical: Bool = false) -> CGPath {
        var transform = CGAffineTransform(
            a: rect.width / 1024, b: 0, c: 0, d: rect.height / 1024,
            tx: rect.minX, ty: rect.minY)
        return makeMark(micro: optical).copy(using: &transform)!
    }

    private static func makeMark(micro: Bool = false) -> CGPath {
        let main = CGMutablePath()
        main.move(to: CGPoint(x: 230, y: 360))
        main.addLine(to: CGPoint(x: 330, y: 600))
        main.addCurve(
            to: CGPoint(x: 430, y: 600), control1: CGPoint(x: 350, y: 660), control2: CGPoint(x: 410, y: 660))
        main.addLine(to: CGPoint(x: 452, y: 524))
        main.addCurve(
            to: CGPoint(x: 572, y: 524), control1: CGPoint(x: 482, y: 466), control2: CGPoint(x: 542, y: 466))
        main.addLine(to: CGPoint(x: 606, y: 600))
        main.addCurve(
            to: CGPoint(x: 706, y: 600), control1: CGPoint(x: 626, y: 660), control2: CGPoint(x: 686, y: 660))
        main.addLine(to: CGPoint(x: 800, y: 326))
        let fork = CGMutablePath()
        fork.move(to: CGPoint(x: 756, y: 450))
        fork.addCurve(
            to: CGPoint(x: 900, y: 370), control1: CGPoint(x: 794, y: 424), control2: CGPoint(x: 858, y: 391))
        let mark = CGMutablePath()
        mark.addPath(
            main.copy(strokingWithWidth: micro ? 86 : 74, lineCap: .round, lineJoin: .round, miterLimit: 2))
        mark.addPath(
            fork.copy(strokingWithWidth: micro ? 62 : 48, lineCap: .round, lineJoin: .round, miterLimit: 2))
        let radius: CGFloat = micro ? 34 : 30
        // Match the stroke outlines' winding so overlap stays solid in compound SVGs.
        let node = CGMutablePath()
        node.addArc(
            center: CGPoint(x: 900, y: 370), radius: radius,
            startAngle: 0, endAngle: -.pi * 2, clockwise: true)
        node.closeSubpath()
        mark.addPath(node)
        var transform = CGAffineTransform(a: 0.93, b: 0, c: 0, d: 0.93, tx: -10, ty: 60)
        return mark.copy(using: &transform)!
    }
}
