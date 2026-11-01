import AppKit
import Foundation

// Normalize only the compatibility bitmap canvas. Modern .icon layers are unmasked.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let source = NSBitmapImageRep(data: try Data(contentsOf: input))!
let width = source.pixelsWide
let height = source.pixelsHigh
let xs = (0..<width).filter { source.colorAt(x: $0, y: height / 2)!.alphaComponent > 0.5 }
let ys = (0..<height).filter { source.colorAt(x: width / 2, y: $0)!.alphaComponent > 0.5 }
let extentX = CGFloat(xs.last! - xs.first! + 1)
let extentY = CGFloat(ys.last! - ys.first! + 1)
let factor = (CGFloat(width) * (824.0 / 1024.0)) / max(extentX, extentY)
let midpoint = CGPoint(x: CGFloat(xs.first! + xs.last! + 1) / 2, y: CGFloat(ys.first! + ys.last! + 1) / 2)
let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.interpolationQuality = .high
context.draw(
    source.cgImage!,
    in: CGRect(
        x: CGFloat(width) / 2 - midpoint.x * factor,
        y: CGFloat(height) / 2 - (CGFloat(height) - midpoint.y) * factor,
        width: CGFloat(width) * factor, height: CGFloat(height) * factor))
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("Normalized \(input.lastPathComponent): scale \(factor)")
