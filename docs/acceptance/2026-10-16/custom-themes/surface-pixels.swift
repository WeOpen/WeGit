import AppKit
import Foundation
let base=URL(fileURLWithPath:CommandLine.arguments[1])
let groups:[String:[String:(Double,Double)]] = [
 "workspace-light":["toolbar":(0.40,0.035),"canvas":(0.65,0.72),"inspector":(0.985,0.72),"commitStrip":(0.52,0.96)],
 "workspace-dark":["toolbar":(0.40,0.035),"canvas":(0.65,0.72),"inspector":(0.985,0.72),"commitStrip":(0.52,0.96)],
 "settings-light":["titlebar":(0.80,0.025),"canvas":(0.98,0.60)],
 "settings-dark":["titlebar":(0.80,0.025),"canvas":(0.98,0.60)],
 "split-inspector-custom":["toolbar":(0.40,0.035),"diffHeader":(0.65,0.16),"inspector":(0.985,0.72),"canvas":(0.65,0.72),"sidebar":(0.08,0.75)]
]
var out:[String:Any]=[:]
for (name,points) in groups {
 let bmp=NSBitmapImageRep(data:try Data(contentsOf:base.appending(path:name+".png")))!
 var colors:[String:Any]=[:]
 for (label,(x,y)) in points {
  let px=Int(x*Double(bmp.pixelsWide)), py=Int(y*Double(bmp.pixelsHigh))
  let c=bmp.colorAt(x:px,y:py)!.usingColorSpace(.sRGB)!
  colors[label] = ["pixel":[px,py], "rgb":[c.redComponent,c.greenComponent,c.blueComponent].map{Int(($0*255).rounded())}]
 }
 out[name]=["size":[bmp.pixelsWide,bmp.pixelsHigh],"samples":colors]
}
try JSONSerialization.data(withJSONObject:out,options:[.prettyPrinted,.sortedKeys]).write(to:base.appending(path:"surface-pixels.json"))
