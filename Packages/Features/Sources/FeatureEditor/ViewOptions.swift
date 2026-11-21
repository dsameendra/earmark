import AppCore
import Foundation

/// How the transcript is laid out (EDIT-AC-14).
public enum TranscriptLayoutMode: String, Codable, Sendable, CaseIterable {
    case segments, paragraphs
    public var title: String { self == .segments ? "Segments" : "Paragraphs" }
}

/// Vertical spacing between rows.
public enum TranscriptDensity: String, Codable, Sendable, CaseIterable {
    case compact, regular, spacious
    public var title: String { rawValue.capitalized }
    public var rowPadding: Double {
        switch self {
        case .compact: 3
        case .regular: 8
        case .spacious: 14
        }
    }
}

/// Appearance options for the transcript area. Stored as a global default plus optional per-transcript overrides.
public struct ViewOptions: Codable, Sendable, Hashable {
    public var layout: TranscriptLayoutMode = .segments
    /// Font family name; nil is the system font (with the Sinhala cascade).
    public var fontFamily: String?
    public var fontSize: Double = 15
    public var lineSpacing: Double = 4
    public var showTimestamps = true
    public var showSpeakers = true
    public var showLanguageBadges = true
    public var density: TranscriptDensity = .regular
    /// Underline words below the low-confidence threshold.
    public var underlineLowConfidence = false

    public init() {}

    public static let fontSizeRange: ClosedRange<Double> = 10...32
    public static let lineSpacingRange: ClosedRange<Double> = 0...16
    /// Words with confidence below this are underlined when ``underlineLowConfidence`` is on.
    public static let lowConfidenceThreshold = 0.5
}

/// Per-transcript overrides: only the fields that differ from the global defaults (EDIT-AC-14).
public struct ViewOptionsOverride: Codable, Sendable, Hashable {
    public var layout: TranscriptLayoutMode?
    /// Double-optional encoded as `fontFamilySet` + value so "system font" can be an explicit override.
    public var fontFamilySet: Bool?
    public var fontFamily: String?
    public var fontSize: Double?
    public var lineSpacing: Double?
    public var showTimestamps: Bool?
    public var showSpeakers: Bool?
    public var showLanguageBadges: Bool?
    public var density: TranscriptDensity?
    public var underlineLowConfidence: Bool?

    public init() {}

    /// `base` with the overridden fields applied.
    public func applied(to base: ViewOptions) -> ViewOptions {
        var out = base
        if let layout { out.layout = layout }
        if fontFamilySet == true { out.fontFamily = fontFamily }
        if let fontSize { out.fontSize = fontSize }
        if let lineSpacing { out.lineSpacing = lineSpacing }
        if let showTimestamps { out.showTimestamps = showTimestamps }
        if let showSpeakers { out.showSpeakers = showSpeakers }
        if let showLanguageBadges { out.showLanguageBadges = showLanguageBadges }
        if let density { out.density = density }
        if let underlineLowConfidence { out.underlineLowConfidence = underlineLowConfidence }
        return out
    }

    /// The override that turns `global` into `effective` (fields that are equal stay nil).
    public static func difference(from global: ViewOptions, to effective: ViewOptions) -> ViewOptionsOverride {
        var out = ViewOptionsOverride()
        if effective.layout != global.layout { out.layout = effective.layout }
        if effective.fontFamily != global.fontFamily {
            out.fontFamilySet = true
            out.fontFamily = effective.fontFamily
        }
        if effective.fontSize != global.fontSize { out.fontSize = effective.fontSize }
        if effective.lineSpacing != global.lineSpacing { out.lineSpacing = effective.lineSpacing }
        if effective.showTimestamps != global.showTimestamps { out.showTimestamps = effective.showTimestamps }
        if effective.showSpeakers != global.showSpeakers { out.showSpeakers = effective.showSpeakers }
        if effective.showLanguageBadges != global.showLanguageBadges { out.showLanguageBadges = effective.showLanguageBadges }
        if effective.density != global.density { out.density = effective.density }
        if effective.underlineLowConfidence != global.underlineLowConfidence {
            out.underlineLowConfidence = effective.underlineLowConfidence
        }
        return out
    }
}

/// `SettingsStore` keys owned by the editor.
public enum EditorSettingsKey {
    public static let globalViewOptions = "editor.viewOptions"
    public static let showIgnored = "editor.showIgnored"
    public static let playbackSpeed = "editor.playbackSpeed"
    public static let showWaveform = "editor.showWaveform"
    public static func viewOptionsOverride(_ id: TranscriptID) -> String { "editor.viewOptions.override.\(id)" }
    public static func highlights(_ id: TranscriptID) -> String { "editor.highlights.\(id)" }
}

/// A coloured highlight over a run of words with an optional note (EDIT-AC-13). Stored in `SettingsStore` because
/// `TranscriptBookmark` carries only a time.
public struct TextHighlight: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var segmentID: SegmentID
    /// Inclusive word range; nil covers the whole segment.
    public var wordRange: ClosedRange<Int>?
    public var note: String
    public var colorName: String
    public var time: TimeInterval
    public init(
        id: UUID = UUID(), segmentID: SegmentID, wordRange: ClosedRange<Int>? = nil, note: String = "",
        colorName: String = "yellow", time: TimeInterval
    ) {
        self.id = id
        self.segmentID = segmentID
        self.wordRange = wordRange
        self.note = note
        self.colorName = colorName
        self.time = time
    }
}
