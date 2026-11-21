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

/// Corner radius scale in points.
public enum DSRadius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large: CGFloat = 16
    public static let pill: CGFloat = 999
}

/// Typography tokens. All use system text styles so Dynamic Type-style scaling and Sinhala cascade work.
public enum DSTypography {
    public static let title: Font = .title2.weight(.semibold)
    public static let headline: Font = .headline
    public static let body: Font = .body
    public static let caption: Font = .caption
    public static let badge: Font = .caption2.weight(.semibold)
    public static let timestamp: Font = .caption.monospacedDigit()
}

/// Semantic color tokens, adaptive to light/dark appearance.
public enum DSColor {
    /// Solid surface for content areas (transcripts, editors).
    public static let contentBackground = Color(nsColor: .textBackgroundColor)
    /// Solid fallback surface for chrome when glass is disabled.
    public static let solidChrome = Color(nsColor: .windowBackgroundColor)
    /// Hairline separator / border used on solid fallbacks.
    public static let hairline = Color(nsColor: .separatorColor)
    public static let primaryText = Color(nsColor: .labelColor)
    public static let secondaryText = Color(nsColor: .secondaryLabelColor)
    /// Recording red.
    public static let recording = Color(nsColor: .systemRed)
    public static let success = Color(nsColor: .systemGreen)
    public static let warning = Color(nsColor: .systemOrange)
    public static let danger = Color(nsColor: .systemRed)
    public static let accent = Color.accentColor
}

/// Visual tone of a ``StatusPill``.
public enum DSTone: Sendable, Hashable, CaseIterable {
    case neutral, info, success, warning, danger

    /// Foreground/tint color for the tone.
    public var color: Color {
        switch self {
        case .neutral: DSColor.secondaryText
        case .info: DSColor.accent
        case .success: DSColor.success
        case .warning: DSColor.warning
        case .danger: DSColor.danger
        }
    }
}
