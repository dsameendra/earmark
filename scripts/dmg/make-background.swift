import AppKit

// Author installer artwork in points, with separate 1x/2x representations for Finder.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift make-background.swift OUTPUT_DIRECTORY local|selfsigned|distribution")
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let isPreview = CommandLine.arguments[2] == "local"
let isSelfSigned = CommandLine.arguments[2] == "selfsigned"
let width: CGFloat = 660
let height: CGFloat = 420
let paper = NSColor(srgbRed: 243 / 255, green: 238 / 255, blue: 229 / 255, alpha: 1)
let sheet = NSColor(srgbRed: 252 / 255, green: 250 / 255, blue: 246 / 255, alpha: 1)
let ink = NSColor(srgbRed: 28 / 255, green: 27 / 255, blue: 24 / 255, alpha: 1)
let secondary = NSColor(srgbRed: 91 / 255, green: 85 / 255, blue: 75 / 255, alpha: 1)
let ember = NSColor(srgbRed: 196 / 255, green: 75 / 255, blue: 22 / 255, alpha: 1)

func font(_ size: CGFloat, serif: Bool = false) -> NSFont {
    let base = NSFont.systemFont(ofSize: size)
    guard serif, let descriptor = base.fontDescriptor.withDesign(.serif), let result = NSFont(descriptor: descriptor, size: size)
    else { return base }
    return result
}

func text(_ value: String, top: CGFloat, size: CGFloat, color: NSColor, serif: Bool = false) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    (value as NSString).draw(
        in: NSRect(x: 24, y: height - top - size * 1.5, width: width - 48, height: size * 1.5),
        withAttributes: [.font: font(size, serif: serif), .foregroundColor: color, .paragraphStyle: style])
}

func draw(scale: CGFloat) throws {
    guard
        let context = CGContext(
            data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("Could not allocate installer artwork") }
    context.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }

    paper.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    ember.setFill()
    NSRect(x: 0, y: 0, width: 5, height: height).fill()

    text("Install Earmark", top: 27, size: 31, color: ink, serif: true)
    text("Drag Earmark into your Applications folder.", top: 77, size: 14, color: secondary)

    let card = NSBezierPath(roundedRect: NSRect(x: 28, y: height - 292, width: 604, height: 180), xRadius: 24, yRadius: 24)
    sheet.setFill()
    card.fill()
    ink.withAlphaComponent(0.08).setStroke()
    card.lineWidth = 1
    card.stroke()

    // Finder supplies both actual icons and their labels; the background supplies only the directional cue.
    let arrowY = height - 190
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 282, y: arrowY))
    shaft.line(to: NSPoint(x: 377, y: arrowY))
    shaft.lineWidth = 3
    shaft.lineCapStyle = .round
    ink.withAlphaComponent(0.34).setStroke()
    shaft.stroke()
    let tip = NSBezierPath()
    tip.move(to: NSPoint(x: 364, y: arrowY + 13))
    tip.line(to: NSPoint(x: 378, y: arrowY))
    tip.line(to: NSPoint(x: 364, y: arrowY - 13))
    tip.lineWidth = 3
    tip.lineCapStyle = .round
    tip.lineJoinStyle = .round
    ember.setStroke()
    tip.stroke()

    text("Listen once. Keep what matters.", top: 310, size: 17, color: ink, serif: true)
    text("macOS 26 or later  ·  Apple silicon", top: 342, size: 11, color: secondary)
    if isPreview { text("LOCAL PREVIEW", top: 376, size: 9, color: secondary) }
    if isSelfSigned { text("First launch: System Settings  ›  Privacy & Security  ›  Open Anyway", top: 376, size: 9, color: secondary) }

    let image = context.makeImage()!
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = NSSize(width: width, height: height)
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}

try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
try draw(scale: 1)
try draw(scale: 2)
