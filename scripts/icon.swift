import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let n = 1024
let ctx = CGContext(data:nil,width:n,height:n,bitsPerComponent:8,bytesPerRow:n*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(red:0.035,green:0.035,blue:0.035,alpha:1))
ctx.fill(CGRect(x:0,y:0,width:n,height:n))
for row in 0..<3 {
 for col in 0..<3 {
  let rect = CGRect(x:166+col*236,y:166+row*236,width:220,height:220)
  let path = CGPath(roundedRect:rect,cornerWidth:42,cornerHeight:42,transform:nil)
  ctx.setFillColor(CGColor(red:0.17,green:0.17,blue:0.17,alpha:1));ctx.addPath(path);ctx.fillPath()
  let inset = rect.insetBy(dx:13,dy:13)
  let face = CGPath(roundedRect:inset,cornerWidth:32,cornerHeight:32,transform:nil)
  let color = row == 1 && col == 1 ? CGColor(red:0.96,green:0.82,blue:0.12,alpha:1) : CGColor(red:0.065,green:0.065,blue:0.065,alpha:1)
  ctx.setFillColor(color);ctx.addPath(face);ctx.fillPath()
 }
}
let url = URL(fileURLWithPath:"Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let out = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(out,ctx.makeImage()!,nil)
guard CGImageDestinationFinalize(out) else { fatalError("Icon generation failed") }
