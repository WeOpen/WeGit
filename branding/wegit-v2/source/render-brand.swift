import AppKit
import CoreText
import Foundation

// Independent vector reconstruction of the imagegen direction. Generated PNGs
// are preserved unchanged; all production exports share this geometric master.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let blue: UInt32 = 0x2463DB
let paleBlue: UInt32 = 0x8CB5FF

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func makeMark(micro: Bool = false) -> CGPath {
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
let mark = makeMark()

func pathData(_ path: CGPath) -> String {
    var result = ""
    path.applyWithBlock { pointer in
        let element = pointer.pointee
        func point(_ index: Int) -> String {
            String(format: "%.3f %.3f", element.points[index].x, element.points[index].y)
        }
        switch element.type {
        case .moveToPoint: result += "M" + point(0)
        case .addLineToPoint: result += "L" + point(0)
        case .addQuadCurveToPoint: result += "Q" + point(0) + " " + point(1)
        case .addCurveToPoint: result += "C" + point(0) + " " + point(1) + " " + point(2)
        case .closeSubpath: result += "Z"
        @unknown default: break
        }
    }
    return result
}

func writeSVG(_ name: String, width: Int, height: Int, content: String) throws {
    let svg =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\" role=\"img\" aria-label=\"WeGit\"><title>WeGit</title>\(content)</svg>\n"
    try svg.write(to: directory.appending(path: name + ".svg"), atomically: true, encoding: .utf8)
}

func writePNG(_ name: String, width: Int, height: Int, draw: (CGContext) -> Void) throws {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)
    draw(context)
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    try image.representation(using: .png, properties: [:])!.write(
        to: directory.appending(path: name + ".png"))
}

for (name, fill) in [
    ("mark", blue), ("mark-dark", paleBlue), ("mark-black", UInt32(0x171B24)),
    ("mark-white", UInt32(0xF3F6FC)),
] {
    try writeSVG(
        name, width: 1024, height: 1024,
        content: "<path d=\"\(pathData(mark))\" fill=\"\(String(format: "#%06X", fill))\"/>")
    try writePNG(name, width: 2048, height: 2048) { context in
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(color(fill))
        context.addPath(mark)
        context.fillPath()
    }
}

let fontURL = directory.appending(path: "source/InterVariable.ttf")
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil),
    let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
    let descriptor = descriptors.first
else { fatalError("Missing project-local Inter font") }
let variable = CTFontDescriptorCreateCopyWithAttributes(
    descriptor,
    [kCTFontVariationAttribute: [NSNumber(value: 0x7767_6874): NSNumber(value: 510)]] as CFDictionary)
let font = CTFontCreateWithFontDescriptor(variable, 208, nil)
let line = CTLineCreateWithAttributedString(
    NSAttributedString(
        string: "WeGit",
        attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): -2.2,
        ]))
let word = CGMutablePath()
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
    for (glyph, position) in zip(glyphs, positions) {
        if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            word.addPath(path, transform: CGAffineTransform(translationX: position.x, y: position.y))
        }
    }
}
let bounds = word.boundingBoxOfPath
let logoWidth = Int(ceil(380 + bounds.width + 64))
var wordTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 380 - bounds.minX, ty: 180 + bounds.midY)
let outlinedWord = word.copy(using: &wordTransform)!
for (name, ink, glyph) in [("logo-light", UInt32(0x171B24), blue), ("logo-dark", UInt32(0xEEF3FC), paleBlue)]
{
    try writeSVG(
        name, width: logoWidth, height: 360,
        content:
            "<g transform=\"translate(0 -14.56) scale(.38)\"><path d=\"\(pathData(mark))\" fill=\"\(String(format: "#%06X", glyph))\"/></g><path d=\"\(pathData(outlinedWord))\" fill=\"\(String(format: "#%06X", ink))\"/>"
    )
    try writePNG(name, width: logoWidth * 3, height: 1080) { context in
        context.scaleBy(x: 3, y: 3)
        context.saveGState()
        context.translateBy(x: 0, y: -14.56)
        context.scaleBy(x: 0.38, y: 0.38)
        context.setFillColor(color(glyph))
        context.addPath(mark)
        context.fillPath()
        context.restoreGState()
        context.setFillColor(color(ink))
        context.addPath(outlinedWord)
        context.fillPath()
    }
}

let micro = makeMark(micro: true)
try FileManager.default.createDirectory(
    at: directory.appending(path: "menu-bar"), withIntermediateDirectories: true)
try writeSVG(
    "menu-bar/mark-template", width: 1024, height: 1024,
    content: "<path d=\"\(pathData(micro))\" fill=\"#000000\"/>")
for pixels in [16, 18, 20, 24, 32, 36, 40, 48, 64] {
    for (suffix, ink) in [("black", UInt32(0)), ("white", UInt32(0xFFFFFF))] {
        try writePNG("menu-bar/mark-\(pixels)-\(suffix)", width: pixels, height: pixels) { context in
            context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
            context.setFillColor(color(ink))
            context.addPath(micro)
            context.fillPath()
        }
    }
}

let iconDirectory = directory.appending(path: "AppIcon.icon/Assets")
try FileManager.default.createDirectory(at: iconDirectory, withIntermediateDirectories: true)
try writeSVG(
    "AppIcon.icon/Assets/mark", width: 1024, height: 1024,
    content: "<path d=\"\(pathData(mark))\" fill=\"#F3F6FC\"/>")
print("Rendered WeGit v2 vector masters, transparent PNGs, outlined wordmarks, and optical menu-bar assets.")
