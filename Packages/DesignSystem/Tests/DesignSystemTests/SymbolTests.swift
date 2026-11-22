import AppKit
import SwiftUI
import Testing

@testable import DesignSystem

/// Locates `Symbols.xcassets` in the source tree (tests run from the package checkout).
func symbolCatalogURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/DesignSystem/Symbols/Resources/Symbols.xcassets")
}

@Suite("DSSymbol") struct DSSymbolTests {
    @Test func coversTheBoardPlusEar() {
        #expect(DSSymbol.allCases.count == 27)
        #expect(Set(DSSymbol.allCases.map(\.assetName)).count == 27)
    }

    @Test func everyAssetNameExistsOnDisk() throws {
        let catalog = symbolCatalogURL()
        for symbol in DSSymbol.allCases {
            let dir = catalog.appendingPathComponent("\(symbol.assetName).symbolset")
            let svg = dir.appendingPathComponent("\(symbol.assetName).svg")
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Contents.json").path), "\(symbol) Contents.json")
            #expect(FileManager.default.fileExists(atPath: svg.path), "\(symbol) svg")
        }
    }

    @Test func everySymbolsetHasAll27CellsAndTwoLayers() throws {
        let weights = ["Ultralight", "Thin", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"]
        for symbol in DSSymbol.allCases {
            let svg = try String(
                contentsOf: symbolCatalogURL().appendingPathComponent("\(symbol.assetName).symbolset/\(symbol.assetName).svg"),
                encoding: .utf8)
            for weight in weights {
                for scale in ["S", "M", "L"] {
                    #expect(svg.contains("<g id=\"\(weight)-\(scale)\""), "\(symbol) \(weight)-\(scale)")
                }
            }
            #expect(svg.components(separatedBy: "hierarchical-0:primary SFSymbolsPreviewWireframe").count - 1 == 27)
            #expect(svg.components(separatedBy: "hierarchical-1:secondary SFSymbolsPreviewWireframe").count - 1 == 27)
        }
    }

    @Test func everySymbolHasALabel() {
        for symbol in DSSymbol.allCases { #expect(!symbol.accessibilityLabel.isEmpty, "\(symbol)") }
    }

    @Test func fallbacksAreValidSFSymbols() {
        for symbol in DSSymbol.allCases {
            #expect(
                NSImage(systemSymbolName: symbol.systemImageName, accessibilityDescription: nil) != nil,
                Comment(rawValue: "\(symbol): \(symbol.systemImageName)"))
        }
    }

    @Test func replacedStockNamesAreValidAndMapBack() {
        for symbol in DSSymbol.allCases {
            for name in symbol.replacedStockNames {
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, Comment(rawValue: name))
                #expect(DSSymbol(replacingStock: name) == symbol)
            }
        }
        #expect(DSSymbol(replacingStock: "xmark") == nil)
        #expect(DSSymbol(replacingStock: "chevron.right") == nil)
    }

    @Test func missingAssetFallsBackToStock() {
        #expect(DSSymbolResolution.resolve(assetName: "earmark.bogus", fallback: "star") == .stock("star"))
        #expect(!DSSymbolAssets.contains("earmark.bogus", in: .module))
    }

    @Test func compiledCatalogResolvesEveryCustomSymbol() {
        // swift test compiles the catalog into the resource bundle; when it is absent every symbol must still resolve to stock.
        let compiled = Bundle.module.url(forResource: "Assets", withExtension: "car") != nil
        for symbol in DSSymbol.allCases {
            if compiled {
                #expect(symbol.resolution == .custom(symbol.assetName), "\(symbol)")
            } else {
                #expect(symbol.resolution == .stock(symbol.systemImageName))
            }
        }
    }

    @MainActor @Test func iconsRenderUnderImageRenderer() {
        for symbol in DSSymbol.allCases {
            let renderer = ImageRenderer(content: DSIcon(symbol).font(.system(size: 17)).frame(width: 24, height: 24))
            #expect(renderer.cgImage != nil, "\(symbol)")
        }
    }

    @Test func weightsDiffer() throws {
        let light = SymbolRaster.coverage(of: DSSymbol.library, weight: .ultraLight)
        let regular = SymbolRaster.coverage(of: DSSymbol.library, weight: .regular)
        let black = SymbolRaster.coverage(of: DSSymbol.library, weight: .black)
        #expect(light < regular && regular < black)
    }

    @Test func paletteRendersInkAndEmber() throws {
        guard DSSymbol.library.hasCustomAsset else { return }
        let colors = SymbolRaster.distinctColors(of: DSSymbol.library)
        #expect(colors.ink > 0 && colors.ember > 0)
    }
}
