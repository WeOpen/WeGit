import AppKit
import CoreText
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let width = 1800
let height = 1260
let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.translateBy(x: 0, y: CGFloat(height))
context.scaleBy(x: 1, y: -1)
func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func image(_ name: String, rect: CGRect) {
    let bitmap = NSBitmapImageRep(data: try! Data(contentsOf: root.appending(path: name)))!
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.interpolationQuality = .high
    context.draw(bitmap.cgImage!, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
}
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, ink: UInt32) {
    let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(
            string: value,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(ink),
            ]))
    context.saveGState()
    context.translateBy(x: x, y: y + size)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
}
context.setFillColor(color(0xF4F6F9))
context.fill(CGRect(x: 0, y: 0, width: 900, height: height))
context.setFillColor(color(0x101319))
context.fill(CGRect(x: 900, y: 0, width: 900, height: height))
text("WeGit / Identity 02", x: 64, y: 48, size: 24, ink: 0x717783)
text("WeGit / Identity 02", x: 964, y: 48, size: 24, ink: 0x8D97A8)
let logoLight = NSBitmapImageRep(data: try Data(contentsOf: root.appending(path: "logo-light.png")))!
let logoHeight = 720 * CGFloat(logoLight.pixelsHigh) / CGFloat(logoLight.pixelsWide)
image("logo-light.png", rect: CGRect(x: 80, y: 115, width: 720, height: logoHeight))
image("logo-dark.png", rect: CGRect(x: 980, y: 115, width: 720, height: logoHeight))
image("app-icon-light.png", rect: CGRect(x: 225, y: 440, width: 450, height: 450))
image("app-icon-dark.png", rect: CGRect(x: 1125, y: 440, width: 450, height: 450))
for (offset, folder, ink) in [
    (CGFloat(0), "WeGit.iconset", UInt32(0x717783)), (CGFloat(900), "WeGit-dark.iconset", UInt32(0x8D97A8)),
] {
    text(offset == 0 ? "Default" : "Dark", x: offset + 64, y: 370, size: 21, ink: ink)
    text("16 / 32 / 64 / 128 px", x: offset + 64, y: 950, size: 21, ink: ink)
    let samples: [(String, CGFloat, CGFloat)] = [
        ("icon_16x16.png", 16, 200), ("icon_32x32.png", 32, 300), ("icon_32x32@2x.png", 64, 410),
        ("icon_128x128.png", 128, 540),
    ]
    for (file, size, x) in samples {
        image(folder + "/" + file, rect: CGRect(x: offset + x, y: 1100 - size / 2, width: size, height: size))
    }
}
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: root.appending(path: "preview.png"))
print("Created native light/dark identity preview with true-size Dock samples.")
