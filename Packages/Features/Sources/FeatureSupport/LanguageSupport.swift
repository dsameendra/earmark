import AppCore
import Foundation

// Seams between the UI and the language/translation runtimes. The Features package depends on AppCore only, so the
// composition root fills these in with the Transcription and Translation packages.

/// Re-runs ASR for one segment's time range with a user-chosen language (EDIT-AC-09, LANG-AC-08). The engine is chosen for
/// the *new* language (Sinhala goes to the Sinhala model), never the segment's old one.
public protocol SegmentRetranscriptionService: Sendable {
    /// - Returns: the segment with its new text, words, language and confidence; identity, speaker and time range kept.
    /// - Throws: `AppError` (for example `modelNotInstalled` when the engine for `language` still has to be downloaded).
    func retranscribe(segment: Segment, mediaURL: URL, language: LanguageCode) async throws -> Segment
}

/// What is missing before a translation pair can run (TRN-AC-03, TRN-AC-15).
public enum TranslationReadiness: Sendable, Equatable {
    case ready
    /// A translation model must be downloaded first (NLLB). Show size and licence, then `ModelManaging.ensureAvailable`.
    case needsModel(ModelID)
    /// Apple's on-device language pack must be installed through the system download sheet.
    case needsApplePack(source: LanguageCode, target: LanguageCode)
    /// Cannot be translated in this build or on this Mac; the reason is shown to the user.
    case unavailable(reason: String)
}

/// Translation availability and one-time preparation (language packs) for the UI.
public protocol TranslationPreparing: Sendable {
    /// Languages that can be offered as a target for `source`, with the pair's readiness (unavailable ones carry a reason).
    func targets(from source: LanguageCode) async -> [(language: LanguageCode, readiness: TranslationReadiness)]
    func readiness(source: LanguageCode, target: LanguageCode) async -> TranslationReadiness
    /// Installs Apple's language pack for the pair via the system download flow. Returns `true` when the pair is now ready.
    func prepareApplePack(source: LanguageCode, target: LanguageCode) async -> Bool
}

/// The previous content of a segment replaced by re-transcription (LANG-AC-08 "keeping a revision"). Persisted per
/// transcript in the settings store because `Segment` has no revision field.
public struct SegmentRevision: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var segmentID: SegmentID
    public var text: String
    public var languageCode: LanguageCode?
    public var replacedAt: Date
    public var reason: String
    public init(
        id: UUID = UUID(), segmentID: SegmentID, text: String, languageCode: LanguageCode?, replacedAt: Date = Date(),
        reason: String = "Re-transcribed"
    ) {
        self.id = id
        self.segmentID = segmentID
        self.text = text
        self.languageCode = languageCode
        self.replacedAt = replacedAt
        self.reason = reason
    }
}

/// How a transcript shows translations in the Editor (TRN-AC-08). Raw values match `EarmarkTranslation.TranslationViewMode`.
public enum TranslationDisplayMode: String, Codable, Sendable, CaseIterable, Hashable {
    case original, translated, bilingual
    public var title: String {
        switch self {
        case .original: "Original"
        case .translated: "Translated"
        case .bilingual: "Bilingual"
        }
    }
}

/// The per-transcript translation view choice, persisted by the Editor.
public struct TranslationDisplayChoice: Codable, Sendable, Hashable {
    public var mode: TranslationDisplayMode
    public var target: LanguageCode?
    public init(mode: TranslationDisplayMode = .original, target: LanguageCode? = nil) {
        self.mode = mode
        self.target = target
    }
}

/// Segment language certainty (LANG-AC-06, LANG-AC-05). Only transcripts that contain more than one language are judged:
/// in a single-language transcript the engine stamps the language without identifying it, so a missing confidence says
/// nothing there.
public enum LanguageCertainty {
    public static let threshold = 0.5

    public static func isUncertain(_ segment: Segment, in transcriptLanguages: Set<LanguageCode>) -> Bool {
        guard segment.languageCode != nil, transcriptLanguages.count > 1 else { return false }
        guard let confidence = segment.languageConfidence else { return true }
        return confidence < threshold
    }
}

/// Which translations the UI should flag as weak (TRN-AC-07). The stored `SegmentTranslation` carries no confidence flag,
/// so it is derived from the engine and target the same way the Translation package does.
public enum TranslationConfidence {
    public static func isLow(engine: EngineID, target: LanguageCode) -> Bool {
        target.primary == .sinhala && (engine.rawValue == "nllb" || engine.rawValue.hasPrefix("pivot:"))
    }
}
