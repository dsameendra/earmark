import AppKit
import SwiftUI

/// An sRGB color triple used for contrast math independent of SwiftUI.
public struct RGB: Sendable, Hashable {
    public let r: Double
    public let g: Double
    public let b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio between two colors (1...21).
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Creates a colour from a `0xRRGGBB` hex value.
    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    public static let white = RGB(1, 1, 1)
    /// Approximation of the dark-mode text background.
    public static let darkSurface = RGB(0.118, 0.118, 0.118)
}

/// Color-blind-considerate speaker palette (M8 board palette plus the original blue and crimson) tuned for >= 3:1 against light and dark surfaces.
///
/// Speaker identity is never conveyed by color alone: ``SpeakerChip`` also shows the name.
public enum SpeakerPalette {
    /// Light/dark variants of one speaker color.
    public struct Entry: Sendable, Hashable {
        public let light: RGB
        public let dark: RGB
    }

    /// Slots 0-5 follow the M8 board palette (Handoff 1: ember, teal, indigo, amber, magenta, slate; dark variants
    /// matched in lightness; the two dark values for magenta and slate were chosen at T31). Slots 6-7 keep the original
    /// tested blue and crimson so eight speakers stay distinguishable. Every light entry is >= 3:1 on white, Sheet,
    /// Inset and Paper; every dark entry is >= 3:1 on the dark surfaces (see `DSContrastTests`).
    public static let entries: [Entry] = [
        Entry(light: RGB(hex: 0xC44B16), dark: RGB(hex: 0xF28A57)),  // ember
        Entry(light: RGB(hex: 0x1B7A74), dark: RGB(hex: 0x4FB3AB)),  // teal
        Entry(light: RGB(hex: 0x5558D6), dark: RGB(hex: 0x8E8CF0)),  // indigo
        Entry(light: RGB(hex: 0xA67A0B), dark: RGB(hex: 0xE0B04A)),  // amber
        Entry(light: RGB(hex: 0x9A3E7A), dark: RGB(hex: 0xE58AC0)),  // magenta
        Entry(light: RGB(hex: 0x5B6B7A), dark: RGB(hex: 0x9DB0C2)),  // slate
        Entry(light: RGB(0.00, 0.37, 0.70), dark: RGB(0.40, 0.67, 1.00)),  // blue
        Entry(light: RGB(0.72, 0.15, 0.25), dark: RGB(1.00, 0.50, 0.55)),  // crimson
    ]

    /// Entry for a zero-based speaker slot; wraps for slots beyond the palette size.
    public static func entry(forSlot slot: Int) -> Entry {
        let n = entries.count
        return entries[((slot % n) + n) % n]
    }

    /// Adaptive SwiftUI color for a speaker slot.
    public static func color(forSlot slot: Int) -> Color {
        let e = entry(forSlot: slot)
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let c = dark ? e.dark : e.light
                return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
            })
    }
}
