import CoreGraphics
import Foundation

// Optical cleanup of the independent R5 generated silhouette. Real circles and
// continuous curves remove raster stair steps; the two endpoints and open stem
// keep the imagegen master's measured positions. The verified Ku path is untouched.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let trunk = CGMutablePath()
trunk.move(to: CGPoint(x: 82, y: 590))
trunk.addLine(to: CGPoint(x: 82, y: 462))
trunk.addCurve(to: CGPoint(x: 118, y: 376), control1: CGPoint(x: 82, y: 423), control2: CGPoint(x: 90, y: 405))
trunk.addLine(to: CGPoint(x: 325, y: 140))
let arm = CGMutablePath()
arm.move(to: CGPoint(x: 162, y: 323))
arm.addLine(to: CGPoint(x: 402, y: 323))
var branch = trunk.copy(strokingWithWidth: 52, lineCap: .butt, lineJoin: .round, miterLimit: 2)
    .union(arm.copy(strokingWithWidth: 52, lineCap: .round, lineJoin: .round, miterLimit: 2))
for point in [CGPoint(x: 325, y: 140), CGPoint(x: 402, y: 323)] {
    branch = branch.union(CGPath(ellipseIn: CGRect(x: point.x-72, y: point.y-72, width: 144, height: 144), transform: nil))
}
for point in [CGPoint(x: 325, y: 140), CGPoint(x: 402, y: 323)] {
    branch = branch.subtracting(CGPath(ellipseIn: CGRect(x: point.x-30, y: point.y-30, width: 60, height: 60), transform: nil))
}
branch = branch.intersection(CGPath(rect: CGRect(x: 0, y: 0, width: 566, height: 566), transform: nil))
func write(_ path: CGPath, name: String) throws {
    var result = "", contours = 0
    path.flattened(threshold: 0.05).applyWithBlock { pointer in
        let element = pointer.pointee
        switch element.type {
        case .moveToPoint, .addLineToPoint:
            if element.type == .moveToPoint { contours += 1 }
            result += (element.type == .moveToPoint ? "M" : "L") + String(format: "%.3f %.3f", element.points[0].x, element.points[0].y)
        case .closeSubpath: result += "Z "
        default: fatalError("Expected flattened geometry")
        }
    }
    let value: [String: Any] = ["width": 566, "height": 566, "contourCount": contours, "d": result.trimmingCharacters(in: .whitespaces)]
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent(name + "-contours.json"))
    print(name, contours)
}
try write(branch, name: "git")
try write(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 566, height: 566), cornerWidth: 108, cornerHeight: 108, transform: nil), name: "plate")
