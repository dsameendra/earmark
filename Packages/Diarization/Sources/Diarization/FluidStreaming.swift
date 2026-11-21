import AppCore
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Drives a FluidAudio frame-based streaming diarizer and translates its output through a ``LiveTurnPipeline``.
enum FluidStreamRunner {
    /// - Parameter makeEngine: Builds the (non-`Sendable`) engine **inside** the streaming task so it never crosses isolation.
    static func run(
        audio: AsyncStream<AudioChunk>, options: DiarizationOptions, engine: EngineID,
        makeEngine: @escaping @Sendable () async throws -> any FluidFrameDiarizer
    ) -> AsyncThrowingStream<LiveDiarizationEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let diarizer = try await makeEngine()
                    var pipeline: LiveTurnPipeline?
                    var offset: TimeInterval = 0
                    var fedSamples = 0

                    func emit(_ update: DiarizerTimelineUpdate?) {
                        guard let update, var current = pipeline else { return }
                        let events = current.ingest(
                            tentative: update.tentativeSegments.map(Self.raw), finalized: update.finalizedSegments.map(Self.raw))
                        pipeline = current
                        for event in events { continuation.yield(event) }
                    }

                    for await chunk in audio {
                        if Task.isCancelled { break }
                        if pipeline == nil {
                            offset = chunk.startSeconds
                            pipeline = LiveTurnPipeline(configuration: .init(options: options), timeOffset: offset)
                        }
                        try diarizer.addAudio(chunk.samples, sourceSampleRate: AudioChunk.sampleRate)
                        fedSamples += chunk.samples.count
                        while let update = try diarizer.process() { emit(update) }
                    }
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    emit(try diarizer.finalizeSession())
                    if var current = pipeline {
                        for event in current.finish(totalDuration: offset + Double(fedSamples) / AudioChunk.sampleRate) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as AppError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AppError.engineFailure(engine, reason: error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func raw(_ segment: DiarizerSegment) -> RawLiveSegment {
        RawLiveSegment(slot: segment.speakerIndex, start: Double(segment.startTime), end: Double(segment.endTime))
    }
}

/// Primary live engine: LS-EEND (`.ami` checkpoint, 100 ms step) via FluidAudio.
///
/// Measured on AMI headset meetings (spike): pooled strict DER 15.7 %, about 1.1 s label latency, 43 MB model, about 1 %
/// CPU; live and offline labels disagree on 17-29 % of audio, so every turn is provisional until the offline pass
/// (see ``LiveReconciliation``). Output follows the ``LiveTurnPipeline`` event semantics. Slots are capped at
/// ``maxLiveSpeakers``; further speakers raise ``LiveDiarizationEvent/speakerLimitReached`` once.
///
/// The model is loaded from ``ModelManaging/location(of:)`` for ``DiarizationModelID/lseendAMI``; nothing is
/// downloaded, FluidAudio's default cache is never used, and a missing model fails the stream with
/// ``AppError/modelNotInstalled(_:)``.
public struct LSEENDStreamingDiarizer: StreamingDiarizer {
    public static let engineID: EngineID = "fluidaudio.lseend-ami"
    public var id: EngineID { Self.engineID }
    private let models: any ModelManaging
    private let modelID: ModelID

    public init(models: any ModelManaging, modelID: ModelID = DiarizationModelID.lseendAMI) {
        self.models = models
        self.modelID = modelID
    }

    public func stream(
        audio: AsyncStream<AudioChunk>, options: DiarizationOptions
    ) -> AsyncThrowingStream<LiveDiarizationEvent, any Error> {
        let models = models
        let modelID = modelID
        return FluidStreamRunner.run(audio: audio, options: options, engine: Self.engineID) {
            let folder = try await ModelFiles.folder(of: modelID, using: models)
            guard let url = ModelFiles.item(named: ModelFiles.lseendAMIModel, under: folder) else {
                throw AppError.modelNotInstalled(modelID)
            }
            let diarizer = LSEENDDiarizer()
            try diarizer.initialize(model: LSEENDModel(modelURL: url, computeUnits: .cpuOnly))
            return diarizer
        }
    }
}

/// Fallback live engine: Sortformer **v2** (CC-BY-4.0 weights) via FluidAudio.
///
/// Chosen when stability matters more than accuracy: tentative labels arrive earlier (about 0.4 s median) and revise only
/// about 5 % of frames, at the cost of 4 speakers maximum, a 240 MB model and missed quiet or overlapped speech. The v2.1
/// weights are deliberately not selectable (licence, see the diarization research).
public struct SortformerStreamingDiarizer: StreamingDiarizer {
    /// The v2 weight variants that may be loaded.
    public enum Variant: Sendable, Hashable {
        /// Lowest latency (`Sortformer_v2`).
        case fast
        /// Balanced context (`SortformerNvidiaLow_v2`).
        case balanced

        var bundleFile: String {
            switch self {
            case .fast: ModelFiles.sortformerFastV2
            case .balanced: ModelFiles.sortformerBalancedV2
            }
        }
        var config: SortformerConfig {
            switch self {
            case .fast: .fastV2
            case .balanced: .balancedV2
            }
        }
    }

    public static let engineID: EngineID = "fluidaudio.sortformer-v2"
    public var id: EngineID { Self.engineID }
    private let models: any ModelManaging
    private let modelID: ModelID
    private let variant: Variant

    public init(models: any ModelManaging, modelID: ModelID = DiarizationModelID.sortformerV2, variant: Variant = .fast) {
        self.models = models
        self.modelID = modelID
        self.variant = variant
    }

    public func stream(
        audio: AsyncStream<AudioChunk>, options: DiarizationOptions
    ) -> AsyncThrowingStream<LiveDiarizationEvent, any Error> {
        let models = models
        let modelID = modelID
        let variant = variant
        return FluidStreamRunner.run(audio: audio, options: options, engine: Self.engineID) {
            let folder = try await ModelFiles.folder(of: modelID, using: models)
            guard let url = ModelFiles.item(named: variant.bundleFile, under: folder), !variant.bundleFile.contains("v2.1") else {
                throw AppError.modelNotInstalled(modelID)
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndGPU
            let main = try await MLModel.load(contentsOf: url, configuration: configuration)
            let diarizer = SortformerDiarizer(config: variant.config)
            diarizer.initialize(models: try SortformerModels(config: variant.config, main: main))
            return diarizer
        }
    }
}
