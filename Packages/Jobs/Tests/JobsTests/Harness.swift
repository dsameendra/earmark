import AppCore
import AppCoreTesting
import AudioCapture
import Export
import Foundation
import ModelStore
import Persistence
import Testing
import Transcription
import os

@testable import Jobs

// MARK: - Fakes

/// Engine that echoes one segment per chunk, can be held, and can fail. Tracks concurrent use.
final class TestEngine: TranscriptionEngine, Sendable {
    struct State {
        var held = false
        var holdAfter = 0
        var failure: AppError?
        var active = 0
        var maxActive = 0
        var chunkStarts: [TimeInterval] = []
        var unloads = 0
    }
    let id: EngineID = "whisperkit"
    private let state = OSAllocatedUnfairLock(initialState: State())

    var maxActive: Int { state.withLock { $0.maxActive } }
    var active: Int { state.withLock { $0.active } }
    var chunkStarts: [TimeInterval] { state.withLock { $0.chunkStarts } }
    var unloads: Int { state.withLock { $0.unloads } }
    func hold(_ value: Bool, afterChunks: Int = 0) {
        state.withLock {
            $0.held = value
            $0.holdAfter = afterChunks
        }
    }
    func fail(with error: AppError?) { state.withLock { $0.failure = error } }

    func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> { ["en"] }
    func prepare(model: ModelID) async throws {}
    func unload() async { state.withLock { $0.unloads += 1 } }
    func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stream(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                state.withLock {
                    $0.active += 1
                    $0.maxActive = max($0.maxActive, $0.active)
                }
                defer { state.withLock { $0.active -= 1 } }
                do {
                    for await chunk in audio {
                        while state.withLock({ $0.held && $0.chunkStarts.count >= $0.holdAfter }) {
                            try await Task.sleep(for: .milliseconds(5))
                        }
                        try Task.checkCancellation()
                        if let failure = state.withLock({ $0.failure }) { throw failure }
                        state.withLock { $0.chunkStarts.append(chunk.startSeconds) }
                        continuation.yield(
                            .final(
                                Segment(
                                    start: chunk.startSeconds, end: chunk.startSeconds + chunk.duration,
                                    text: "seg \(Int(chunk.startSeconds))", languageCode: "en")))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Decoder producing silent 10 s blocks; records where each decode started.
final class FakeDecoder: AudioFileDecoder, Sendable {
    let total: TimeInterval
    let block: TimeInterval
    private let starts = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])
    private let failure = OSAllocatedUnfairLock<(error: AppError, name: String?)?>(initialState: nil)
    init(total: TimeInterval = 40, block: TimeInterval = 10) {
        self.total = total
        self.block = block
    }
    var decodeStarts: [TimeInterval] { starts.withLock { $0 } }
    func failDecoding(with error: AppError?, forFileNamed name: String? = nil) { failure.withLock { $0 = error.map { ($0, name) } } }

    func decode(file: URL, chunkSeconds: TimeInterval, startingAt: TimeInterval) -> AsyncThrowingStream<AudioChunk, any Error> {
        starts.withLock { $0.append(startingAt) }
        let (total, block) = (total, block)
        let failure = failure.withLock { $0 }.flatMap { $0.name == nil || $0.name == file.lastPathComponent ? $0.error : nil }
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            var time = startingAt
            while time < total {
                let length = min(block, total - time)
                continuation.yield(
                    AudioChunk(
                        samples: [Float](repeating: 0, count: Int(length * AudioChunk.sampleRate)), startSeconds: time, source: .file))
                time += length
            }
            continuation.finish()
        }
    }

    func duration(of file: URL) async throws -> TimeInterval { total }
}

/// Wraps the mock model manager and records `ensureAvailable` calls.
final class SpyModelManager: ModelManaging, Sendable {
    private let inner: MockModelManager
    private let ensuredIDs = OSAllocatedUnfairLock<[ModelID]>(initialState: [])
    init(_ inner: MockModelManager) { self.inner = inner }
    var ensured: [ModelID] { ensuredIDs.withLock { $0 } }

    func catalog() async -> [ModelDescriptor] { await inner.catalog() }
    func state(of model: ModelID) async -> ModelState { await inner.state(of: model) }
    func stateChanges() -> AsyncStream<(ModelID, ModelState)> { inner.stateChanges() }
    func installedModels() async -> Set<ModelID> { await inner.installedModels() }
    func ensureAvailable(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error> {
        ensuredIDs.withLock { $0.append(model) }
        return inner.ensureAvailable(model)
    }
    func pauseDownload(_ model: ModelID) async { await inner.pauseDownload(model) }
    func resumeDownload(_ model: ModelID) async { await inner.resumeDownload(model) }
    func cancelDownload(_ model: ModelID) async { await inner.cancelDownload(model) }
    func delete(_ model: ModelID) async throws { try await inner.delete(model) }
    func importModel(folder: URL, displayName: String, languages: Set<LanguageCode>) async throws -> ModelDescriptor {
        try await inner.importModel(folder: folder, displayName: displayName, languages: languages)
    }
    func diskUsage() async -> DiskUsage { await inner.diskUsage() }
    func location(of model: ModelID) async throws -> URL { try await inner.location(of: model) }
}

/// Records the engine plans the queue hands to the pipeline factory.
final class PlanRecorder: Sendable {
    private let recorded = OSAllocatedUnfairLock<[EnginePlan]>(initialState: [])
    var plans: [EnginePlan] { recorded.withLock { $0 } }
    func record(_ plan: EnginePlan) { recorded.withLock { $0.append(plan) } }
}

final class TestHardware: HardwareTierProviding, Sendable {
    private struct State {
        var onBattery = false
        var tier: HardwareTier = .tier16
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let thermalStream = AsyncStream<ThermalPressure>.makeStream()
    private let memoryStream = AsyncStream<Void>.makeStream()

    var profile: HardwareProfile {
        HardwareProfile(chip: "Test", memoryBytes: 18 << 30, performanceCores: 6, tier: state.withLock { $0.tier })
    }
    func setBattery(_ value: Bool) { state.withLock { $0.onBattery = value } }
    func setTier(_ tier: HardwareTier) { state.withLock { $0.tier = tier } }
    func sendThermal(_ value: ThermalPressure) { thermalStream.continuation.yield(value) }
    func sendMemoryPressure() { memoryStream.continuation.yield() }
    func memoryPressure() -> AsyncStream<Void> { memoryStream.stream }
    func thermalPressure() -> AsyncStream<ThermalPressure> { thermalStream.stream }
    func isOnBattery() -> Bool { state.withLock { $0.onBattery } }
}

final class RecordingNotifier: JobNotifier, Sendable {
    private struct State {
        var completed: [JobCompletionInfo] = []
        var failed: [Job] = []
        var batches: [JobBatchSummary] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var completed: [JobCompletionInfo] { state.withLock { $0.completed } }
    var failed: [Job] { state.withLock { $0.failed } }
    var batches: [JobBatchSummary] { state.withLock { $0.batches } }
    func jobCompleted(_ info: JobCompletionInfo) async { state.withLock { $0.completed.append(info) } }
    func jobFailed(_ job: Job) async { state.withLock { $0.failed.append(job) } }
    func batchFinished(_ summary: JobBatchSummary) async { state.withLock { $0.batches.append(summary) } }
}

/// Maps the first half of the media to slot 0 and the rest to slot 1.
struct FakeDiarizer: Diarizer {
    let id: EngineID = "fake.diarizer"
    var split: TimeInterval = 20
    var end: TimeInterval = 40
    func diarize(file: URL, options: DiarizationOptions) async throws -> [SpeakerTurn] {
        [SpeakerTurn(range: TimeRange(start: 0, end: split), slot: 0), SpeakerTurn(range: TimeRange(start: split, end: end), slot: 1)]
    }
    func diarize(audio: AsyncThrowingStream<AudioChunk, any Error>, options: DiarizationOptions) async throws -> [SpeakerTurn] { [] }
}

// MARK: - Harness

struct Harness {
    let database: AppDatabase
    let engine = TestEngine()
    let decoder: FakeDecoder
    let hardware = TestHardware()
    let notifier = RecordingNotifier()
    let models: SpyModelManager
    let plans = PlanRecorder()
    let settings: SQLiteSettingsStore
    let exportFolder = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-export-\(UUID().uuidString)")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-input-\(UUID().uuidString)")
    let queue: PersistentJobQueue

    static let largeModel = RoutingTargets.whisperLarge

    init(
        installed: Set<ModelID> = [Harness.largeModel], decoder: FakeDecoder = FakeDecoder(), diarizer: (any Diarizer)? = nil,
        memoryHold: Duration = .milliseconds(100), database: AppDatabase? = nil
    ) throws {
        let db = try database ?? AppDatabase.inMemory()
        self.database = db
        self.decoder = decoder
        models = SpyModelManager(MockModelManager(descriptors: BuiltInCatalog.models, installed: installed))
        settings = db.makeSettingsStore()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var chunking = FileTranscriptionPipeline.Configuration()
        chunking.chunkSeconds = 10
        let config = chunking
        let plans = plans
        let pipeline: PipelineFactory = { plan in
            plans.record(plan)
            return FileTranscriptionPipeline(decoder: decoder, vad: nil, identifier: nil, configuration: config)
        }
        let exportFolder = exportFolder
        let presets = db.presets
        var configuration = JobQueueConfiguration()
        configuration.memoryPressureHold = memoryHold
        configuration.progressInterval = 0
        queue = PersistentJobQueue(
            services: JobQueueServices(
                jobs: db.jobs, transcripts: db.transcripts, media: db.media, rules: db.rules, settings: settings, models: models,
                hardware: hardware, engines: ["whisperkit": engine], pipeline: pipeline, decoder: decoder, diarizer: diarizer,
                autoExport: { AutoExportWriter(folder: exportFolder, presets: presets) }, notifier: notifier),
            configuration: configuration)
    }

    /// Creates an empty media file the queue can "decode" through the fake decoder.
    func makeFile(_ name: String = "talk.wav") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    func job(_ id: JobID) async -> Job? { await queue.jobs().first { $0.id == id } }

    func segments(of job: Job) async throws -> [Segment] {
        guard let tid = job.transcriptID else { return [] }
        return try await database.transcripts.segments(for: tid)
    }

    /// Waits for `condition` (polled), failing the test via `false` after `timeout`.
    func until(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func waitFor(_ id: JobID, _ state: JobState, timeout: Duration = .seconds(10)) async -> Bool {
        await until(timeout: timeout) { await job(id)?.state == state }
    }
}

extension Harness {
    func transcript(of job: Job) async throws -> Transcript {
        let id = try #require(job.transcriptID)
        return try #require(try await database.transcripts.transcript(id))
    }

    func asset(of transcript: Transcript) async throws -> MediaAsset {
        let id = try #require(transcript.mediaAssetID)
        return try #require(try await database.media.asset(id))
    }
}
