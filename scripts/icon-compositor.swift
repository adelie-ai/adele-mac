import AppKit

// Compose the source artwork centered on a transparent square canvas.
// `fill` = fraction of the canvas the artwork's longest side occupies (Dock
// icons read best when the art nearly fills the frame but doesn't touch edges).
let args = CommandLine.arguments
guard args.count == 4, let side = Int(args[3]) else {
    FileHandle.standardError.write("usage: mkicon <in.png> <out.png> <side>\n".data(using: .utf8)!)
    exit(2)
}
let inPath = args[1], outPath = args[2]
let fill: CGFloat = 0.88

guard let src = NSImage(contentsOfFile: inPath),
      let srcRep = NSBitmapImageRep(data: src.tiffRepresentation ?? Data()) else {
    FileHandle.standardError.write("cannot load \(inPath)\n".data(using: .utf8)!); exit(1)
}
let sw = CGFloat(srcRep.pixelsWide), sh = CGFloat(srcRep.pixelsHigh)
let canvas = CGFloat(side)
let scale = (canvas * fill) / max(sw, sh)
let dw = sw * scale, dh = sh * scale
let ox = (canvas - dw) / 2, oy = (canvas - dh) / 2

guard let ctx = CGContext(data: nil, width: side, height: side,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
ctx.interpolationQuality = .high
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
guard let cg = srcRep.cgImage else { exit(1) }
ctx.draw(cg, in: CGRect(x: ox, y: oy, width: dw, height: dh))

guard let out = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: out)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
