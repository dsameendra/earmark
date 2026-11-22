import AppKit
import Testing

@testable import DesignSystem

/// Size-aware stock fallback (T34 follow-up d, `specs/design/m8-symbol-review.md` recommendation).
@Suite("DSIcon size rule") struct IconSizeRuleTests {
    @Test func heavyFiveAreStockAtToolbarAndMenuSizes() {
        let heavy: [DSSymbol] = [.liveCaptions, .recentlyDeleted, .settings, .video, .download]
        #expect(Set(heavy) == DSSymbol.heavyAtSmallSizes)
        for symbol in heavy {
            for context in [DSIconContext.toolbar, .menu] { #expect(symbol.prefersStock(atPointSize: context.pointSize)) }
            #expect(symbol.prefersStock(atPointSize: 15))
            #expect(!symbol.prefersStock(atPointSize: 15.5))
        }
    }

    @Test func customStaysInSidebarHeadersAndEmptyStates() {
        for symbol in DSSymbol.allCases {
            for context in [DSIconContext.sidebar, .header, .emptyState] {
                #expect(!symbol.prefersStock(atPointSize: context.pointSize), "\(symbol) in \(context)")
            }
            #expect(!symbol.prefersStock(atPointSize: nil))
        }
    }

    @Test func otherSymbolsAreCustomEvenAtToolbarSize() {
        for symbol in DSSymbol.allCases where !DSSymbol.heavyAtSmallSizes.contains(symbol) {
            #expect(!symbol.prefersStock(atPointSize: 13))
        }
    }

    @Test func everyStockFallbackIsARealSymbol() {
        for symbol in DSSymbol.allCases {
            #expect(NSImage(systemSymbolName: symbol.systemImageName, accessibilityDescription: nil) != nil, "\(symbol.systemImageName)")
        }
    }

    @Test func contextSizesAreOrdered() {
        #expect(DSIconContext.menu.pointSize < DSIconContext.toolbar.pointSize)
        #expect(DSIconContext.toolbar.pointSize < DSIconContext.sidebar.pointSize)
    }
}
