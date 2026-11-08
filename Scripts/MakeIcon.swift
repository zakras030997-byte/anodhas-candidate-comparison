import AppKit
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size*scale
        let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        rep.size = NSSize(width:size,height:size)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
        let transform = NSAffineTransform(); transform.scale(by:CGFloat(size)/1024); transform.concat()
        let background = NSBezierPath(roundedRect:NSRect(x:60,y:60,width:904,height:904),xRadius:205,yRadius:205)
        NSColor(srgbRed:0.11,green:0.12,blue:0.14,alpha:1).setFill(); background.fill()
        for (i,x) in [CGFloat(190),CGFloat(550)].enumerated() {
            NSColor(srgbRed:i==0 ? 1:0.65,green:i==0 ? 0.70:0.79,blue:i==0 ? 0.28:0.93,alpha:1).setFill()
            NSBezierPath(roundedRect:NSRect(x:x,y:240,width:285,height:525),xRadius:42,yRadius:42).fill()
            NSColor(srgbRed:0.13,green:0.15,blue:0.18,alpha:1).setFill()
            NSBezierPath(ovalIn:NSRect(x:x+91,y:570,width:104,height:104)).fill()
            NSBezierPath(roundedRect:NSRect(x:x+52,y:435,width:181,height:110),xRadius:45,yRadius:45).fill()
            for y in [CGFloat(365),CGFloat(305)] { NSBezierPath(roundedRect:NSRect(x:x+50,y:y,width:185,height:18),xRadius:9,yRadius:9).fill() }
        }
        NSGraphicsContext.restoreGraphicsState()
        let name="icon_\(size)x\(size)"+(scale==2 ? "@2x" : "")+".png"
        try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output).appendingPathComponent(name))
    }
}
