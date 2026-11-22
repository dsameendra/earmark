// Rasterises an SVG to a PNG using AppKit's built-in SVG support.
// Usage: swift render.swift <in.svg> <out.png> <pixelWidth> [pixelHeight] [bg-hex]
import AppKit

let args = CommandLine.arguments
guard args.count >= 4, let image = NSImage(contentsOfFile: args[1]), let w = Int(args[3]) else {
    FileHandle.standardError.write(Data("usage: render.swift in.svg out.png width [height] [bg-hex]\n".utf8))
    exit(1)
}
let h = args.count > 4 ? (Int(args[4]) ?? w) : w
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
if args.count > 5, let v = UInt32(args[5], radix: 16) {
    NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
}
image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
