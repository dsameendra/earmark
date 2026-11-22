import AppCore
import AppKit
import SwiftUI
import Testing

@testable import DesignSystem

@Test func moduleLoads() { #expect(DesignSystemModule.name == "DesignSystem") }

@Suite("AccessibilityPolicy") struct PolicyTests {
    @Test func defaultsUseGlass() {
        let p = AccessibilityPolicy()
        #expect(!p.usesSolidSurface && !p.usesHighContrast && !p.suppressesMotion)
    }
    @Test func reduceTransparencyForcesSolid() { #expect(AccessibilityPolicy(reduceTransparency: true).usesSolidSurface) }
    @Test func increaseContrastForcesSolid() {
        let p = AccessibilityPolicy(increaseContrast: true)
        #expect(p.usesSolidSurface && p.usesHighContrast)
    }
    @Test func reduceMotionDropsAnimation() {
        #expect(AccessibilityPolicy(reduceMotion: true).animation(.easeIn) == nil)
        #expect(AccessibilityPolicy().animation(.easeIn) != nil)
        #expect(AccessibilityPolicy(reduceMotion: true).suppressesMotion)
    }
}

@Suite("SpeakerPalette") struct PaletteTests {
    @Test func slotsWrapAndNegativeSafe() {
        let n = SpeakerPalette.entries.count
        #expect(SpeakerPalette.entry(forSlot: n) == SpeakerPalette.entry(forSlot: 0))
        #expect(SpeakerPalette.entry(forSlot: -1) == SpeakerPalette.entry(forSlot: n - 1))
    }
    @Test func atLeastFourDistinctSpeakers() { #expect(Set(SpeakerPalette.entries).count >= 4) }
    @Test func contrastAgainstSurfaces() {
        for (i, e) in SpeakerPalette.entries.enumerated() {
            #expect(RGB.contrast(e.light, .white) >= 3.0, "light slot \(i)")
            #expect(RGB.contrast(e.dark, .darkSurface) >= 3.0, "dark slot \(i)")
        }
    }
    @Test func contrastMath() {
        #expect(abs(RGB.contrast(.white, RGB(0, 0, 0)) - 21) < 0.01)
        #expect(abs(RGB.contrast(.white, .white) - 1) < 0.0001)
    }
}

@Suite("Language and status") struct LabelTests {
    @Test func badgeLabel() {
        #expect(LanguageBadge.label(for: "en-US") == "EN")
        #expect(LanguageBadge.label(for: .sinhala) == "SI")
    }
    @Test func toneColorsDefined() { #expect(DSTone.allCases.count == 5) }
    @Test func spacingMonotonic() {
        let s = [DSSpacing.xxs, DSSpacing.xs, DSSpacing.sm, DSSpacing.md, DSSpacing.lg, DSSpacing.xl, DSSpacing.xxl]
        #expect(s == s.sorted())
    }
}

@Suite("SinhalaFont") struct SinhalaTests {
    static let sample = "ශ්‍රී ලංකාව"  // contains conjunct (shri) and pili vowel signs

    @Test func detectsSinhala() {
        #expect(SinhalaFont.containsSinhala(Self.sample))
        #expect(SinhalaFont.containsSinhala("hello ක"))
        #expect(!SinhalaFont.containsSinhala("hello"))
    }
    @Test func fallbackResolvesToSinhalaFont() {
        let font = SinhalaFont.nsFont(size: 17)
        let name = SinhalaFont.resolvedFontName(for: Self.sample, using: font)
        #expect(name.localizedCaseInsensitiveContains("Sinhala"), "resolved \(name)")
        #expect(!name.localizedCaseInsensitiveContains("LastResort"))
    }
    @Test func shapingFormsClusters() {
        // Correct shaping reorders/ligates: ZWJ and viramas never produce a 1:1 scalar-to-glyph mapping that leaves tofu.
        let font = SinhalaFont.nsFont(size: 17)
        let scalars = Self.sample.unicodeScalars.count
        let glyphs = SinhalaFont.shapedGlyphCount(Self.sample, font: font)
        #expect(glyphs > 0)
        #expect(glyphs < scalars, "expected conjunct/ZWJ ligation: \(glyphs) glyphs for \(scalars) scalars")
    }
    @Test @MainActor func sinhalaRendersInk() throws {
        let img = try #require(
            render(Text(Self.sample).font(SinhalaFont.font(size: 28)).foregroundStyle(.black), size: CGSize(width: 240, height: 60)))
        #expect(inkPixelCount(img) > 200)
    }
    @Test func mixedTextKeepsLatinInBaseFont() {
        let font = SinhalaFont.nsFont(size: 17)
        #expect(!SinhalaFont.resolvedFontName(for: "Hello", using: font).localizedCaseInsensitiveContains("Sinhala"))
    }
}

@Suite("Render smoke") @MainActor struct RenderTests {
    static func views() -> [(String, AnyView)] {
        [
            ("SheetCard", AnyView(SheetCard { Text("Card") })),
            ("InsetCard", AnyView(InsetCard { Text("Card") })),
            ("Floater", AnyView(Text("Panel").padding().dsGlass(.prominent, radius: DSRadius.large))),
            ("Toolbar", AnyView(GlassToolbarButton("Add", systemImage: "plus") {})),
            ("Pill", AnyView(StatusPill(state: .completed))),
            ("Recording", AnyView(RecordingIndicator())),
            ("Badge", AnyView(LanguageBadge("si"))),
            ("Speaker", AnyView(SpeakerChip(name: "Ann", slot: 2))),
            ("Progress", AnyView(ProgressRow(title: "a.wav", detail: "x", fraction: 0.5))),
            ("Empty", AnyView(EmptyState(systemImage: "tray", title: "Empty"))),
            ("Error", AnyView(ErrorState(message: "Boom") {})),
            ("Skeleton", AnyView(Skeleton(width: 80))),
        ]
    }

    @Test func allRenderInBothModes() throws {
        let modes = [AccessibilityPolicy(), AccessibilityPolicy(reduceTransparency: true, increaseContrast: true, reduceMotion: true)]
        for policy in modes {
            for (name, view) in Self.views() {
                let img = render(
                    view.environment(\.accessibilityPolicyOverride, policy).padding(8), size: CGSize(width: 200, height: 120))
                #expect(img != nil, "\(name) failed to render")
                if let img { #expect(img.width > 0 && img.height > 0) }
            }
        }
    }

    @Test func solidFallbackDrawsOpaqueSurface() throws {
        let policy = AccessibilityPolicy(reduceTransparency: true)
        let view = Color.clear.frame(width: 80, height: 80).glassBackground().environment(\.accessibilityPolicyOverride, policy)
        let img = try #require(render(view, size: CGSize(width: 80, height: 80)))
        #expect(inkPixelCount(img, alphaAbove: 200) > 1000)
    }
}

@MainActor private func render<V: View>(_ view: V, size: CGSize) -> CGImage? {
    let r = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    r.scale = 2
    return r.cgImage
}

/// Counts pixels that are non-transparent with alpha above threshold.
private func inkPixelCount(_ image: CGImage, alphaAbove: UInt8 = 64) -> Int {
    let w = image.width
    let h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = data.withUnsafeMutableBytes {
        CGContext(
            data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return stride(from: 3, to: data.count, by: 4).filter { data[$0] > alphaAbove }.count
}
