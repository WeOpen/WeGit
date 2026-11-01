import AppKit
import CoreText
import Foundation

// Reproducible geometric artwork inspired by the imagegen exploration.
// Draws new vector geometry; the generated raster images remain untouched.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fontURL = directory.appending(path: "source/InterVariable.ttf")
var fontError: Unmanaged<CFError>?
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &fontError),
    let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
    let descriptor = descriptors.first
else { fatalError("Could not register the project-local Inter font") }
let weightDescriptor = CTFontDescriptorCreateCopyWithAttributes(
    descriptor,
    [
        kCTFontVariationAttribute: [NSNumber(value: 0x7767_6874): NSNumber(value: 600)]
    ] as CFDictionary)
let font = CTFontCreateWithFontDescriptor(weightDescriptor, 292, nil)
let line = CTLineCreateWithAttributedString(
    NSAttributedString(
        string: "WeGit",
        attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): -3,
        ]))
let word = CGMutablePath()
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
    for (glyph, point) in zip(glyphs, positions) {
        if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            word.addPath(path, transform: CGAffineTransform(translationX: point.x, y: point.y))
        }
    }
}

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let blue: UInt32 = 0x2B67D8
let darkBlue: UInt32 = 0x79AAFF
let branch = CGMutablePath()
branch.move(to: CGPoint(x: 262, y: 418))
branch.addLine(to: CGPoint(x: 371, y: 690))
branch.addQuadCurve(to: CGPoint(x: 397, y: 693), control: CGPoint(x: 383, y: 722))
branch.addLine(to: CGPoint(x: 512, y: 492))
branch.addLine(to: CGPoint(x: 627, y: 693))
branch.addQuadCurve(to: CGPoint(x: 653, y: 690), control: CGPoint(x: 641, y: 722))
branch.addLine(to: CGPoint(x: 762, y: 418))
branch.move(to: CGPoint(x: 512, y: 492))
branch.addLine(to: CGPoint(x: 512, y: 288))
let nodes: [(CGFloat, CGFloat, CGFloat)] = [(262, 418, 68), (762, 418, 68), (512, 492, 64), (512, 288, 68)]
let branchD = "M262 418L371 690Q383 722 397 693L512 492L627 693Q641 722 653 690L762 418M512 492V288"

func markSVG(fill: String) -> String {
    "<path d=\"\(branchD)\" fill=\"none\" stroke=\"\(fill)\" stroke-width=\"64\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        + nodes.map { "<circle cx=\"\($0.0)\" cy=\"\($0.1)\" r=\"\($0.2)\" fill=\"\(fill)\"/>" }.joined()
}
func pathData(_ path: CGPath) -> String {
    var result = ""
    path.applyWithBlock { pointer in
        let e = pointer.pointee
        func p(_ i: Int) -> String { String(format: "%.3f %.3f", e.points[i].x, e.points[i].y) }
        switch e.type {
        case .moveToPoint: result += "M" + p(0)
        case .addLineToPoint: result += "L" + p(0)
        case .addQuadCurveToPoint: result += "Q" + p(0) + " " + p(1)
        case .addCurveToPoint: result += "C" + p(0) + " " + p(1) + " " + p(2)
        case .closeSubpath: result += "Z"
        @unknown default: break
        }
    }
    return result
}
func saveSVG(_ name: String, width: Int, height: Int, content: String) throws {
    let svg =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\" role=\"img\" aria-label=\"WeGit\"><title>WeGit</title>\(content)</svg>\n"
    try svg.write(to: directory.appending(path: name + ".svg"), atomically: true, encoding: .utf8)
}
func drawMark(_ context: CGContext, fill: UInt32 = blue) {
    context.setStrokeColor(color(fill))
    context.setFillColor(color(fill))
    context.setLineWidth(64)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(branch)
    context.strokePath()
    context.fill(CGRect(x: 480, y: 288, width: 64, height: 204))
    for (x, y, radius) in nodes {
        context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }
}
func savePNG(_ name: String, width: Int, height: Int, draw: (CGContext) -> Void) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    draw(context)
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    try image.representation(using: .png, properties: [:])!.write(
        to: directory.appending(path: name + ".png"))
}

let tile = CGPath(
    roundedRect: CGRect(x: 96, y: 96, width: 832, height: 832),
    cornerWidth: 178, cornerHeight: 178, transform: nil)
let iconSVG =
    "<defs><linearGradient id=\"tile\" x2=\"0\" y2=\"1\"><stop stop-color=\"#FFFFFF\"/><stop offset=\"1\" stop-color=\"#EEF1F6\"/></linearGradient></defs><rect x=\"96\" y=\"96\" width=\"832\" height=\"832\" rx=\"178\" fill=\"url(#tile)\" stroke=\"#DCE1E9\" stroke-width=\"1.5\"/>"
try saveSVG("app-icon", width: 1024, height: 1024, content: iconSVG + markSVG(fill: "#2B67D8"))
let darkIconSVG =
    "<defs><linearGradient id=\"tile\" x2=\"0\" y2=\"1\"><stop stop-color=\"#1B2435\"/><stop offset=\"1\" stop-color=\"#101722\"/></linearGradient></defs><rect x=\"96\" y=\"96\" width=\"832\" height=\"832\" rx=\"178\" fill=\"url(#tile)\" stroke=\"#334156\" stroke-width=\"1.5\"/>"
try saveSVG("app-icon-dark", width: 1024, height: 1024, content: darkIconSVG + markSVG(fill: "#79AAFF"))
// Icon Composer supplies the enclosure; expand the mark to match the legacy tile's content area.
try saveSVG(
    "icon-mark", width: 1024, height: 1024,
    content: "<g transform=\"translate(512 512) scale(1.2307692308) translate(-512 -512)\">"
        + markSVG(fill: "#2B67D8") + "</g>")
func drawIcon(_ context: CGContext, dark: Bool = false) {
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: (dark ? [color(0x1B2435), color(0x101722)] : [color(0xFFFFFF), color(0xEEF1F6)]) as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 512, y: 96), end: CGPoint(x: 512, y: 928), options: [])
    context.restoreGState()
    context.setStrokeColor(color(dark ? 0x334156 : 0xDCE1E9))
    context.setLineWidth(1.5)
    context.addPath(tile)
    context.strokePath()
    drawMark(context, fill: dark ? darkBlue : blue)
}
try savePNG("app-icon", width: 1024, height: 1024) { drawIcon($0) }
try savePNG("app-icon-dark", width: 1024, height: 1024) { drawIcon($0, dark: true) }
let iconEntries = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
for (points, scale) in iconEntries {
    let filename = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "")
    let pixels = points * scale
    for (folder, dark) in [("WeGit.iconset", false), ("WeGit-dark.iconset", true)] {
        try FileManager.default.createDirectory(
            at: directory.appending(path: folder), withIntermediateDirectories: true)
        try savePNG(folder + "/" + filename, width: pixels, height: pixels) { context in
            context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
            drawIcon(context, dark: dark)
        }
    }
}
try saveSVG("mark", width: 1024, height: 1024, content: markSVG(fill: "#2B67D8"))
try savePNG("mark", width: 1024, height: 1024) { drawMark($0) }

let bounds = word.boundingBoxOfPath
let width = Int(ceil(400 + bounds.width + 80))
let baseline = 225 + bounds.midY
var wordTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 400 - bounds.minX, ty: baseline)
let outlinedWord = word.copy(using: &wordTransform)!
for (name, ink, glyph) in [
    ("logo-light", UInt32(0x172033), blue), ("logo-dark", UInt32(0xEEF1F6), UInt32(0x79AAFF)),
] {
    let content =
        "<g transform=\"translate(0 32) scale(.4)\">\(markSVG(fill: String(format: "#%06X", glyph)))</g>"
        + "<path d=\"\(pathData(outlinedWord))\" fill=\"\(String(format: "#%06X", ink))\"/>"
    try saveSVG(name, width: width, height: 450, content: content)
    try savePNG(name, width: width, height: 450) { context in
        context.saveGState()
        context.translateBy(x: 0, y: 32)
        context.scaleBy(x: 0.4, y: 0.4)
        drawMark(context, fill: glyph)
        context.restoreGState()
        context.setFillColor(color(ink))
        context.addPath(outlinedWord)
        context.fillPath()
    }
}
print("WeGit assets rendered: icon 1024 × 1024; logos \(width) × 450; real alpha; outlined Inter wordmark.")
try savePNG("preview", width: 1440, height: 960) { context in
    context.setFillColor(color(0xF4F6FA))
    context.fill(CGRect(x: 0, y: 0, width: 1440, height: 480))
    context.setFillColor(color(0x172033))
    context.fill(CGRect(x: 0, y: 480, width: 1440, height: 480))
    for (top, ink, glyph) in [
        (CGFloat(0), UInt32(0x172033), blue), (CGFloat(480), UInt32(0xEEF1F6), UInt32(0x79AAFF)),
    ] {
        context.saveGState()
        context.translateBy(x: 58, y: top + 30)
        context.scaleBy(x: 0.37, y: 0.37)
        drawIcon(context, dark: top > 0)
        context.restoreGState()
        context.saveGState()
        context.translateBy(x: 455, y: top + 88)
        context.scaleBy(x: 0.69, y: 0.69)
        context.saveGState()
        context.translateBy(x: 0, y: 32)
        context.scaleBy(x: 0.4, y: 0.4)
        drawMark(context, fill: glyph)
        context.restoreGState()
        context.setFillColor(color(ink))
        context.addPath(outlinedWord)
        context.fillPath()
        context.restoreGState()
        var left: CGFloat = 145
        for size in [16, 32, 64] {
            context.saveGState()
            context.translateBy(x: left, y: top + 460 - CGFloat(size))
            context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
            drawIcon(context, dark: top > 0)
            context.restoreGState()
            left += CGFloat(size) + 24
        }
    }
}
