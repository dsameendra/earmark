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

    public static let white = RGB(1, 1, 1)
    /// Approximation of the dark-mode text background.
    public static let darkSurface = RGB(0.118, 0.118, 0.118)
}

/// Color-blind-considerate speaker palette (Okabe-Ito derived) tuned for >= 3:1 against light and dark surfaces.
///
/// Speaker identity is never conveyed by color alone: ``SpeakerChip`` also shows the name.
public enum SpeakerPalette {
    /// Light/dark variants of one speaker color.
    public struct Entry: Sendable, Hashable {
        public let light: RGB
        public let dark: RGB
    }

    public static let entries: [Entry] = [
        Entry(light: RGB(0.00, 0.37, 0.70), dark: RGB(0.40, 0.67, 1.00)),  // blue
        Entry(light: RGB(0.70, 0.30, 0.00), dark: RGB(1.00, 0.62, 0.30)),  // vermillion
        Entry(light: RGB(0.00, 0.45, 0.30), dark: RGB(0.25, 0.80, 0.60)),  // bluish green
        Entry(light: RGB(0.62, 0.20, 0.55), dark: RGB(0.90, 0.55, 0.85)),  // reddish purple
        Entry(light: RGB(0.55, 0.45, 0.00), dark: RGB(0.95, 0.85, 0.30)),  // olive
        Entry(light: RGB(0.00, 0.50, 0.55), dark: RGB(0.35, 0.85, 0.90)),  // teal
        Entry(light: RGB(0.72, 0.15, 0.25), dark: RGB(1.00, 0.50, 0.55)),  // crimson
        Entry(light: RGB(0.35, 0.35, 0.40), dark: RGB(0.70, 0.70, 0.75)),  // slate
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
