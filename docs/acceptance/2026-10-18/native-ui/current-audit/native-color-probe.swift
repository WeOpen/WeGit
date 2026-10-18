import AppKit
import Foundation

@main struct AuditNativeColors {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func rgba(_ c: NSColor) -> [Double] {
            let s = c.usingColorSpace(.sRGB)!
            return [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent].map(Double.init)
        }
        func over(_ c: [Double], _ b: [Double]) -> [Double] {
            (0..<3).map { c[$0] * c[3] + b[$0] * (1 - c[3]) } + [1]
        }
        func luminance(_ c: [Double]) -> Double {
            let v = c.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return zip(v, [0.2126, 0.7152, 0.0722]).map(*).reduce(0, +)
        }
        var rows: [[String: Any]] = []
        for dark in [false, true] {
            let colors = AppColors(dark: dark)
            let canvas = rgba(colors.resolvedNSColor(.canvas))
            let added = over(rgba(colors.resolvedNSColor(.diffAdded)), canvas)
            let removed = over(rgba(colors.resolvedNSColor(.diffRemoved)), canvas)
            var blue = NSColor.systemBlue
            colors.appearance.performAsCurrentDrawingAppearance { blue = blue.usingColorSpace(.sRGB)! }
            let pairs: [(String, [Double], [Double])] = [
                ("text/canvas", rgba(colors.resolvedNSColor(.text)), canvas),
                ("secondary/canvas", rgba(colors.resolvedNSColor(.secondaryText)), canvas),
                ("secondary/added", rgba(colors.resolvedNSColor(.secondaryText)), added),
                ("positive/added", rgba(colors.resolvedNSColor(.positive)), added),
                ("negative/removed", rgba(colors.resolvedNSColor(.negative)), removed),
                ("selected-sidebar", [1, 1, 1, 1], rgba(blue)),
            ]
            for (name, foreground, background) in pairs {
                let rendered = over(foreground, background)
                let a = luminance(rendered), b = luminance(background)
                rows.append(["theme": dark ? "dark" : "light", "pair": name,
                             "foregroundRGBA": foreground, "backgroundRGBA": background,
                             "compositedForegroundRGBA": rendered,
                             "contrast": (max(a, b) + 0.05) / (min(a, b) + 0.05)])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
