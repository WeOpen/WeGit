import Foundation
import Vision
import AppKit
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let request = VNDetectContoursRequest()
request.contrastAdjustment = 1.0
request.detectsDarkOnLight = false
request.maximumImageDimension = 2048
let handler = VNImageRequestHandler(url: input, options: [:])
try handler.perform([request])
guard let result = request.results?.first, let rep=NSBitmapImageRep(data: try Data(contentsOf: input)) else { fatalError("No contours") }
let width=Double(rep.pixelsWide), height=Double(rep.pixelsHigh)
var paths:[String]=[]
func walk(_ contour: VNContour) throws {
    let simplified = try contour.polygonApproximation(epsilon: 0.0005)
    var d=""
    simplified.normalizedPath.applyWithBlock { pointer in
        let e=pointer.pointee
        func p(_ i:Int)->String {String(format:"%.3f %.3f",Double(e.points[i].x)*width,(1-Double(e.points[i].y))*height)}
        switch e.type {
        case .moveToPoint:d += "M"+p(0)
        case .addLineToPoint:d += "L"+p(0)
        case .addQuadCurveToPoint:d += "Q"+p(0)+" "+p(1)
        case .addCurveToPoint:d += "C"+p(0)+" "+p(1)+" "+p(2)
        case .closeSubpath:d += "Z"
        @unknown default:break
        }
    }
    paths.append(d)
    for child in contour.childContours {try walk(child)}
}
for c in result.topLevelContours {try walk(c)}
let payload:[String:Any] = ["width":width,"height":height,"contourCount":paths.count,"d":paths.joined(separator:" ")]
try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]).write(to:output)
print("\(input.lastPathComponent): \(paths.count) editable contours")
