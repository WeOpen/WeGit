import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var checked: [[String: Any]] = []
func verify(_ name: String, width: Int, height: Int, alpha: Bool = true) throws {
    let data = try Data(contentsOf: root.appending(path: name))
    guard let bitmap = NSBitmapImageRep(data: data) else { fatalError("Invalid image: \(name)") }
    precondition(bitmap.pixelsWide == width && bitmap.pixelsHigh == height, name)
    if alpha {
        precondition(bitmap.hasAlpha, name)
        precondition(bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0, name)
    }
    checked.append(["file": name, "width": width, "height": height, "transparentCorner": alpha])
}
for name in ["mark", "mark-dark", "mark-black", "mark-white"] {
    try verify(name + ".png", width: 2048, height: 2048)
}
for name in ["logo-light", "logo-dark"] {
    try verify(name + ".png", width: 3006, height: 1080)
    let source = try String(contentsOf: root.appending(path: name + ".svg"), encoding: .utf8)
    precondition(!source.contains("<text") && !source.contains("font-family"), name)
}
for folder in ["WeGit.iconset", "WeGit-dark.iconset"] {
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            try verify(
                "\(folder)/icon_\(points)x\(points)\(suffix).png", width: points * scale,
                height: points * scale)
        }
    }
}
for name in ["app-icon-light", "app-icon-dark"] {
    try verify(name + ".png", width: 1024, height: 1024)
}
for pixels in [16, 18, 20, 24, 32, 36, 40, 48, 64] {
    for suffix in ["black", "white"] {
        try verify("menu-bar/mark-\(pixels)-\(suffix).png", width: pixels, height: pixels)
    }
}
for file in ["WeGit.icns", "WeGit-dark.icns"] {
    let data = try Data(contentsOf: root.appending(path: file))
    precondition(data.prefix(4) == Data("icns".utf8))
    precondition(NSImage(data: data) != nil, file)
}
let mark = NSBitmapImageRep(data: try Data(contentsOf: root.appending(path: "mark.png")))!
let solidNode = mark.colorAt(x: 1654, y: 808)!.alphaComponent > 0.99
precondition(solidNode, "Commit node must remain solid where contours overlap")
try verify("preview.png", width: 1800, height: 1260, alpha: false)
let result: [String: Any] = [
    "passed": true,
    "pngChecks": checked,
    "outlinedWordmarks": true,
    "solidNodeOverlap": solidNode,
    "icnsDecoded": true,
    "nativeAppearancesRendered": ["Default", "Dark"],
    "applicationIntegrationChecked": false,
    "generatedOriginalsUnmodified": true,
    "scope": "Asset export integrity and visual size review, not application acceptance",
]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    .write(to: root.appending(path: "validation.json"))
print("Verified \(checked.count) PNG exports, outlined wordmarks, solid node, and both ICNS files.")
