import AppKit
import Foundation

// Icon Composer exports the tile edge-to-edge. Legacy ICNS/applicationIconImage
// needs the macOS canvas inset; applying this to the .icon document would inset twice.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let pixels = Int(CommandLine.arguments[3])!
let source = NSBitmapImageRep(data: try Data(contentsOf: input))!.cgImage!
let context = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
    bytesPerRow: pixels * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Finder, Notes and Terminal have a 206 px tile in a 256 px static canvas.
let extent = (Double(pixels) * 824 / 1024).rounded()
let inset = (Double(pixels) - extent) / 2
context.interpolationQuality = .high
context.draw(source, in: CGRect(x: inset, y: inset, width: extent, height: extent))
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
