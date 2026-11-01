import AppKit
import Foundation
for path in CommandLine.arguments.dropFirst() {
 guard let image=NSImage(contentsOfFile:path),let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else {continue}
 let bmp=NSBitmapImageRep(cgImage:cg)
 var minX=bmp.pixelsWide,minY=bmp.pixelsHigh,maxX=0,maxY=0
 for y in 0..<bmp.pixelsHigh {for x in 0..<bmp.pixelsWide {if bmp.colorAt(x:x,y:y)!.alphaComponent>0.5 {minX=min(minX,x);minY=min(minY,y);maxX=max(maxX,x);maxY=max(maxY,y)}}}
 print(path, bmp.pixelsWide,bmp.pixelsHigh, "opaque>0.5",[minX,minY,maxX,maxY])
}
