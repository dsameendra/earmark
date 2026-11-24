import AppCore
import Foundation

/// One capture lane of a live session. Most sources have a single lane; Mic + System with labelled lanes has two
/// ("You" and "Them"), each transcribed independently and merged into one caption list.
public struct LiveAudioLane: Sendable {
    public var label: String?
    public var source: any AudioSource
    /// Whether streaming diarization should run on this lane (the "Them" / mixed lane; never the "You" lane).
    public var diarize: Bool
    public init(label: String? = nil, source: any AudioSource, diarize: Bool = true) {
        self.label = label
        self.source = source
        self.diarize = diarize
    }
}

/// Builds the audio lanes for a `CaptureSource`. The app target supplies an implementation backed by the
/// `AudioCapture` package (mic, process tap, app tap); tests supply `MockAudioSource`.
public protocol LiveAudioProviding: Sendable {
    func lanes(for source: CaptureSource) async throws -> [LiveAudioLane]
}

/// An engine chosen for a session, with the model the router picked.
public struct LiveEngineSelection: Sendable {
    public var engine: any TranscriptionEngine
    public var model: ModelID?
    public var warnings: [String]
    public init(engine: any TranscriptionEngine, model: ModelID? = nil, warnings: [String] = []) {
        self.engine = engine
        self.model = model
        self.warnings = warnings
    }
}

/// Resolves the ASR engine for a live session (ADR-004: routing is table-driven and lives in `EngineRouter`).
public protocol LiveEngineProviding: Sendable {
    func resolve(languageMode: LanguageMode) async throws -> LiveEngineSelection
}

/// Default provider: asks the `EngineRouter` for a `.live` plan and looks the engine up in a registry.
public struct RouterEngineProvider: LiveEngineProviding {
    private let router: any EngineRouter
    private let hardware: any HardwareTierProviding
    private let models: any ModelManaging
    private let engine: @Sendable (EngineID) -> (any TranscriptionEngine)?
    private let explicitModel: @Sendable () async -> ModelID?

    public init(
        router: any EngineRouter, hardware: any HardwareTierProviding, models: any ModelManaging,
        engine: @escaping @Sendable (EngineID) -> (any TranscriptionEngine)?,
        explicitModel: @escaping @Sendable () async -> ModelID? = { nil }
    ) {
        self.router = router
        self.hardware = hardware
        self.models = models
        self.engine = engine
        self.explicitModel = explicitModel
    }

    public func resolve(languageMode: LanguageMode) async throws -> LiveEngineSelection {
        let request = RoutingRequest(
            languageMode: languageMode, useCase: .live, tier: hardware.profile.tier,
            installedModels: await models.installedModels(), explicitModel: await explicitModel())
        let plan = try await router.preparedPlan(for: request)
        guard let assignment = plan.assignments.first else { throw AppError.other("No engine available for live captions") }
        if assignment.requiresDownload, let model = assignment.model { throw AppError.modelNotInstalled(model) }
        guard let engine = engine(assignment.engine) else {
            throw AppError.engineFailure(assignment.engine, reason: "Engine is not registered")
        }
        if let model = assignment.model { try await engine.prepare(model: model) }
        return LiveEngineSelection(engine: engine, model: assignment.model, warnings: plan.warnings)
    }
}

/// Tunables; the defaults match the spec, tests shrink the intervals.
public struct LiveSessionOptions: Sendable {
    /// How often finalized segments are flushed to the repository (crash safety).
    public var checkpointInterval: Duration
    /// How long `stop()` waits for engines to flush remaining finals before cancelling them.
    public var drainTimeout: Duration
    /// Minimum gap between translation updates (LIVE-AC-13: at most 1 update per second).
    public var translationMinInterval: Duration
    /// Pending finalized captions waiting for translation; older overflow retains its original text.
    public var maxPendingTranslations: Int
    public var maxRetainedLines: Int
    public var vocabulary: [String]
    public var now: @Sendable () -> Date

    public init(
        checkpointInterval: Duration = .seconds(3), drainTimeout: Duration = .seconds(2),
        translationMinInterval: Duration = .seconds(1), maxPendingTranslations: Int = 32, maxRetainedLines: Int = 200, vocabulary: [String] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.checkpointInterval = checkpointInterval
        self.drainTimeout = drainTimeout
        self.translationMinInterval = translationMinInterval
        self.maxPendingTranslations = max(1, maxPendingTranslations)
        self.maxRetainedLines = maxRetainedLines
        self.vocabulary = vocabulary
        self.now = now
    }
}

/// Out-of-band notices from a running session (shown as notifications / recovery actions by the app).
public enum LiveSessionEvent: Sendable, Equatable {
    case paused, resumed
    /// The input device went away and capture fell back to the default (LIVE-AC-15); the session continues.
    case deviceFallback(to: String?)
    /// Capture problem, e.g. `.captureSilent` (LIVE-AC-05): the UI offers a permission recovery action.
    case captureProblem(AppError)
    /// More than `maxLiveSpeakers` speakers; extras are labelled "More speakers".
    case speakerLimitReached
    case checkpointFailed(String)
    /// The engine router chose a fallback or has another note for the user (`EnginePlan.warnings`), for example that Apple
    /// Speech is unavailable and Whisper is used instead.
    case engineNotice(String)
    /// Translation failed while recognition continues; retain the original caption and offer recovery.
    case translationFailed(reason: String)
}

/// Shown on the translation line when the engine flags a weak direction (LIVE-AC-13). The contract's `CaptionLine`
/// has no confidence field, so the orchestrator prefixes the translation and the overlay renders it as a marker.
public enum LiveCaptionMarkers {
    public static let lowConfidenceTranslationPrefix = "\u{2248} "
}
