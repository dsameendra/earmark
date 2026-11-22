import AppKit
import SwiftUI
import Testing

@testable import DesignSystem

/// Regression: several custom monochrome symbols kept their source ink colour and disappeared on dark sidebar chrome.
@Suite("Symbol foreground contrast") @MainActor
struct SymbolVisibilityTests {
    @Test(arguments: DSSymbol.allCases, [false, true])
    func restingSymbolsRemainVisible(symbol: DSSymbol, dark: Bool) throws {
        let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
        var visiblePixels = 0
        appearance.performAsCurrentDrawingAppearance {
            let view = DSIcon(symbol, style: .monochrome)
                .font(.system(size: 32)).frame(width: 64, height: 64)
                .background(DSColor.paper).environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: image) else { return }
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let brightest = max(color.redComponent, color.greenComponent, color.blueComponent)
                    if dark ? brightest > 0.5 : brightest < 0.55 { visiblePixels += 1 }
                }
            }
        }
        #expect(visiblePixels >= 15, "\(symbol) lost its foreground in \(dark ? "dark" : "light") appearance")
    }
}
