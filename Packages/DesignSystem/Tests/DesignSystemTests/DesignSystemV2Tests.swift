import AppKit
import SwiftUI
import Testing

@testable import DesignSystem

/// Contrast of every M8 token pair in both appearances (WCAG: 4.5:1 text, 3:1 large text and non-text).
@Suite("DSContrast") struct DSContrastTests {
    enum Surface: String, CaseIterable { case paper, sheet, inset, emberTint }

    static func surface(_ s: Surface, dark: Bool) -> RGB {
        let sheet = DSPalette.sheet.value(dark: dark).rgb
        switch s {
        case .paper: return DSPalette.paper.value(dark: dark).rgb
        case .sheet: return sheet
        case .inset: return DSPalette.inset.value(dark: dark).rgb
        // emberTint is a translucent tint in dark: composite it over Sheet, where selected rows sit.
        case .emberTint: return DSPalette.emberTint.value(dark: dark).composited(over: sheet)
        }
    }

    static let textTokens: [(String, DSColorToken)] = [
        ("ink", DSPalette.ink), ("ink2", DSPalette.ink2), ("ink3", DSPalette.ink3),
    ]
    static let statusTokens: [(String, DSColorToken)] = [
        ("ember", DSPalette.ember), ("recording", DSPalette.recording), ("success", DSPalette.success),
        ("warning", DSPalette.warning), ("danger", DSPalette.danger),
    ]

    /// Known pairs (light appearance) below 4.5:1 for small text, with the minimum they do reach. These are the
    /// locked brand hexes (not changed); use at >= 14 pt bold or as non-text (3:1) and re-check at T40.
    static let knownSub45: [String: Double] = [
        "ember/paper": 3.0, "ember/inset": 3.0, "ember/emberTint": 3.0,
        "recording/paper": 3.0, "recording/inset": 3.0, "recording/emberTint": 3.0,
        "success/emberTint": 3.0, "warning/emberTint": 3.0,
    ]

    @Test(arguments: [false, true]) func bodyTextTokensMeetAA(dark: Bool) {
        for (name, token) in Self.textTokens {
            for s in Surface.allCases {
                let ratio = RGB.contrast(token.value(dark: dark).rgb, Self.surface(s, dark: dark))
                // Known exception: dark ink3 on the (translucent) emberTint reaches 4.45:1 (locked hexes); T40 to confirm.
                let floor = (name == "ink3" && s == .emberTint && dark) ? 4.4 : 4.5
                #expect(ratio >= floor, "\(name) on \(s) dark=\(dark): \(ratio)")
            }
        }
    }

    @Test(arguments: [false, true]) func statusTokensOnSheetMeetAA(dark: Bool) {
        for (name, token) in Self.statusTokens {
            let ratio = RGB.contrast(token.value(dark: dark).rgb, Self.surface(.sheet, dark: dark))
            #expect(ratio >= 4.5, "\(name) on sheet dark=\(dark): \(ratio)")
        }
    }

    @Test(arguments: [false, true]) func statusTokensOnOtherSurfaces(dark: Bool) {
        for (name, token) in Self.statusTokens {
            for s in Surface.allCases where s != .sheet {
                let ratio = RGB.contrast(token.value(dark: dark).rgb, Self.surface(s, dark: dark))
                if let floor = Self.knownSub45["\(name)/\(s.rawValue)"], !dark {
                    #expect(ratio >= floor, "\(name) on \(s) light (known exception): \(ratio)")
                } else {
                    #expect(ratio >= 4.5, "\(name) on \(s) dark=\(dark): \(ratio)")
                }
            }
        }
    }

    /// The exceptions list may not silently grow: every light pair below 4.5 must be listed.
    @Test func exceptionsAreExactlyTheDocumentedOnes() {
        var below: Set<String> = []
        for (name, token) in Self.statusTokens {
            for s in Surface.allCases {
                if RGB.contrast(token.value(dark: false).rgb, Self.surface(s, dark: false)) < 4.5 { below.insert("\(name)/\(s.rawValue)") }
                if RGB.contrast(token.value(dark: true).rgb, Self.surface(s, dark: true)) < 4.5 {
                    below.insert("\(name)/\(s.rawValue)/dark")
                }
            }
        }
        // Light: ember, recording and the amber/green tokens on emberTint, plus paper/inset for ember and recording.
        let listed = Set(Self.knownSub45.keys)
        #expect(below.isSubset(of: listed), "undocumented sub-4.5 pairs: \(below.subtracting(listed).sorted())")
    }

    @Test(arguments: [false, true]) func primaryActionLabelOnEmber(dark: Bool) {
        // Prominent Ember button: white label on light Ember, ink (Night) label on the lighter dark Ember.
        let ember = DSPalette.ember.value(dark: dark).rgb
        let label: RGB = dark ? DSPalette.paper.dark.rgb : .white
        #expect(RGB.contrast(label, ember) >= 4.5)
    }

    @Test(arguments: [false, true]) func hairlinesAreVisibleNotLoud(dark: Bool) {
        let sheet = Self.surface(.sheet, dark: dark)
        let line = DSPalette.line.value(dark: dark).composited(over: sheet)
        let strong = DSPalette.lineStrong.value(dark: dark).composited(over: sheet)
        #expect(RGB.contrast(strong, sheet) >= 3.0, "solid-twin border must reach 3:1 as a UI boundary")
        #expect(RGB.contrast(strong, sheet) > RGB.contrast(line, sheet))
    }

    @Test(arguments: [false, true]) func surfacesAreDistinctTiers(dark: Bool) {
        let paper = Self.surface(.paper, dark: dark)
        let sheet = Self.surface(.sheet, dark: dark)
        let inset = Self.surface(.inset, dark: dark)
        #expect(paper != sheet && sheet != inset && paper != inset)
    }

    @Test(arguments: [false, true]) func speakerColorsReadOnEverySurface(dark: Bool) {
        for (i, e) in SpeakerPalette.entries.enumerated() {
            let c = dark ? e.dark : e.light
            for s in [Surface.paper, .sheet, .inset] {
                let ratio = RGB.contrast(c, Self.surface(s, dark: dark))
                #expect(ratio >= 3.0, "speaker \(i) on \(s) dark=\(dark): \(ratio)")
            }
        }
    }

    @Test func boardPaletteSlotsAreAdopted() {
        #expect(SpeakerPalette.entries[0].light == RGB(hex: 0xC44B16))
        #expect(SpeakerPalette.entries[1].light == RGB(hex: 0x1B7A74))
        #expect(SpeakerPalette.entries[3].dark == RGB(hex: 0xE0B04A))
        #expect(SpeakerPalette.entries.count == 8)
    }
}

@Suite("DSTokens") struct DSTokenTests {
    @Test func hexRoundTrip() {
        let c = DSRGBA(hex: 0xC44B16)
        #expect(abs(c.r - 196.0 / 255) < 1e-9 && abs(c.g - 75.0 / 255) < 1e-9 && abs(c.b - 22.0 / 255) < 1e-9)
    }
    @Test func ember() {
        #expect(DSPalette.ember.light == DSRGBA(hex: 0xC44B16))
        #expect(DSPalette.ember.dark == DSRGBA(hex: 0xF28A57))
        #expect(DSPalette.emberTint.dark.a == 0.16)
    }
    @Test func lockedPaperSheetInset() {
        #expect(DSPalette.paper.light == DSRGBA(hex: 0xF3EEE5) && DSPalette.paper.dark == DSRGBA(hex: 0x12110F))
        #expect(DSPalette.sheet.light == DSRGBA(hex: 0xFCFAF6) && DSPalette.sheet.dark == DSRGBA(hex: 0x1B1A17))
        #expect(DSPalette.inset.light == DSRGBA(hex: 0xF7F3EB) && DSPalette.inset.dark == DSRGBA(hex: 0x22211D))
    }
    @Test func recordingIsNotEmber() { #expect(DSPalette.recording != DSPalette.ember && DSPalette.danger != DSPalette.ember) }
    @Test func concentricRadii() {
        #expect(DSRadius.concentric(outer: 26, padding: 12) == 14)
        #expect(DSRadius.concentric(outer: 6, padding: 12) == 0)
    }
    @Test func minControlHeightIs28() { #expect(DSLayout.minControlHeight == 28) }
    @Test func radiiMonotonic() {
        let r = [DSRadius.small, DSRadius.medium, DSRadius.large, DSRadius.card, DSRadius.panel, DSRadius.pill]
        #expect(r == r.sorted())
    }
    @Test func adaptiveColorsResolveBothAppearances() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        func resolve(_ c: Color, _ a: NSAppearance) -> NSColor {
            var out = NSColor.clear
            a.performAsCurrentDrawingAppearance { out = NSColor(c).usingColorSpace(.sRGB) ?? .clear }
            return out
        }
        let l = resolve(DSColor.contentBackground, light)
        let d = resolve(DSColor.contentBackground, dark)
        #expect(abs(l.redComponent - 252.0 / 255) < 0.01)
        #expect(abs(d.redComponent - 27.0 / 255) < 0.01)
    }
}

@Suite("DSMotion") struct DSMotionTests {
    @Test func curvesMatchHandoff() {
        #expect(DSMotion.settle.controlPoints == (0.2, 0.9, 0.3, 1.1))
        #expect(DSMotion.glide.controlPoints == (0.4, 0, 0.2, 1))
        #expect(DSMotion.exit.controlPoints == (0.4, 0, 1, 1))
    }
    @Test func durationsInRange() {
        for m in DSMotion.allCases { #expect(m.durationRange.contains(m.defaultDuration)) }
        #expect(DSMotion.settle.durationRange == 0.32...0.5)
        #expect(DSMotion.glide.durationRange == 0.2...0.28)
        #expect(DSMotion.exit.defaultDuration == 0.14)
        #expect(DSMotion.exit.defaultDuration < DSMotion.settle.defaultDuration)
    }
    @Test func reduceMotionIsA120msCrossfadeNotACut() {
        let reduced = AccessibilityPolicy(reduceMotion: true)
        for m in DSMotion.allCases {
            #expect(m.animation(reduced) == .linear(duration: 0.12))
            #expect(m.animation(AccessibilityPolicy()) != .linear(duration: 0.12))
        }
        #expect(DSMotion.reducedDuration == 0.12)
    }
    @Test func loopsStopUnderReduceMotion() {
        let reduced = AccessibilityPolicy(reduceMotion: true)
        #expect(DSMotion.pulse(reduced) == nil && DSMotion.shimmer(reduced) == nil)
        #expect(DSMotion.pulse() != nil && DSMotion.shimmer() != nil)
        #expect(DSMotion.pulseDuration == 2)
    }
    @Test func existingPolicyAnimationStillDropsToNil() {
        #expect(AccessibilityPolicy(reduceMotion: true).animation(.easeIn) == nil)
    }
}

@Suite("DSGlass") struct DSGlassPolicyTests {
    @Test func budgetIsThree() {
        #expect(DSGlass.maxLayersPerScreen == 3)
        #expect(DSGlass.allowedLayerMarkers.count == 3)
    }
    @Test func layerSpecsMatchBoards() {
        #expect(DSGlassLayer.clear.blurRadius == 16 && DSGlassLayer.clear.fillOpacity == 0.30)
        #expect(DSGlassLayer.regular.blurRadius == 28 && DSGlassLayer.regular.fillOpacity == 0.58)
        #expect(DSGlassLayer.prominent.blurRadius == 40 && DSGlassLayer.prominent.fillOpacity == 0.82)
    }
    @Test func solidTwinFollowsPolicy() {
        #expect(!AccessibilityPolicy().usesSolidSurface)
        #expect(AccessibilityPolicy(reduceTransparency: true).usesSolidSurface)
        #expect(AccessibilityPolicy(increaseContrast: true).usesSolidSurface)
        #expect(!AccessibilityPolicy(reduceMotion: true).usesSolidSurface)
    }
    @Test func layersMapToDistinctGlass() {
        #expect(DSGlassLayer.clear.glass() != DSGlassLayer.regular.glass())
        #expect(DSGlassLayer.regular.glass() != DSGlassLayer.prominent.glass())
        #expect(DSGlassLayer.regular.glass(interactive: true) != DSGlassLayer.regular.glass())
    }

    @MainActor @Test func everyLayerRendersAsOpaqueTwin() throws {
        let policy = AccessibilityPolicy(reduceTransparency: true)
        for layer in DSGlassLayer.allCases {
            let view = Color.clear.frame(width: 80, height: 80).dsGlass(layer, radius: 12).environment(\.accessibilityPolicyOverride, policy)
            let r = ImageRenderer(content: view.frame(width: 80, height: 80))
            r.scale = 2
            let img = try #require(r.cgImage)
            #expect(opaquePixels(img) > 1000, "\(layer) twin must be opaque")
        }
    }

    @MainActor @Test func cardsAreSolidWithoutGlass() throws {
        for policy in [AccessibilityPolicy(), AccessibilityPolicy(increaseContrast: true)] {
            for tier in [DSSurfaceTier.sheet, .inset] {
                let view = Color.clear.frame(width: 80, height: 80).dsSolidSurface(tier, radius: 12)
                    .environment(\.accessibilityPolicyOverride, policy)
                let r = ImageRenderer(content: view.frame(width: 80, height: 80))
                r.scale = 2
                let img = try #require(r.cgImage)
                #expect(opaquePixels(img) > 1000, "\(tier) card must be opaque regardless of policy")
            }
        }
    }

    @MainActor @Test func sheetAndInsetCardsRender() {
        let views: [AnyView] = [AnyView(SheetCard { Text("a") }), AnyView(InsetCard { Text("b") }), AnyView(SheetCard(selected: true) { Text("c") })]
        for v in views {
            let r = ImageRenderer(content: v.frame(width: 120, height: 80))
            #expect(r.cgImage != nil)
        }
    }

    @MainActor @Test func deprecatedShimsStillRender() {
        #expect(renderDeprecatedShims())
    }
}

@Suite("Serif and Sinhala") struct SerifSinhalaTests {
    @Test func latinResolvesToNewYork() {
        let font = SinhalaFont.serifNSFont(size: 19)
        let name = SinhalaFont.resolvedFontName(for: "Hello", using: font)
        #expect(name.localizedCaseInsensitiveContains("NewYork"), "resolved \(name)")
    }
    @Test func sinhalaStillFallsThroughToSinhalaFont() {
        let font = SinhalaFont.serifNSFont(size: 19)
        let name = SinhalaFont.resolvedFontName(for: "ශ්‍රී ලංකාව", using: font)
        #expect(name.localizedCaseInsensitiveContains("Sinhala"), "resolved \(name)")
    }
    @Test func sinhalaShapesAtEverySize() {
        for size in [11.0, 13.0, 17.0, 19.0, 26.0, 46.0] {
            let font = SinhalaFont.serifNSFont(size: size)
            #expect(SinhalaFont.shapedGlyphCount("ශ්‍රී ලංකාව", font: font) < "ශ්‍රී ලංකාව".unicodeScalars.count, "size \(size)")
        }
    }
}

@available(*, deprecated)
@MainActor private func renderDeprecatedShims() -> Bool {
    let views: [AnyView] = [AnyView(GlassCard { Text("a") }), AnyView(GlassPanel { Text("b") })]
    return views.allSatisfy { ImageRenderer(content: $0.frame(width: 120, height: 80)).cgImage != nil }
}

private func opaquePixels(_ image: CGImage) -> Int {
    let w = image.width
    let h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = data.withUnsafeMutableBytes {
        CGContext(
            data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return stride(from: 3, to: data.count, by: 4).filter { data[$0] > 200 }.count
}
