import AppKit
import SwiftUI

/// Namespace marker for the DesignSystem package.
public enum DesignSystemModule {
    /// Module name.
    public static let name = "DesignSystem"
}

/// Spacing scale in points.
public enum DSSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

/// Corner radius scale in points (Handoff 1: chip 10-16, card 20-24, panel 26, capsule 999).
public enum DSRadius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large: CGFloat = 16
    /// Cards (Sheet and Inset tiers).
    public static let card: CGFloat = 22
    /// Panels and the sidebar.
    public static let panel: CGFloat = 26
    public static let pill: CGFloat = 999

    /// Concentric rule: inner radius = outer radius - padding (never negative).
    public static func concentric(outer: CGFloat, padding: CGFloat) -> CGFloat { max(0, outer - padding) }
}

/// Layout constants from Handoff 1.
public enum DSLayout {
    /// macOS 26 minimum control height in points (the boards draw 32-40 pt capsules).
    public static let minControlHeight: CGFloat = 28
    public static let toolbarControlHeight: CGFloat = 32
    public static let prominentControlHeight: CGFloat = 36
    public static let toolbarHeight: CGFloat = 44
    public static let sidebarWidth: CGFloat = 232
    public static let windowInset: CGFloat = 12
    public static let contentMaxWidth: CGFloat = 1120
    public static let minWindowSize = CGSize(width: 960, height: 600)
    /// Below this window width the Editor inspector hides behind a toolbar toggle.
    public static let inspectorCollapseWidth: CGFloat = 1100
    /// Below this window width the sidebar collapses.
    public static let sidebarCollapseWidth: CGFloat = 800
}

/// Typography tokens. SF Pro for controls, New York (`.serif` design) for titles and transcript voice,
/// tabular numerals for timestamps. Text styles are used where they exist so Dynamic Type scaling and the
/// Sinhala cascade keep working; for Sinhala runs use ``SinhalaFont``.
public enum DSTypography {
    /// New York display, 46 pt.
    public static let display: Font = .system(size: 46, weight: .regular, design: .serif)
    /// New York title 1 (34-40 pt in the boards).
    public static let title1: Font = .system(size: 34, weight: .regular, design: .serif)
    /// New York title 2 (24-28 pt in the boards).
    public static let title2: Font = .system(size: 26, weight: .regular, design: .serif)
    /// View titles. New York.
    public static let title: Font = .system(.title2, design: .serif).weight(.regular)
    public static let headline: Font = .headline
    /// Row titles and body.
    public static let body: Font = .body
    public static let caption: Font = .caption
    public static let badge: Font = .caption2.weight(.semibold)
    /// SF Pro 12 with tabular numerals.
    public static let timestamp: Font = .caption.monospacedDigit()
    /// Small caps-style labels (apply `.textCase(.uppercase)` and `.tracking(DSTypography.labelTracking)`).
    public static let label: Font = .system(size: 11, weight: .semibold)
    public static let labelTracking: CGFloat = 0.77
    /// Transcript voice: New York 19 with line height 1.6 (apply `.lineSpacing(DSTypography.transcriptLineSpacing)`).
    public static let transcript: Font = .system(size: 19, weight: .regular, design: .serif)
    public static let transcriptLineSpacing: CGFloat = 19 * 0.6 - 4
    /// Live caption, SF Pro 24 medium (line 1.35).
    public static let liveCaption: Font = .system(size: 24, weight: .medium)
}

/// An sRGB colour with alpha, used for token tables and contrast math independent of SwiftUI.
public struct DSRGBA: Sendable, Hashable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Creates a colour from a `0xRRGGBB` hex value.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255, a: alpha)
    }

    /// The opaque colour obtained by drawing this colour over `background`.
    public func composited(over background: RGB) -> RGB {
        RGB(r * a + background.r * (1 - a), g * a + background.g * (1 - a), b * a + background.b * (1 - a))
    }

    /// Opaque RGB (alpha ignored).
    public var rgb: RGB { RGB(r, g, b) }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// A token with a light and a dark value that resolves with the effective appearance.
public struct DSColorToken: Sendable, Hashable {
    public let light: DSRGBA
    public let dark: DSRGBA

    public init(light: DSRGBA, dark: DSRGBA) {
        self.light = light
        self.dark = dark
    }

    public init(light: UInt32, dark: UInt32) { self.init(light: DSRGBA(hex: light), dark: DSRGBA(hex: dark)) }

    /// Value for an appearance.
    public func value(dark isDark: Bool) -> DSRGBA { isDark ? dark : light }

    /// Adaptive SwiftUI colour (follows light/dark, including per-view `preferredColorScheme`).
    public var color: Color {
        let token = self
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return token.value(dark: isDark).nsColor
            })
    }
}

/// The M8 token table (Handoff 1, section "Colour tokens"). Hex values are authoritative; tests read this table.
public enum DSPalette {
    /// Window background.
    public static let paper = DSColorToken(light: 0xF3EEE5, dark: 0x12110F)
    /// Primary content surface.
    public static let sheet = DSColorToken(light: 0xFCFAF6, dark: 0x1B1A17)
    /// Secondary surface (rows, chips).
    public static let inset = DSColorToken(light: 0xF7F3EB, dark: 0x22211D)
    public static let ink = DSColorToken(light: 0x1C1B18, dark: 0xF3EFE7)
    public static let ink2 = DSColorToken(light: 0x5A564E, dark: 0xB5B0A5)
    /// Tertiary text and labels (AA on sheet).
    public static let ink3 = DSColorToken(light: 0x6B675D, dark: 0x9A9589)
    /// Small tertiary labels keep AA contrast on tinted selections as well as plain sheets.
    public static let tertiaryText = DSColorToken(light: 0x6B675D, dark: 0xA29D92)
    /// Hairline, 1 px. Alpha colour: composite over the surface it sits on.
    public static let line = DSColorToken(
        light: DSRGBA(hex: 0x1C1B18, alpha: 0.12), dark: DSRGBA(hex: 0xF3EFE7, alpha: 0.14))
    /// Stronger hairline for solid twins under Reduce Transparency / Increase Contrast (>= 3:1 on sheet).
    public static let lineStrong = DSColorToken(
        light: DSRGBA(hex: 0x5A564E, alpha: 0.75), dark: DSRGBA(hex: 0xB5B0A5, alpha: 0.75))
    /// Fixed brand accent.
    public static let ember = DSColorToken(light: 0xC44B16, dark: 0xF28A57)
    /// Selected row, chip, karaoke highlight.
    public static let emberTint = DSColorToken(
        light: DSRGBA(hex: 0xF7E4D8), dark: DSRGBA(hex: 0xF28A57, alpha: 0.16))
    public static let recording = DSColorToken(light: 0xD1352B, dark: 0xFF6B5E)
    /// Label on an ember or recording fill: white on the light fills (4.8:1), near-black on the lighter dark fills (about 7:1;
    /// white on dark ember is only 2.5:1).
    public static let onAccent = DSColorToken(light: 0xFFFFFF, dark: 0x1C1B18)
    /// Ember for small text (links, labels, badge numerals): 4.5:1 on paper, sheet, inset and emberTint in light
    /// (4.63 to 5.99). `ember` (#C44B16) stays for fills, icons and text at 24 pt and above. Dark equals `ember`.
    public static let accentText = DSColorToken(light: 0xA83E10, dark: 0xF28A57)
    /// Recording red for small text next to the dot (4.68 to 6.07 on the light surfaces). The dot and fills keep `recording`.
    public static let recordingText = DSColorToken(light: 0xB52A22, dark: 0xFF6B5E)
    public static let success = DSColorToken(light: 0x2F7A4F, dark: 0x6CC48F)
    /// Success text on plain and tinted surfaces; the locked success colour remains available for fills.
    public static let successText = DSColorToken(light: 0x25663F, dark: 0x6CC48F)
    /// Not specified by the boards; amber chosen at T31 to reach 4.5:1 on paper, sheet and inset in both appearances.
    public static let warning = DSColorToken(light: 0x8F5300, dark: 0xE8A93C)
    public static let warningText = DSColorToken(light: 0x7C4400, dark: 0xE8A93C)
    public static let danger = DSColorToken(light: 0xB3321F, dark: 0xFF8A7A)
    /// Sidebar selection pill (Sidebar board): translucent Sheet on the glass sidebar. Ink on it reads as on sheet.
    public static let selectionPill = DSColorToken(
        light: DSRGBA(hex: 0xFFFCF6, alpha: 0.85), dark: DSRGBA(hex: 0xFFFFFF, alpha: 0.10))
    /// Warm shadow colour (apply 7-14 % alpha, 14-24 pt blur).
    public static let shadow = DSColorToken(light: 0x3C2814, dark: 0x000000)
}

/// Semantic color tokens, adaptive to light/dark appearance.
public enum DSColor {
    // MARK: Surfaces
    /// Window background (Paper).
    public static let paper = DSPalette.paper.color
    /// Primary solid surface for content (Sheet): transcripts, cards, inspector, tables.
    public static let contentBackground = DSPalette.sheet.color
    /// Secondary solid surface (Inset): rows, chips, grouped regions.
    public static let insetBackground = DSPalette.inset.color
    /// Solid fallback surface for chrome when glass is disabled (Paper).
    public static let solidChrome = DSPalette.paper.color
    /// Hairline separator / border used on solid surfaces.
    public static let hairline = DSPalette.line.color
    /// Stronger hairline used by solid twins when transparency is reduced or contrast increased.
    public static let hairlineStrong = DSPalette.lineStrong.color
    // MARK: Text
    public static let primaryText = DSPalette.ink.color
    public static let secondaryText = DSPalette.ink2.color
    public static let tertiaryText = DSPalette.tertiaryText.color
    // MARK: Accent and status
    /// Ember, the fixed brand accent. Apply with `.tint(DSColor.accent)` at the root.
    public static let accent = DSPalette.ember.color
    /// Label colour for text and glyphs drawn on an accent or recording fill (see ``DSPalette/onAccent``).
    public static let onAccent = DSPalette.onAccent.color
    /// Alias for ``accent``.
    public static let ember = DSPalette.ember.color
    /// Selected row / chip / karaoke background.
    public static let accentTint = DSPalette.emberTint.color
    /// Ember for small text (links, labels): 4.5:1 on every surface. Use ``accent`` for fills, icons, large text.
    public static let accentText = DSPalette.accentText.color
    /// Recording red. Never Ember.
    public static let recording = DSPalette.recording.color
    /// Recording red for small text (labels beside the recording dot).
    public static let recordingText = DSPalette.recordingText.color
    public static let success = DSPalette.successText.color
    public static let warning = DSPalette.warningText.color
    public static let danger = DSPalette.danger.color
    /// Selected sidebar row pill.
    public static let selectionPill = DSPalette.selectionPill.color
    /// Warm drop shadow colour.
    public static let shadow = DSPalette.shadow.color
}

/// Visual tone of a ``StatusPill``.
public enum DSTone: Sendable, Hashable, CaseIterable {
    case neutral, info, success, warning, danger

    /// Foreground/tint color for the tone.
    public var color: Color {
        switch self {
        case .neutral: DSColor.secondaryText
        case .info: DSColor.accentText
        case .success: DSColor.success
        case .warning: DSColor.warning
        case .danger: DSColor.danger
        }
    }
}
