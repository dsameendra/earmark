import Foundation
import os

// MARK: - Typed identifiers

/// A strongly typed identifier. The phantom `Tag` prevents mixing, e.g., a `TranscriptID` with a `SpeakerID`.
public struct ID<Tag>: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue.uuidString }
}

public enum TranscriptTag: Sendable {}
public enum SegmentTag: Sendable {}
public enum SpeakerTag: Sendable {}
public enum VoiceProfileTag: Sendable {}
public enum MediaAssetTag: Sendable {}
public enum JobTag: Sendable {}
public enum MeetingTag: Sendable {}
public enum FolderTag: Sendable {}
public enum TagTag: Sendable {}
public enum RuleTag: Sendable {}
public enum PresetTag: Sendable {}
public enum BookmarkTag: Sendable {}
public enum AttachmentTag: Sendable {}
public enum ChatMessageTag: Sendable {}
public enum NotesVersionTag: Sendable {}

public typealias TranscriptID = ID<TranscriptTag>
public typealias SegmentID = ID<SegmentTag>
public typealias SpeakerID = ID<SpeakerTag>
public typealias VoiceProfileID = ID<VoiceProfileTag>
public typealias MediaAssetID = ID<MediaAssetTag>
public typealias JobID = ID<JobTag>
public typealias MeetingID = ID<MeetingTag>
public typealias FolderID = ID<FolderTag>
public typealias LabelID = ID<TagTag>
public typealias RuleID = ID<RuleTag>
public typealias PresetID = ID<PresetTag>
public typealias BookmarkID = ID<BookmarkTag>
public typealias AttachmentID = ID<AttachmentTag>
public typealias ChatMessageID = ID<ChatMessageTag>
public typealias NotesVersionID = ID<NotesVersionTag>

/// Stable string identifier for an engine implementation (e.g. `"apple.speech"`, `"whisperkit"`).
public struct EngineID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// Stable string identifier for a downloadable or system model (e.g. `"whisperkit/large-v3-v20240930_626MB"`).
public struct ModelID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

// MARK: - Time

/// A half-open time range in seconds on a media timeline.
public struct TimeRange: Hashable, Codable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
    public var duration: TimeInterval { max(0, end - start) }
    /// Length of the overlap with `other` (0 when disjoint).
    public func overlap(with other: TimeRange) -> TimeInterval {
        max(0, min(end, other.end) - max(start, other.start))
    }
}

// MARK: - Languages

/// A BCP-47-ish language code such as `"en"`, `"si"`, `"en-US"`.
public struct LanguageCode: Hashable, Codable, Sendable, ExpressibleByStringLiteral, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
    /// Primary subtag (`"en-US"` → `"en"`).
    public var primary: LanguageCode { LanguageCode(String(rawValue.split(separator: "-").first ?? "")) }

    public static let english: LanguageCode = "en"
    public static let sinhala: LanguageCode = "si"
}

/// A language-identification result.
public struct LanguageScore: Hashable, Codable, Sendable {
    public var language: LanguageCode
    public var probability: Double
    public init(language: LanguageCode, probability: Double) {
        self.language = language
        self.probability = probability
    }
}

/// How the language(s) of a job or live session are chosen.
public enum LanguageMode: Hashable, Codable, Sendable {
    /// Fixed single language (fastest, most accurate).
    case single(LanguageCode)
    /// Detect one language from roughly the first 30 s.
    case autoDetect
    /// Per-VAD-segment language ID restricted to this set (code-switching).
    case multilingual(Set<LanguageCode>)

    /// App default: English.
    public static let `default`: LanguageMode = .single(.english)
}

// MARK: - Errors

/// Errors surfaced across module boundaries. Engines map internal failures into these; none may crash the app.
public enum AppError: Error, Sendable, Equatable {
    case cancelled
    case modelNotInstalled(ModelID)
    case modelDownloadFailed(ModelID, reason: String)
    case checksumMismatch(ModelID)
    case unsupportedLanguage(LanguageCode)
    case unsupportedFormat(String)
    case engineFailure(EngineID, reason: String)
    case permissionDenied(PermissionKind)
    case captureSilent(reason: String)
    case deviceUnavailable
    case mediaMissing(MediaAssetID)
    case persistence(reason: String)
    case exportFailed(reason: String)
    case outOfMemory
    case other(String)
}

// MARK: - Logging

/// Central `os.Logger` factory so every module logs under the same subsystem.
public enum AppLog {
    public static let subsystem = "lk.dumindu.earmark"
    public static func logger(_ category: String) -> Logger { Logger(subsystem: subsystem, category: category) }
}
