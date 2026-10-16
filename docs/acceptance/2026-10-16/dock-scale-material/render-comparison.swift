import AppKit
import CoreText
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let width = 1200
let height = 660
let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.translateBy(x: 0, y: CGFloat(height))
context.scaleBy(x: 1, y: -1)
context.setFillColor(CGColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat = 18) {
    let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: value, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1),
        ]))
    context.saveGState()
    context.translateBy(x: x, y: y + size)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = .zero
    CTLineDraw(line, context)
    context.restoreGState()
}
text("Static icon canvas / same 128 px slot", x: 44, y: 26, size: 26)
text("Asset comparison, not a Dock screenshot", x: 44, y: 65, size: 16)
let items: [(String, String)] = [
    ("WeGit before / 100%", root.appending(path: "branding/wegit-v2/revisions/before-dock-material-2026-10-16/WeGit.icns").path),
    ("WeGit light / 80.5%", root.appending(path: "branding/wegit-v2/WeGit.icns").path),
    ("WeGit dark / 80.5%", root.appending(path: "branding/wegit-v2/WeGit-dark.icns").path),
    ("Finder / 80.5%", "/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns"),
    ("Notes / 80.5%", "/System/Applications/Notes.app/Contents/Resources/AppIcon.icns"),
    ("Terminal / 80.5%", "/System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.icns"),
]
for (i, item) in items.enumerated() {
    let x = CGFloat(100 + (i % 3) * 390)
    let y = CGFloat(125 + (i / 3) * 260)
    let image = NSImage(contentsOfFile: item.1)!
    let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    context.saveGState()
    context.translateBy(x: x, y: y + 128)
    context.scaleBy(x: 1, y: -1)
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 128, height: 128))
    context.restoreGState()
    text(item.0, x: x - 36, y: y + 154)
}
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
