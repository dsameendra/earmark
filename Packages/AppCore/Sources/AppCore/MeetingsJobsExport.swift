import Foundation

// MARK: - Meetings

public enum MeetingApp: String, Codable, Sendable, CaseIterable {
    case zoom, teams
    public var bundleIDs: [String] {
        switch self {
        case .zoom: ["us.zoom.xos"]
        // New Teams (`teams2`, executable MSTeams) first, then classic Teams. SCR-012.
        case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
        }
    }
}

public enum MeetingEvent: Sendable, Equatable {
    case started(MeetingApp, at: Date)
    case ended(MeetingApp, at: Date)
}

/// Detects meetings via the app's own audio process having mic input and audio output active (debounced).
public protocol MeetingDetector: Sendable {
    func events() -> AsyncStream<MeetingEvent>
}

/// What to do when a meeting is detected. `askFirst` is the default (user sign-off 2026-11-21).
public enum MeetingBehavior: String, Codable, Sendable, CaseIterable {
    case doNothing, askFirst, autoTranscribe, autoTranscribeAndRecord
}

public struct MeetingPolicy: Codable, Sendable, Hashable {
    public var app: MeetingApp
    public var behavior: MeetingBehavior
    public var autoStopGraceSeconds: TimeInterval
    public var recordVideo: Bool
    /// Hours (0...24) during which automatic recording is suppressed, e.g. 22...24.
    public var quietHours: ClosedRange<Int>?
    public var excludedKeywords: [String]
    public init(
        app: MeetingApp, behavior: MeetingBehavior = .askFirst, autoStopGraceSeconds: TimeInterval = 15,
        recordVideo: Bool = false, quietHours: ClosedRange<Int>? = nil, excludedKeywords: [String] = []
    ) {
        self.app = app
        self.behavior = behavior
        self.autoStopGraceSeconds = autoStopGraceSeconds
        self.recordVideo = recordVideo
        self.quietHours = quietHours
        self.excludedKeywords = excludedKeywords
    }
}

public struct Meeting: Codable, Sendable, Hashable, Identifiable {
    public var id: MeetingID
    public var app: MeetingApp
    public var startedAt: Date
    public var endedAt: Date?
    public var transcriptID: TranscriptID?
    public var recording: Recording?
    public var deletedAt: Date?
    public init(
        id: MeetingID = MeetingID(), app: MeetingApp, startedAt: Date, endedAt: Date? = nil,
        transcriptID: TranscriptID? = nil, recording: Recording? = nil, deletedAt: Date? = nil
    ) {
        self.id = id
        self.app = app
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcriptID = transcriptID
        self.recording = recording
        self.deletedAt = deletedAt
    }
}

public struct RecordingTrack: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable { case mic, remote, mix, video }
    public var role: Role
    public var relativePath: String
    public init(role: Role, relativePath: String) {
        self.role = role
        self.relativePath = relativePath
    }
}

public struct Recording: Codable, Sendable, Hashable {
    public var tracks: [RecordingTrack]
    public var duration: TimeInterval
    public init(tracks: [RecordingTrack], duration: TimeInterval = 0) {
        self.tracks = tracks
        self.duration = duration
    }
}

public struct RecordingConfig: Sendable {
    public var directory: URL
    public var separateTracks: Bool
    public var mixTrack: Bool
    public var includeVideo: Bool
    public init(directory: URL, separateTracks: Bool = true, mixTrack: Bool = true, includeVideo: Bool = false) {
        self.directory = directory
        self.separateTracks = separateTracks
        self.mixTrack = mixTrack
        self.includeVideo = includeVideo
    }
}

/// Crash-safe recorder: fragmented writes so a crash leaves usable files. A persistent indicator is shown while active.
public protocol Recorder: Sendable {
    func start(config: RecordingConfig, mic: AsyncStream<AudioChunk>, remote: AsyncStream<AudioChunk>) async throws
    func stop() async throws -> Recording
    var isRecording: Bool { get async }
}

// MARK: - Jobs

public enum JobKind: String, Codable, Sendable { case transcribeFile, retranscribeSegment, translate, finalizeMeeting, export }

public enum JobState: String, Codable, Sendable { case pending, running, paused, failed, completed, cancelled }

/// Journaled checkpoint so a crash or restart resumes from the last chunk.
public struct JobCheckpoint: Codable, Sendable, Hashable {
    public var lastCompletedChunk: Int
    public var mediaTime: TimeInterval
    public init(lastCompletedChunk: Int, mediaTime: TimeInterval) {
        self.lastCompletedChunk = lastCompletedChunk
        self.mediaTime = mediaTime
    }
}

public struct JobSettings: Codable, Sendable, Hashable {
    public var languageMode: LanguageMode
    public var modelID: ModelID?
    public var diarize: Bool
    public var diarization: [String: Int]  // e.g. ["min": 2, "max": 6]; empty = auto
    public var translateTo: LanguageCode?
    public var applyReplacements: Bool
    public var autoExportPresetID: PresetID?
    /// FILE-AC-16: copy the media into the library (library-owned asset) instead of referencing it with a bookmark.
    public var copyIntoLibrary: Bool
    public init(
        languageMode: LanguageMode = .default, modelID: ModelID? = nil, diarize: Bool = false,
        diarization: [String: Int] = [:], translateTo: LanguageCode? = nil, applyReplacements: Bool = true,
        autoExportPresetID: PresetID? = nil, copyIntoLibrary: Bool = false
    ) {
        self.languageMode = languageMode
        self.modelID = modelID
        self.diarize = diarize
        self.diarization = diarization
        self.translateTo = translateTo
        self.applyReplacements = applyReplacements
        self.autoExportPresetID = autoExportPresetID
        self.copyIntoLibrary = copyIntoLibrary
    }

    /// Decodes jobs journaled before `copyIntoLibrary` existed (it defaults to `false`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            languageMode: try c.decode(LanguageMode.self, forKey: .languageMode),
            modelID: try c.decodeIfPresent(ModelID.self, forKey: .modelID), diarize: try c.decode(Bool.self, forKey: .diarize),
            diarization: try c.decode([String: Int].self, forKey: .diarization),
            translateTo: try c.decodeIfPresent(LanguageCode.self, forKey: .translateTo),
            applyReplacements: try c.decode(Bool.self, forKey: .applyReplacements),
            autoExportPresetID: try c.decodeIfPresent(PresetID.self, forKey: .autoExportPresetID),
            copyIntoLibrary: try c.decodeIfPresent(Bool.self, forKey: .copyIntoLibrary) ?? false)
    }
}

/// One file or folder to enqueue with its own settings (FILE-AC-04 per-file overrides).
public struct FileJobRequest: Sendable, Hashable {
    public var url: URL
    public var settings: JobSettings
    public init(url: URL, settings: JobSettings) {
        self.url = url
        self.settings = settings
    }
}

public struct Job: Codable, Sendable, Hashable, Identifiable {
    public var id: JobID
    public var kind: JobKind
    public var state: JobState
    public var input: URL?
    public var transcriptID: TranscriptID?
    public var settings: JobSettings
    public var progress: Double
    public var etaSeconds: TimeInterval?
    public var engine: EngineID?
    public var checkpoint: JobCheckpoint?
    public var failureReason: String?
    public var priority: Int
    public var createdAt: Date
    public var deletedAt: Date?
    public init(
        id: JobID = JobID(), kind: JobKind, state: JobState = .pending, input: URL? = nil, transcriptID: TranscriptID? = nil,
        settings: JobSettings = JobSettings(), progress: Double = 0, etaSeconds: TimeInterval? = nil, engine: EngineID? = nil,
        checkpoint: JobCheckpoint? = nil, failureReason: String? = nil, priority: Int = 0, createdAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.input = input
        self.transcriptID = transcriptID
        self.settings = settings
        self.progress = progress
        self.etaSeconds = etaSeconds
        self.engine = engine
        self.checkpoint = checkpoint
        self.failureReason = failureReason
        self.priority = priority
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}

public enum JobEvent: Sendable {
    case updated(Job)
    case removed(JobID)
}

/// Persistent job queue (implemented as an actor). State is journaled; engine errors become `.failed` with retry.
public protocol JobQueue: Sendable {
    func enqueue(_ job: Job) async throws -> JobID
    func enqueue(files: [URL], settings: JobSettings, recursive: Bool) async throws -> [JobID]
    /// Enqueues files or folders that may each carry their own settings as one batch (FILE-AC-04).
    func enqueue(requests: [FileJobRequest], recursive: Bool) async throws -> [JobID]
    func prioritize(_ id: JobID, to index: Int) async
    func pause(_ id: JobID) async
    func resume(_ id: JobID) async
    func cancel(_ id: JobID) async
    func retry(_ id: JobID) async
    /// Removes queue history only, preserving transcripts and media. Active work is cancelled and joined first.
    func remove(_ id: JobID) async throws
    func setMaxConcurrency(_ n: Int) async
    func jobs() async -> [Job]
    func events() -> AsyncStream<JobEvent>
    /// Re-queues interrupted jobs after launch.
    func resumeInterrupted() async
}

extension JobQueue {
    /// Fallback for adapters without batch support: groups consecutive requests that share settings.
    public func enqueue(requests: [FileJobRequest], recursive: Bool) async throws -> [JobID] {
        var ids: [JobID] = []
        var index = 0
        while index < requests.count {
            let settings = requests[index].settings
            var end = index
            while end < requests.count, requests[end].settings == settings { end += 1 }
            ids += try await enqueue(files: requests[index..<end].map(\.url), settings: settings, recursive: recursive)
            index = end
        }
        return ids
    }

    /// Adapters without persistent queue editing report the unsupported action instead of hiding an item locally.
    public func remove(_ id: JobID) async throws {
        throw AppError.other("Removing queue items is unavailable for this queue.")
    }
}

// MARK: - Export

public enum ExportFormat: String, Codable, Sendable, CaseIterable {
    case txt, markdown, docx, html, pdf, json, csv
    case srt, vtt, ass, sbv, ttml, lrc
}

public enum TranslationExportMode: String, Codable, Sendable { case none, replace, bilingual }
public enum TimestampStyle: Codable, Sendable, Hashable {
    case none, perSegment, perParagraph
    case everyNSeconds(Int)
}

public struct SubtitleConstraints: Codable, Sendable, Hashable {
    public var maxCharsPerLine: Int
    public var maxLinesPerCue: Int
    public var minCueDuration: TimeInterval
    public var maxCueDuration: TimeInterval
    public var minGap: TimeInterval
    public var splitOnPunctuation: Bool
    public init(
        maxCharsPerLine: Int = 42, maxLinesPerCue: Int = 2, minCueDuration: TimeInterval = 1,
        maxCueDuration: TimeInterval = 7, minGap: TimeInterval = 0.08, splitOnPunctuation: Bool = true
    ) {
        self.maxCharsPerLine = maxCharsPerLine
        self.maxLinesPerCue = maxLinesPerCue
        self.minCueDuration = minCueDuration
        self.maxCueDuration = maxCueDuration
        self.minGap = minGap
        self.splitOnPunctuation = splitOnPunctuation
    }
}

public struct ExportOptions: Codable, Sendable, Hashable {
    public var format: ExportFormat
    public var timestamps: TimestampStyle
    public var includeSpeakers: Bool
    public var mergeSameSpeaker: Bool
    public var paragraphGrouping: Bool
    public var translation: TranslationExportMode
    public var translationLanguage: LanguageCode?
    public var includeIgnored: Bool
    public var subtitle: SubtitleConstraints
    public var timeOffset: TimeInterval
    public var timeRange: TimeRange?
    public var fontFamily: String?
    public init(
        format: ExportFormat, timestamps: TimestampStyle = .perSegment, includeSpeakers: Bool = true,
        mergeSameSpeaker: Bool = false, paragraphGrouping: Bool = false, translation: TranslationExportMode = .none,
        translationLanguage: LanguageCode? = nil, includeIgnored: Bool = false, subtitle: SubtitleConstraints = SubtitleConstraints(),
        timeOffset: TimeInterval = 0, timeRange: TimeRange? = nil, fontFamily: String? = nil
    ) {
        self.format = format
        self.timestamps = timestamps
        self.includeSpeakers = includeSpeakers
        self.mergeSameSpeaker = mergeSameSpeaker
        self.paragraphGrouping = paragraphGrouping
        self.translation = translation
        self.translationLanguage = translationLanguage
        self.includeIgnored = includeIgnored
        self.subtitle = subtitle
        self.timeOffset = timeOffset
        self.timeRange = timeRange
        self.fontFamily = fontFamily
    }
}

public struct ExportPreset: Codable, Sendable, Hashable, Identifiable {
    public var id: PresetID
    public var name: String
    public var options: ExportOptions
    public var deletedAt: Date?
    public init(id: PresetID = PresetID(), name: String, options: ExportOptions, deletedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.options = options
        self.deletedAt = deletedAt
    }
}

public struct ExportArtifact: Sendable, Hashable {
    public var suggestedFilename: String
    public var mimeType: String
    public var data: Data
    public init(suggestedFilename: String, mimeType: String, data: Data) {
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        self.data = data
    }
}

public protocol Exporter: Sendable {
    var formats: Set<ExportFormat> { get }
    /// Pure-Swift generation. Respects `includeIgnored`, translation mode and per-cue language.
    func export(_ document: TranscriptDocument, options: ExportOptions) async throws -> ExportArtifact
}
