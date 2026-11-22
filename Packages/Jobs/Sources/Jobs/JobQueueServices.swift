import AppCore
import AudioCapture
import Export
import Foundation
import Processing
import Transcription

/// Supplies the auto-export writer for the current watch-folder setting (`nil` skips auto-export).
public typealias AutoExportProvider = @Sendable () async -> AutoExportWriter?

/// Creates the file pipeline for one job given its engine plan.
public typealias PipelineFactory = @Sendable (EnginePlan) -> FileTranscriptionPipeline

/// What a non-file job handler (meeting finalization, translation) needs from the queue while it runs.
public struct JobHandlerContext: Sendable {
    public var job: Job
    /// Reports overall progress in 0...1 (throttled and broadcast by the queue).
    public var progress: @Sendable (Double) async -> Void
    /// Sets or clears the one-line status note shown with the job.
    public var note: @Sendable (String?) async -> Void
    public init(
        job: Job, progress: @escaping @Sendable (Double) async -> Void = { _ in },
        note: @escaping @Sendable (String?) async -> Void = { _ in }
    ) {
        self.job = job
        self.progress = progress
        self.note = note
    }
}

/// The result of a handled job: the transcript it produced or changed and the title used in the completion notification.
public struct JobHandlerResult: Sendable {
    public var transcriptID: TranscriptID?
    public var title: String?
    public init(transcriptID: TranscriptID? = nil, title: String? = nil) {
        self.transcriptID = transcriptID
        self.title = title
    }
}

/// Runs a job kind the queue does not implement itself. Jobs depends only on AppCore for these: the app injects handlers
/// (for example `.finalizeMeeting` backed by `MeetingFinalizer`, `.translate` backed by the translation coordinator).
/// Throw to fail the job (`AppError`s are described to the user, a cancelled task pauses/cancels as usual).
public typealias JobHandler = @Sendable (JobHandlerContext) async throws -> JobHandlerResult

/// Chooses the engine and model per language for a file job, given the router's plan for the job's language mode. The
/// default resolves from the plan only; the app supplies one that asks the router per detected language so auto-detect and
/// multilingual jobs can reach engines the plan did not name (Sinhala).
public typealias FileEngineResolver = @Sendable (EnginePlan, JobSettings) -> EngineResolver

/// Everything the queue needs, injected so tests can run it without AVFoundation, WhisperKit or FluidAudio.
public struct JobQueueServices: Sendable {
    public var jobs: any JobRepository
    public var transcripts: any TranscriptRepository
    public var media: any MediaRepository
    public var rules: any RuleRepository
    public var settings: any SettingsStore
    public var models: any ModelManaging
    public var hardware: any HardwareTierProviding
    /// Engine instances by id; the router's plan picks from these.
    public var engines: [EngineID: any TranscriptionEngine]
    /// Builds the chunking pipeline for a job from its engine plan, so the language identifier can use the model the plan
    /// routed to (a fixed identifier model would swap models under a running job).
    public var pipeline: PipelineFactory
    /// Used for media duration; should be the decoder the pipeline uses.
    public var decoder: any AudioFileDecoder
    /// Offline diarizer for jobs with `settings.diarize` (`nil` skips diarization).
    public var diarizer: (any Diarizer)?
    public var postProcessor: any TranscriptPostProcessor
    public var autoExport: AutoExportProvider?
    public var notifier: (any JobNotifier)?
    /// Handlers for job kinds other than `.transcribeFile`.
    public var handlers: [JobKind: JobHandler]
    /// Per-language engine resolution for file jobs; `nil` resolves from the plan alone.
    public var engineResolver: FileEngineResolver?

    public init(
        jobs: any JobRepository, transcripts: any TranscriptRepository, media: any MediaRepository, rules: any RuleRepository,
        settings: any SettingsStore, models: any ModelManaging, hardware: any HardwareTierProviding,
        engines: [EngineID: any TranscriptionEngine], pipeline: @escaping PipelineFactory = { _ in FileTranscriptionPipeline() },
        decoder: any AudioFileDecoder = AVFileDecoder(), diarizer: (any Diarizer)? = nil,
        postProcessor: any TranscriptPostProcessor = PostProcessingChain(), autoExport: AutoExportProvider? = nil,
        notifier: (any JobNotifier)? = nil, handlers: [JobKind: JobHandler] = [:], engineResolver: FileEngineResolver? = nil
    ) {
        self.jobs = jobs
        self.transcripts = transcripts
        self.media = media
        self.rules = rules
        self.settings = settings
        self.models = models
        self.hardware = hardware
        self.engines = engines
        self.pipeline = pipeline
        self.decoder = decoder
        self.diarizer = diarizer
        self.postProcessor = postProcessor
        self.autoExport = autoExport
        self.notifier = notifier
        self.handlers = handlers
        self.engineResolver = engineResolver
    }
}

/// Tunables that tests shorten.
public struct JobQueueConfiguration: Sendable {
    /// Minimum spacing of non-checkpoint progress broadcasts (the UI needs at least 1 Hz, FILE-AC-14).
    public var progressInterval: TimeInterval = 0.25
    /// How long new starts are held after a memory-pressure warning (FILE-AC-15).
    public var memoryPressureHold: Duration = .seconds(20)
    public var now: @Sendable () -> Date = { Date() }
    public init() {}
}

/// Default watch folder behind ``JobsSettingsKey/autoExportFolder``.
public enum WatchFolderExport {
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Earmark Exports", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Earmark Exports", isDirectory: true)
    }

    /// A provider that reads the folder from settings on every call, so changing it applies to the next job.
    public static func provider(settings: any SettingsStore, presets: any PresetRepository) -> AutoExportProvider {
        {
            let path = await settings.value(for: JobsSettingsKey.autoExportFolder, as: String.self)
            let folder = path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
            return AutoExportWriter(folder: folder, presets: presets)
        }
    }
}
