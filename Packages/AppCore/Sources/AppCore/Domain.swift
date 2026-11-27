import Foundation

// MARK: - Transcript domain

/// A word with timing, kept for click-to-seek and karaoke highlighting.
public struct Word: Hashable, Codable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Double?
    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// A translation of a segment into one target language (stored as a parallel track).
public struct SegmentTranslation: Hashable, Codable, Sendable {
    public var language: LanguageCode
    public var text: String
    public var engine: EngineID
    public init(language: LanguageCode, text: String, engine: EngineID) {
        self.language = language
        self.text = text
        self.engine = engine
    }
}

/// A transcript segment. Ignored segments are flagged (`isIgnored`), never deleted.
public struct Segment: Hashable, Codable, Sendable, Identifiable {
    public var id: SegmentID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var speakerID: SpeakerID?
    public var languageCode: LanguageCode?
    public var languageConfidence: Double?
    public var confidence: Double?
    /// Whisper-style no-speech probability, used by the hallucination filter.
    public var noSpeechProbability: Double?
    public var isIgnored: Bool
    /// `true` when the user set `isIgnored` by hand (either way). Re-deriving ignore flags after a rule change keeps such
    /// segments exactly as the user left them (IGN-AC-05).
    public var ignoreFlagIsManual: Bool
    /// SCR-013: `true` once the user edited the text (or corrected language/speaker by hand). A non-destructive re-transcribe
    /// keeps such segments exactly as the user left them.
    public var isUserEdited: Bool
    public var words: [Word]
    public var translations: [SegmentTranslation]

    public init(
        id: SegmentID = SegmentID(), start: TimeInterval, end: TimeInterval, text: String,
        speakerID: SpeakerID? = nil, languageCode: LanguageCode? = nil, languageConfidence: Double? = nil,
        confidence: Double? = nil, noSpeechProbability: Double? = nil, isIgnored: Bool = false,
        ignoreFlagIsManual: Bool = false, isUserEdited: Bool = false, words: [Word] = [],
        translations: [SegmentTranslation] = []
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.speakerID = speakerID
        self.languageCode = languageCode
        self.languageConfidence = languageConfidence
        self.confidence = confidence
        self.noSpeechProbability = noSpeechProbability
        self.isIgnored = isIgnored
        self.ignoreFlagIsManual = ignoreFlagIsManual
        self.isUserEdited = isUserEdited
        self.words = words
        self.translations = translations
    }

    /// Decodes data written before `ignoreFlagIsManual` existed (it defaults to `false`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(SegmentID.self, forKey: .id), start: try c.decode(TimeInterval.self, forKey: .start),
            end: try c.decode(TimeInterval.self, forKey: .end), text: try c.decode(String.self, forKey: .text),
            speakerID: try c.decodeIfPresent(SpeakerID.self, forKey: .speakerID),
            languageCode: try c.decodeIfPresent(LanguageCode.self, forKey: .languageCode),
            languageConfidence: try c.decodeIfPresent(Double.self, forKey: .languageConfidence),
            confidence: try c.decodeIfPresent(Double.self, forKey: .confidence),
            noSpeechProbability: try c.decodeIfPresent(Double.self, forKey: .noSpeechProbability),
            isIgnored: try c.decode(Bool.self, forKey: .isIgnored),
            ignoreFlagIsManual: try c.decodeIfPresent(Bool.self, forKey: .ignoreFlagIsManual) ?? false,
            isUserEdited: try c.decodeIfPresent(Bool.self, forKey: .isUserEdited) ?? false,
            words: try c.decode([Word].self, forKey: .words),
            translations: try c.decode([SegmentTranslation].self, forKey: .translations))
    }
    public var range: TimeRange { TimeRange(start: start, end: end) }
}

public struct Speaker: Hashable, Codable, Sendable, Identifiable {
    public var id: SpeakerID
    public var name: String
    public var colorHex: String
    public var voiceProfileID: VoiceProfileID?
    public init(id: SpeakerID = SpeakerID(), name: String, colorHex: String, voiceProfileID: VoiceProfileID? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.voiceProfileID = voiceProfileID
    }
}

public enum TranscriptSource: String, Codable, Sendable, CaseIterable {
    case file, meeting, liveCaptions, dictation
}

/// Transcript header. Segments are loaded separately (`TranscriptRepository.segments`) so list views stay fast.
public struct Transcript: Hashable, Codable, Sendable, Identifiable {
    public var id: TranscriptID
    public var title: String
    public var source: TranscriptSource
    public var duration: TimeInterval
    public var languages: Set<LanguageCode>
    public var speakers: [Speaker]
    public var tags: [String]
    public var folderID: FolderID?
    public var mediaAssetID: MediaAssetID?
    public var meetingID: MeetingID?
    /// Set when this transcript is a re-transcription revision of another.
    public var revisionOf: TranscriptID?
    public var createdAt: Date
    public var modifiedAt: Date
    /// Non-nil means soft-deleted (Recently Deleted).
    public var deletedAt: Date?
    /// Non-nil means pinned to the sidebar; the value is the position among pinned items (SCR-018).
    public var pinOrder: Int?

    public init(
        id: TranscriptID = TranscriptID(), title: String, source: TranscriptSource, duration: TimeInterval = 0,
        languages: Set<LanguageCode> = [], speakers: [Speaker] = [], tags: [String] = [], folderID: FolderID? = nil,
        mediaAssetID: MediaAssetID? = nil, meetingID: MeetingID? = nil, revisionOf: TranscriptID? = nil,
        createdAt: Date = Date(), modifiedAt: Date = Date(), deletedAt: Date? = nil, pinOrder: Int? = nil
    ) {
        self.pinOrder = pinOrder
        self.id = id
        self.title = title
        self.source = source
        self.duration = duration
        self.languages = languages
        self.speakers = speakers
        self.tags = tags
        self.folderID = folderID
        self.mediaAssetID = mediaAssetID
        self.meetingID = meetingID
        self.revisionOf = revisionOf
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.deletedAt = deletedAt
    }
}

/// A transcript with its content, as passed to exporters and the editor.
public struct TranscriptDocument: Hashable, Codable, Sendable {
    public var transcript: Transcript
    public var segments: [Segment]
    public init(transcript: Transcript, segments: [Segment]) {
        self.transcript = transcript
        self.segments = segments
    }
}

public struct MediaAsset: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case audio, video }
    public var id: MediaAssetID
    public var kind: Kind
    /// Security-scoped bookmark data for referenced (not copied) media.
    public var bookmark: Data?
    public var libraryRelativePath: String?
    public var duration: TimeInterval
    public var isOwnedByLibrary: Bool
    public var deletedAt: Date?
    public init(
        id: MediaAssetID = MediaAssetID(), kind: Kind, bookmark: Data? = nil, libraryRelativePath: String? = nil,
        duration: TimeInterval = 0, isOwnedByLibrary: Bool = false, deletedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.bookmark = bookmark
        self.libraryRelativePath = libraryRelativePath
        self.duration = duration
        self.isOwnedByLibrary = isOwnedByLibrary
        self.deletedAt = deletedAt
    }
}

public struct TranscriptBookmark: Hashable, Codable, Sendable, Identifiable {
    public var id: BookmarkID
    public var transcriptID: TranscriptID
    public var time: TimeInterval
    public var note: String
    public var createdAt: Date
    public var deletedAt: Date?
    public init(
        id: BookmarkID = BookmarkID(), transcriptID: TranscriptID, time: TimeInterval, note: String = "",
        createdAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id
        self.transcriptID = transcriptID
        self.time = time
        self.note = note
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}

// MARK: - Rules and presets

public enum RuleMatch: String, Codable, Sendable, CaseIterable { case exact, contains, regex }
public enum RuleScope: String, Codable, Sendable, CaseIterable { case wholeSegment, inline }

/// An ignored-segment rule. Hallucination-list rules only apply when confidence is low (see `PostProcessingContext`).
public struct IgnoreRule: Hashable, Codable, Sendable, Identifiable {
    public var id: RuleID
    public var pattern: String
    public var match: RuleMatch
    public var scope: RuleScope
    public var isEnabled: Bool
    public var isHallucinationRule: Bool
    public var deletedAt: Date?
    public init(
        id: RuleID = RuleID(), pattern: String, match: RuleMatch = .exact, scope: RuleScope = .wholeSegment,
        isEnabled: Bool = true, isHallucinationRule: Bool = false, deletedAt: Date? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.match = match
        self.scope = scope
        self.isEnabled = isEnabled
        self.isHallucinationRule = isHallucinationRule
        self.deletedAt = deletedAt
    }
}

public struct ReplacementRule: Hashable, Codable, Sendable, Identifiable {
    public var id: RuleID
    public var find: String
    public var replacement: String
    public var matchCase: Bool
    public var wholeWord: Bool
    public var isRegex: Bool
    public var isEnabled: Bool
    public var deletedAt: Date?
    public init(
        id: RuleID = RuleID(), find: String, replacement: String, matchCase: Bool = false, wholeWord: Bool = false,
        isRegex: Bool = false, isEnabled: Bool = true, deletedAt: Date? = nil
    ) {
        self.id = id
        self.find = find
        self.replacement = replacement
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.isRegex = isRegex
        self.isEnabled = isEnabled
        self.deletedAt = deletedAt
    }
}

/// A saved live-caption overlay appearance.
public struct CaptionPreset: Hashable, Codable, Sendable, Identifiable {
    public enum Background: String, Codable, Sendable { case liquidGlass, solid, none }
    public enum Alignment: String, Codable, Sendable { case leading, center, trailing }
    public var id: PresetID
    public var name: String
    public var fontFamily: String?
    public var fontSize: Double
    public var fontWeight: Double
    public var textColorHex: String
    public var background: Background
    public var backgroundOpacity: Double
    public var cornerRadius: Double
    /// 1...6
    public var visibleLines: Int
    public var maxWidth: Double
    public var alignment: Alignment
    public var textOutline: Bool
    public var showSpeakerLabels: Bool
    public var showLanguageBadge: Bool
    public var showTranslation: Bool
    public var translatedOnly: Bool
    public var autoHideAfterSilence: TimeInterval?
    public var isBuiltIn: Bool
    public var deletedAt: Date?
    public init(
        id: PresetID = PresetID(), name: String, fontFamily: String? = nil, fontSize: Double = 28, fontWeight: Double = 0.4,
        textColorHex: String = "#FFFFFF", background: Background = .liquidGlass, backgroundOpacity: Double = 0.8,
        cornerRadius: Double = 16, visibleLines: Int = 2, maxWidth: Double = 900, alignment: Alignment = .center,
        textOutline: Bool = false, showSpeakerLabels: Bool = true, showLanguageBadge: Bool = false,
        showTranslation: Bool = false, translatedOnly: Bool = false, autoHideAfterSilence: TimeInterval? = 6,
        isBuiltIn: Bool = false, deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.textColorHex = textColorHex
        self.background = background
        self.backgroundOpacity = backgroundOpacity
        self.cornerRadius = cornerRadius
        self.visibleLines = visibleLines
        self.maxWidth = maxWidth
        self.alignment = alignment
        self.textOutline = textOutline
        self.showSpeakerLabels = showSpeakerLabels
        self.showLanguageBadge = showLanguageBadge
        self.showTranslation = showTranslation
        self.translatedOnly = translatedOnly
        self.autoHideAfterSilence = autoHideAfterSilence
        self.isBuiltIn = isBuiltIn
        self.deletedAt = deletedAt
    }
}

public struct DictationEntry: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var language: LanguageCode?
    public var createdAt: Date
    public var deletedAt: Date?
    public init(id: UUID = UUID(), text: String, language: LanguageCode? = nil, createdAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.language = language
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}
