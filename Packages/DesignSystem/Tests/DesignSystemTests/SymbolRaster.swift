import AppKit

@testable import DesignSystem

/// Rasterises custom and stock symbols with AppKit for the weight-match review.
enum SymbolRaster {
    static let ink = NSColor(srgbRed: 0x1C / 255, green: 0x1B / 255, blue: 0x18 / 255, alpha: 1)
    static let ember = NSColor(srgbRed: 0xC4 / 255, green: 0x4B / 255, blue: 0x16 / 255, alpha: 1)

    /// Custom symbol image (palette: ink + ember), or the stock fallback if the catalog is not compiled.
    static func custom(_ symbol: DSSymbol, pointSize: CGFloat, weight: NSFont.Weight, scale: NSImage.SymbolScale = .medium, duotone: Bool = true) -> NSImage? {
        let base: NSImage?
        switch symbol.resolution {
        case .custom(let name): base = NSImage(symbolName: name, bundle: .module, variableValue: 1)
        case .stock(let name): base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: scale)
        return base?.withSymbolConfiguration(cfg.applying(.init(paletteColors: duotone ? [ink, ember] : [ink])))
    }

    static func stock(_ symbol: DSSymbol, pointSize: CGFloat, weight: NSFont.Weight, scale: NSImage.SymbolScale = .medium) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: scale)
        return NSImage(systemSymbolName: symbol.systemImageName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg.applying(.init(paletteColors: [ink])))
    }

    /// Draws an image on transparent black at `k`x and returns RGBA bytes.
    static func pixels(_ image: NSImage, k: Int = 4, pad: Int = 8) -> (data: [UInt8], width: Int, height: Int) {
        let w = Int(image.size.width.rounded(.up)) + pad * 2, h = Int(image.size.height.rounded(.up)) + pad * 2
        let ctx = CGContext(
            data: nil, width: w * k, height: h * k, bitsPerComponent: 8, bytesPerRow: w * k * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(k), y: CGFloat(k))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: CGFloat(pad), y: CGFloat(pad), width: image.size.width, height: image.size.height))
        NSGraphicsContext.restoreGraphicsState()
        let data = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: w * k * h * k * 4))
        return (data, w * k, h * k)
    }

    static func coverage(of symbol: DSSymbol, weight: NSFont.Weight) -> Int {
        guard let image = custom(symbol, pointSize: 60, weight: weight, duotone: false) else { return 0 }
        let p = pixels(image, k: 2)
        return stride(from: 3, to: p.data.count, by: 4).reduce(0) { $0 + (p.data[$1] > 127 ? 1 : 0) }
    }

    static func distinctColors(of symbol: DSSymbol) -> (ink: Int, ember: Int) {
        guard let image = custom(symbol, pointSize: 60, weight: .regular) else { return (0, 0) }
        let p = pixels(image, k: 2)
        var inkCount = 0, emberCount = 0
        for i in stride(from: 0, to: p.data.count, by: 4) where p.data[i + 3] > 200 {
            let r = Int(p.data[i]), g = Int(p.data[i + 1]), b = Int(p.data[i + 2])
            if r < 80 && g < 80 && b < 80 { inkCount += 1 }
            if r > 150 && g < 110 && b < 60 { emberCount += 1 }
        }
        return (inkCount, emberCount)
    }

    /// Average stroke thickness estimate in points: 2 x area / perimeter of the alpha > 50 % mask (exact for long thin strokes).
    static func meanThickness(_ image: NSImage, k: Int = 4) -> Double {
        let p = pixels(image, k: k)
        let w = p.width, h = p.height
        func on(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && p.data[(y * w + x) * 4 + 3] > 127 }
        var area = 0, perimeter = 0
        for y in 0..<h {
            for x in 0..<w where on(x, y) {
                area += 1
                if !on(x - 1, y) { perimeter += 1 }
                if !on(x + 1, y) { perimeter += 1 }
                if !on(x, y - 1) { perimeter += 1 }
                if !on(x, y + 1) { perimeter += 1 }
            }
        }
        return perimeter == 0 ? 0 : 2 * Double(area) / Double(perimeter) / Double(k)
    }

    /// Ink bounding box (points) of an image drawn at its natural size.
    static func inkBounds(_ image: NSImage, k: Int = 4) -> CGSize {
        let p = pixels(image, k: k)
        var minX = p.width, maxX = 0, minY = p.height, maxY = 0
        for y in 0..<p.height {
            for x in 0..<p.width where p.data[(y * p.width + x) * 4 + 3] > 127 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return .zero }
        return CGSize(width: Double(maxX - minX + 1) / Double(k), height: Double(maxY - minY + 1) / Double(k))
    }
}
