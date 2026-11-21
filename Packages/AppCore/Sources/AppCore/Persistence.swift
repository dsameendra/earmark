import Foundation

public enum LibrarySort: String, Codable, Sendable { case createdDesc, createdAsc, titleAsc, durationDesc, modifiedDesc }

public struct LibraryQuery: Sendable, Hashable {
    public var text: String?
    public var sources: Set<TranscriptSource>
    public var languages: Set<LanguageCode>
    public var folderID: FolderID?
    public var tags: Set<String>
    public var dateRange: ClosedRange<Date>?
    public var durationRange: ClosedRange<TimeInterval>?
    public var sort: LibrarySort
    /// `true` lists only soft-deleted items (Recently Deleted).
    public var deletedOnly: Bool
    public var limit: Int?
    public init(
        text: String? = nil, sources: Set<TranscriptSource> = [], languages: Set<LanguageCode> = [], folderID: FolderID? = nil,
        tags: Set<String> = [], dateRange: ClosedRange<Date>? = nil, durationRange: ClosedRange<TimeInterval>? = nil,
        sort: LibrarySort = .createdDesc, deletedOnly: Bool = false, limit: Int? = nil
    ) {
        self.text = text
        self.sources = sources
        self.languages = languages
        self.folderID = folderID
        self.tags = tags
        self.dateRange = dateRange
        self.durationRange = durationRange
        self.sort = sort
        self.deletedOnly = deletedOnly
        self.limit = limit
    }
}

public struct SearchHit: Sendable, Hashable {
    public var transcriptID: TranscriptID
    public var segmentID: SegmentID
    public var snippet: String
    public var time: TimeInterval
    public init(transcriptID: TranscriptID, segmentID: SegmentID, snippet: String, time: TimeInterval) {
        self.transcriptID = transcriptID
        self.segmentID = segmentID
        self.snippet = snippet
        self.time = time
    }
}

/// Library storage (GRDB + FTS5, ADR-001). Every user-facing entity soft-deletes via `deletedAt`.
public protocol TranscriptRepository: Sendable {
    func list(_ query: LibraryQuery) async throws -> [Transcript]
    func transcript(_ id: TranscriptID) async throws -> Transcript?
    func save(_ transcript: Transcript) async throws
    func segments(for id: TranscriptID) async throws -> [Segment]
    /// Incremental persistence per chunk (crash-safe).
    func upsertSegments(_ segments: [Segment], for id: TranscriptID) async throws
    func replaceSegments(_ segments: [Segment], for id: TranscriptID) async throws
    func search(_ text: String, limit: Int) async throws -> [SearchHit]
    func softDelete(_ ids: [TranscriptID], at date: Date) async throws
    func restore(_ ids: [TranscriptID]) async throws
    func purge(_ ids: [TranscriptID]) async throws
    /// Permanently removes items soft-deleted before `date` (Recently Deleted retention, default 30 days).
    func purgeDeleted(before date: Date) async throws -> Int
    func bookmarks(for id: TranscriptID) async throws -> [TranscriptBookmark]
    func save(_ bookmark: TranscriptBookmark) async throws
}

public protocol MediaRepository: Sendable {
    func asset(_ id: MediaAssetID) async throws -> MediaAsset?
    func save(_ asset: MediaAsset) async throws
    func softDelete(_ id: MediaAssetID) async throws
}

public protocol JobRepository: Sendable {
    func allJobs() async throws -> [Job]
    func save(_ job: Job) async throws
    func remove(_ id: JobID) async throws
}

public protocol RuleRepository: Sendable {
    func ignoreRules() async throws -> [IgnoreRule]
    func saveIgnoreRule(_ rule: IgnoreRule) async throws
    func removeIgnoreRule(_ id: RuleID) async throws
    func replaceAllIgnoreRules(_ rules: [IgnoreRule]) async throws  // import / restore defaults
    func replacementRules() async throws -> [ReplacementRule]
    func saveReplacementRule(_ rule: ReplacementRule) async throws
    func removeReplacementRule(_ id: RuleID) async throws
}

public protocol PresetRepository: Sendable {
    func captionPresets() async throws -> [CaptionPreset]
    func save(_ preset: CaptionPreset) async throws
    func exportPresets() async throws -> [ExportPreset]
    func save(_ preset: ExportPreset) async throws
    func softDeletePreset(_ id: PresetID) async throws
}

public protocol VoiceProfileRepository: Sendable {
    func profiles() async throws -> [VoiceProfile]
    func save(_ profile: VoiceProfile) async throws
    func softDelete(_ id: VoiceProfileID) async throws
}

public protocol MeetingRepository: Sendable {
    func meetings() async throws -> [Meeting]
    func save(_ meeting: Meeting) async throws
    func softDelete(_ id: MeetingID) async throws
}

public protocol DictationHistoryRepository: Sendable {
    func recent(limit: Int, matching: String?) async throws -> [DictationEntry]
    func save(_ entry: DictationEntry) async throws
    func clear() async throws
}

/// Typed settings store (global defaults; per-feature overrides live under keys).
public protocol SettingsStore: Sendable {
    func value<T: Codable & Sendable>(for key: String, as: T.Type) async -> T?
    func set<T: Codable & Sendable>(_ value: T, for key: String) async
    func changes(for key: String) -> AsyncStream<Void>
}
