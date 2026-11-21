import AppCore
import AudioCapture
import Export
import Foundation
import Processing
import Transcription

/// Supplies the auto-export writer for the current watch-folder setting (`nil` skips auto-export).
public typealias AutoExportProvider = @Sendable () async -> AutoExportWriter?

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
    /// Chunking pipeline (build it with the decoder, VAD and language identifier for production).
    public var pipeline: FileTranscriptionPipeline
    /// Used for media duration; should be the decoder the pipeline uses.
    public var decoder: any AudioFileDecoder
    /// Offline diarizer for jobs with `settings.diarize` (`nil` skips diarization).
    public var diarizer: (any Diarizer)?
    public var postProcessor: any TranscriptPostProcessor
    public var autoExport: AutoExportProvider?
    public var notifier: (any JobNotifier)?

    public init(
        jobs: any JobRepository, transcripts: any TranscriptRepository, media: any MediaRepository, rules: any RuleRepository,
        settings: any SettingsStore, models: any ModelManaging, hardware: any HardwareTierProviding,
        engines: [EngineID: any TranscriptionEngine], pipeline: FileTranscriptionPipeline = FileTranscriptionPipeline(),
        decoder: any AudioFileDecoder = AVFileDecoder(), diarizer: (any Diarizer)? = nil,
        postProcessor: any TranscriptPostProcessor = PostProcessingChain(), autoExport: AutoExportProvider? = nil,
        notifier: (any JobNotifier)? = nil
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
