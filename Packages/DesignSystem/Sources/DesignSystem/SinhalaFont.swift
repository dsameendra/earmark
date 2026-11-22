import AppKit
import CoreText
import SwiftUI

/// Sinhala-safe font helpers. SF lacks Sinhala glyphs; we pin an explicit cascade list so shaping
/// (conjuncts, pili) and metrics are consistent in mixed Sinhala/English text, in SwiftUI and TextKit 2.
public enum SinhalaFont {
    /// Preferred Sinhala families in priority order (shipped with macOS).
    public static let preferredFamilies = ["Sinhala Sangam MN", "Sinhala MN"]

    /// `true` if `text` contains characters in the Sinhala block (U+0D80...U+0DFF) or Sinhala Archaic Numbers.
    public static func containsSinhala(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0D80...0x0DFF).contains($0.value) || (0x111E0...0x111FF).contains($0.value) }
    }

    /// An `NSFont` whose cascade list includes Sinhala families, usable in TextKit 2 text views.
    public static func nsFont(size: CGFloat, weight: NSFont.Weight = .regular, family: String? = nil) -> NSFont {
        let base: NSFont = family.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: weight)
        let cascade = preferredFamilies.map { name in
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
        }
        let desc = base.fontDescriptor.addingAttributes([.cascadeList: cascade])
        return NSFont(descriptor: desc, size: size) ?? base
    }

    /// New York (the system serif design) with the Sinhala cascade, for transcript text and titles that may mix
    /// Latin and Sinhala. Latin resolves to New York; Sinhala falls through to the Sinhala families.
    public static func serifNSFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        let cascade = preferredFamilies.map { name in
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
        }
        let desc = serif.addingAttributes([.cascadeList: cascade])
        return NSFont(descriptor: desc, size: size) ?? NSFont(descriptor: serif, size: size) ?? base
    }

    /// SwiftUI equivalent of ``serifNSFont(size:weight:)``.
    public static func serifFont(size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(serifNSFont(size: size, weight: weight) as CTFont)
    }

    /// SwiftUI font equivalent of ``nsFont(size:weight:family:)``.
    public static func font(size: CGFloat, weight: NSFont.Weight = .regular, family: String? = nil) -> Font {
        Font(nsFont(size: size, weight: weight, family: family) as CTFont)
    }

    /// PostScript name of the font CoreText picks to render the first character of `text`.
    public static func resolvedFontName(for text: String, using font: NSFont) -> String {
        let ns = text as NSString
        let r = ns.rangeOfComposedCharacterSequence(at: 0)
        let resolved = CTFontCreateForString(font as CTFont, text as CFString, CFRange(location: r.location, length: r.length))
        return CTFontCopyPostScriptName(resolved) as String
    }

    /// Shapes `text` with CoreText and returns the total glyph count (fewer glyphs than scalars means ligated conjuncts).
    public static func shapedGlyphCount(_ text: String, font: NSFont) -> Int {
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        return (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).reduce(0) { $0 + CTRunGetGlyphCount($1) }
    }
}
