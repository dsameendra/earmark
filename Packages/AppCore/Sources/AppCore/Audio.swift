import Foundation

// MARK: - Audio

/// Where an audio chunk came from. Meetings use `.mic` (labelled "You") and `.system`/`.app` (diarized).
public enum AudioSourceTag: Hashable, Codable, Sendable {
    case mic(deviceUID: String?)
    case system
    case app(bundleID: String)
    case mixed
    case file
}

/// A block of 16 kHz mono Float32 audio. This is the single audio currency between modules.
public struct AudioChunk: Sendable {
    public static let sampleRate: Double = 16_000
    public var samples: [Float]
    /// `mach_absolute_time`-style host time of the first sample (0 for file input).
    public var hostTime: UInt64
    /// Seconds from the start of the session/file to the first sample.
    public var startSeconds: TimeInterval
    public var source: AudioSourceTag
    public init(samples: [Float], hostTime: UInt64 = 0, startSeconds: TimeInterval, source: AudioSourceTag) {
        self.samples = samples
        self.hostTime = hostTime
        self.startSeconds = startSeconds
        self.source = source
    }
    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
}

public struct AudioDevice: Hashable, Codable, Sendable, Identifiable {
    public var id: String  // Core Audio device UID
    public var name: String
    public var isInput: Bool
    public var isOutput: Bool
    public var isBluetooth: Bool
    /// "Built-in", "USB", "Bluetooth", "Aggregate", "Virtual" and so on; `nil` when unknown. Used to tell same-named devices apart.
    public var transportLabel: String?
    public init(id: String, name: String, isInput: Bool, isOutput: Bool, isBluetooth: Bool = false, transportLabel: String? = nil) {
        self.transportLabel = transportLabel
        self.id = id
        self.name = name
        self.isInput = isInput
        self.isOutput = isOutput
        self.isBluetooth = isBluetooth
    }
}

/// A live audio producer (mic, system tap, app tap). Real-time threads hand off via lock-free ring buffers internally;
/// consumers only ever see this stream. Streams are bounded (`bufferingNewest`) and never block capture.
public protocol AudioSource: Sendable {
    var tag: AudioSourceTag { get }
    /// Starts capture. Throws `AppError.permissionDenied` / `.deviceUnavailable`. Emits `AppError.captureSilent`
    /// through `health` if only zero buffers arrive (silent TCC denial).
    func start() async throws -> AsyncStream<AudioChunk>
    func stop() async
    /// Linear 0...1 input level for meters.
    var levels: AsyncStream<Float> { get }
    var health: AsyncStream<AudioSourceHealth> { get }
}

public enum AudioSourceHealth: Sendable, Equatable {
    case running
    case silent  // all-zero buffers (possible silent permission denial)
    case deviceChanged(to: String?)  // route change / hot-plug, fell back to default
    case stopped
}

public protocol AudioDeviceProviding: Sendable {
    func devices() async -> [AudioDevice]
    func defaultInput() async -> AudioDevice?
    /// Emits whenever the device list or defaults change.
    func changes() -> AsyncStream<Void>
    /// True when the default output is headphones (Bluetooth or the headphone jack): the mic will not hear system audio.
    func defaultOutputLooksLikeHeadphones() async -> Bool
}

extension AudioDeviceProviding {
    /// Providers that cannot tell assume speakers, the safer reading for the echo hint.
    public func defaultOutputLooksLikeHeadphones() async -> Bool { false }
}

/// Decodes any AVFoundation-readable file into 16 kHz mono Float32 chunks with bounded memory.
public protocol AudioFileDecoder: Sendable {
    func decode(file: URL, chunkSeconds: TimeInterval, startingAt: TimeInterval) -> AsyncThrowingStream<AudioChunk, any Error>
    func duration(of file: URL) async throws -> TimeInterval
}

/// Voice-activity detection used for chunking and per-segment language ID.
public protocol VoiceActivityDetector: Sendable {
    /// Returns speech ranges (seconds, relative to the chunk's `startSeconds`).
    func speechRanges(in chunk: AudioChunk) async throws -> [TimeRange]
}

// MARK: - Transcription

public enum UseCase: String, Codable, Sendable, CaseIterable { case file, live, dictation }

public struct TranscriptionOptions: Sendable {
    public var languageMode: LanguageMode
    public var useCase: UseCase
    /// Explicit model override; `nil` means "Auto (recommended)" via `EngineRouter`.
    public var modelID: ModelID?
    /// Custom vocabulary / acronyms fed to engines that support prompting or contextual strings.
    public var vocabulary: [String]
    public var wordTimestamps: Bool
    public init(
        languageMode: LanguageMode = .default, useCase: UseCase, modelID: ModelID? = nil,
        vocabulary: [String] = [], wordTimestamps: Bool = true
    ) {
        self.languageMode = languageMode
        self.useCase = useCase
        self.modelID = modelID
        self.vocabulary = vocabulary
        self.wordTimestamps = wordTimestamps
    }
}

/// A volatile (not yet final) piece of live text.
public struct PartialSegment: Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var languageCode: LanguageCode?
    public init(text: String, start: TimeInterval, languageCode: LanguageCode? = nil) {
        self.text = text
        self.start = start
        self.languageCode = languageCode
    }
}

public enum TranscriptionEvent: Sendable {
    case partial(PartialSegment)
    case final(Segment)
    /// 0...1 plus the media time reached; used for job progress and checkpointing.
    case progress(fraction: Double, mediaTime: TimeInterval)
    case languageDetected([LanguageScore])
}

/// An ASR engine. Implementations run in isolated tasks, honour cancellation and map failures to `AppError`.
public protocol TranscriptionEngine: Sendable {
    var id: EngineID { get }
    /// Languages this engine can transcribe with the given model (or its default model).
    func supportedLanguages(model: ModelID?) async -> Set<LanguageCode>
    /// Loads a model into memory (idempotent). Engines never download; the `ModelManaging` actor does.
    func prepare(model: ModelID) async throws
    func unload() async
    func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error>
    /// Live transcription from a chunk stream (decoupled from `AudioSource` so mixed/lane inputs work).
    func stream(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error>
}

public protocol LanguageIdentifier: Sendable {
    func identify(chunk: AudioChunk, candidates: Set<LanguageCode>) async throws -> [LanguageScore]
}

// MARK: - Routing

public struct RoutingRequest: Sendable, Hashable {
    public var languageMode: LanguageMode
    public var useCase: UseCase
    public var tier: HardwareTier
    public var installedModels: Set<ModelID>
    public var explicitModel: ModelID?
    public init(
        languageMode: LanguageMode, useCase: UseCase, tier: HardwareTier, installedModels: Set<ModelID>, explicitModel: ModelID? = nil
    ) {
        self.languageMode = languageMode
        self.useCase = useCase
        self.tier = tier
        self.installedModels = installedModels
        self.explicitModel = explicitModel
    }
}

public struct EngineAssignment: Sendable, Hashable {
    public var language: LanguageCode?  // nil = applies to all languages in the request
    public var engine: EngineID
    public var model: ModelID?
    public var isExperimental: Bool
    public var requiresDownload: Bool
    public init(language: LanguageCode?, engine: EngineID, model: ModelID?, isExperimental: Bool = false, requiresDownload: Bool = false) {
        self.language = language
        self.engine = engine
        self.model = model
        self.isExperimental = isExperimental
        self.requiresDownload = requiresDownload
    }
}

public struct EnginePlan: Sendable, Hashable {
    public var assignments: [EngineAssignment]
    public var warnings: [String]
    public init(assignments: [EngineAssignment], warnings: [String] = []) {
        self.assignments = assignments
        self.warnings = warnings
    }
}

/// Pure, table-driven engine routing (ADR-004). Must have no side effects so every row can be unit-tested.
public protocol EngineRouter: Sendable {
    func plan(for request: RoutingRequest) throws -> EnginePlan
}

// MARK: - Post-processing

public struct PostProcessingContext: Sendable {
    public var ignoreRules: [IgnoreRule]
    public var replacementRules: [ReplacementRule]
    public var applyReplacements: Bool
    public var enableHallucinationFilter: Bool
    /// Confidence below which a hallucination-list match is dropped.
    public var lowConfidenceThreshold: Double
    public var noSpeechThreshold: Double
    public init(
        ignoreRules: [IgnoreRule] = [], replacementRules: [ReplacementRule] = [], applyReplacements: Bool = true,
        enableHallucinationFilter: Bool = false, lowConfidenceThreshold: Double = 0.5, noSpeechThreshold: Double = 0.6
    ) {
        self.ignoreRules = ignoreRules
        self.replacementRules = replacementRules
        self.applyReplacements = applyReplacements
        self.enableHallucinationFilter = enableHallucinationFilter
        self.lowConfidenceThreshold = lowConfidenceThreshold
        self.noSpeechThreshold = noSpeechThreshold
    }
}

/// One link in the chain: ignore filter → replacements → formatting.
public protocol TranscriptPostProcessor: Sendable {
    func process(_ segments: [Segment], context: PostProcessingContext) async -> [Segment]
}
