import AppKit
import Foundation
import Testing

@testable import DesignSystem

/// Writes the T33 weight-match contact sheet. Opt in with `EARMARK_WRITE_SYMBOL_SHEET=1`:
///
///     EARMARK_WRITE_SYMBOL_SHEET=1 swift test --filter SymbolReviewSheet
///
/// Output: `specs/design/m8-symbol-review.png` (stock vs custom, Regular and Semibold, 17 pt sidebar and 15 pt toolbar,
/// each next to system text of the same size and weight) and a metrics table on stdout (and in
/// `EARMARK_SYMBOL_METRICS_PATH` when set).
@Suite("SymbolReviewSheet") struct SymbolReviewSheet {
    private static let enabled = ProcessInfo.processInfo.environment["EARMARK_WRITE_SYMBOL_SHEET"] == "1"

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    @MainActor @Test(.enabled(if: SymbolReviewSheet.enabled)) func writeContactSheet() throws {
        #expect(DSSymbol.library.hasCustomAsset, "the catalog must be compiled for the review sheet")
        let variants: [(size: CGFloat, weight: NSFont.Weight, name: String)] = [
            (17, .regular, "Regular 17"), (17, .semibold, "Semibold 17"), (15, .regular, "Regular 15"), (15, .semibold, "Semibold 15"),
        ]
        let nameW: CGFloat = 150, cellW: CGFloat = 112, bigW: CGFloat = 84, rowH: CGFloat = 46, headerH: CGFloat = 54, margin: CGFloat = 20
        let width = margin * 2 + nameW + CGFloat(variants.count * 2) * cellW + 2 * bigW
        let height = margin * 2 + headerH + CGFloat(DSSymbol.allCases.count) * rowH
        let scale = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let gc = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = gc
        let bg = NSColor(srgbRed: 0xF3 / 255, green: 0xEE / 255, blue: 0xE5 / 255, alpha: 1)
        bg.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        func text(_ s: String, at p: NSPoint, size: CGFloat = 11, weight: NSFont.Weight = .regular, color: NSColor = SymbolRaster.ink) {
            NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
                .draw(at: NSPoint(x: p.x, y: height - p.y - size - 2))
        }
        func attachment(_ image: NSImage?, _ label: String, size: CGFloat, weight: NSFont.Weight, at p: NSPoint) {
            guard let image else { return }
            let att = NSTextAttachment()
            att.image = image
            let s = NSMutableAttributedString(attachment: att)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: SymbolRaster.ink]
            s.append(NSAttributedString(string: "  " + label, attributes: attrs))
            s.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: weight), range: NSRange(location: 0, length: 1))
            s.draw(at: NSPoint(x: p.x, y: height - p.y - size - 4))
        }

        text("Earmark symbols vs stock SF Symbols: weight match (T33)", at: NSPoint(x: margin, y: margin), size: 15, weight: .semibold)
        var x = margin + nameW
        for v in variants {
            text(v.name + " pt, stock", at: NSPoint(x: x, y: margin + 30), size: 10, weight: .medium)
            text("custom", at: NSPoint(x: x + cellW, y: margin + 30), size: 10, weight: .medium, color: SymbolRaster.ember)
            x += cellW * 2
        }
        text("40 pt stock", at: NSPoint(x: x, y: margin + 30), size: 10, weight: .medium)
        text("custom", at: NSPoint(x: x + bigW, y: margin + 30), size: 10, weight: .medium, color: SymbolRaster.ember)

        for (row, symbol) in DSSymbol.allCases.enumerated() {
            let y = margin + headerH + CGFloat(row) * rowH
            if row % 2 == 0 {
                NSColor.white.withAlphaComponent(0.45).setFill()
                NSRect(x: margin, y: height - y - rowH, width: width - 2 * margin, height: rowH).fill()
            }
            text(symbol.accessibilityLabel, at: NSPoint(x: margin + 8, y: y + 8), size: 12, weight: .semibold)
            text(symbol.assetName, at: NSPoint(x: margin + 8, y: y + 24), size: 9, color: .secondaryLabelColor)
            var cx = margin + nameW
            for v in variants {
                let label = "Label"
                attachment(SymbolRaster.stock(symbol, pointSize: v.size, weight: v.weight), label, size: v.size, weight: v.weight, at: NSPoint(x: cx, y: y + 12))
                attachment(SymbolRaster.custom(symbol, pointSize: v.size, weight: v.weight), label, size: v.size, weight: v.weight, at: NSPoint(x: cx + cellW, y: y + 12))
                cx += cellW * 2
            }
            if let stock = SymbolRaster.stock(symbol, pointSize: 40, weight: .regular),
                let custom = SymbolRaster.custom(symbol, pointSize: 40, weight: .regular)
            {
                stock.draw(in: NSRect(x: cx + 8, y: height - y - rowH + (rowH - stock.size.height) / 2, width: stock.size.width, height: stock.size.height))
                custom.draw(in: NSRect(x: cx + bigW + 8, y: height - y - rowH + (rowH - custom.size.height) / 2, width: custom.size.width, height: custom.size.height))
            }
        }
        gc.flushGraphics()
        let out = repoRoot().appendingPathComponent("specs/design/m8-symbol-review.png")
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: out)

        // Metrics: mean stroke thickness (2 x area / perimeter) at 100 pt, medium scale, monochrome, per weight.
        var lines = ["symbol | weight | stock t | custom t | ratio | stock h | custom h | h ratio"]
        for symbol in DSSymbol.allCases {
            for (name, w) in [("Regular", NSFont.Weight.regular), ("Semibold", .semibold)] {
                guard let s = SymbolRaster.stock(symbol, pointSize: 100, weight: w), let c = SymbolRaster.custom(symbol, pointSize: 100, weight: w, duotone: false)
                else { continue }
                let st = SymbolRaster.meanThickness(s), ct = SymbolRaster.meanThickness(c)
                let sb = SymbolRaster.inkBounds(s), cb = SymbolRaster.inkBounds(c)
                lines.append(
                    "\(symbol.rawValue) | \(name) | \(String(format: "%.2f", st)) | \(String(format: "%.2f", ct)) | \(String(format: "%.2f", ct / st)) | \(String(format: "%.1f", sb.height)) | \(String(format: "%.1f", cb.height)) | \(String(format: "%.2f", cb.height / sb.height))"
                )
            }
        }
        // Reference: stock circle vs custom stems at each weight (the calibration the generator uses).
        let report = lines.joined(separator: "\n")
        print(report)
        if let path = ProcessInfo.processInfo.environment["EARMARK_SYMBOL_METRICS_PATH"] { try report.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
