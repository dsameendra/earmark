import AppCore
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Loads FluidAudio's offline pipeline models **strictly from the app's model folder**.
///
/// FluidAudio's own loaders (`prepareModels`, `OfflineDiarizerModels.load`) resolve through `ModelHub`, which downloads
/// missing files and, on a failed load, purges the target directory and re-downloads. Those entry points are never
/// called. Instead the four compiled models are opened with Core ML directly and handed to the public initialisers,
/// so a missing file is an ``AppError/modelNotInstalled(_:)`` and the process stays offline.
enum FluidOfflineModelLoader {
    static func load(model: ModelID, using models: any ModelManaging) async throws -> OfflineDiarizerModels {
        let folder = try await ModelFiles.folder(of: model, using: models)
        let required = ModelFiles.offlineModelNames + [ModelFiles.pldaParameters]
        guard let dir = ModelFiles.directory(containingAll: required, under: folder) else {
            throw AppError.modelNotInstalled(model)
        }
        let started = Date()
        func open(_ name: String, units: MLComputeUnits) async throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try await MLModel.load(contentsOf: dir.appendingPathComponent(name), configuration: configuration)
        }
        // FBank is fastest on CPU; the rest follow FluidAudio's defaults.
        async let segmentation = open("Segmentation.mlmodelc", units: .all)
        async let fbank = open("FBank.mlmodelc", units: .cpuOnly)
        async let embedding = open("Embedding.mlmodelc", units: .all)
        async let pldaRho = open("PldaRho.mlmodelc", units: .all)
        let psi = try pldaPsi(at: dir.appendingPathComponent(ModelFiles.pldaParameters))
        return OfflineDiarizerModels(
            segmentationModel: try await segmentation, fbankModel: try await fbank, embeddingModel: try await embedding,
            pldaRhoModel: try await pldaRho, pldaPsi: psi, compilationDuration: Date().timeIntervalSince(started))
    }

    /// Decodes `tensors.psi.data_base64` (little-endian Float32) like FluidAudio's private loader does.
    static func pldaPsi(at url: URL) throws -> [Double] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let root = object as? [String: Any], let tensors = root["tensors"] as? [String: Any],
            let psi = tensors["psi"] as? [String: Any], let base64 = psi["data_base64"] as? String,
            let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]), data.count >= MemoryLayout<Float>.size
        else { throw AppError.engineFailure(FluidAudioDiarizer.engineID, reason: "plda-parameters.json is malformed") }
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return floats.map(Double.init)
    }
}

/// Offline diarization output with the per-speaker centroids needed for voice-profile matching.
public struct OfflineDiarization: Sendable {
    /// Speaker turns (slot = zero-based cluster index; overlapping turns are kept).
    public var turns: [SpeakerTurn]
    /// One centroid embedding per slot (256-d WeSpeaker, pre-PLDA), when the engine exposes them.
    public var centroids: [Int: SpeakerEmbedding]
    /// Identifies the embedding space so stored voice profiles are only compared with compatible vectors.
    public var embeddingModel: String
}

/// Offline diarizer: pyannote Community-1 segmentation + WeSpeaker embeddings + PLDA + VBx via FluidAudio.
///
/// Models are resolved through ``ModelManaging/location(of:)`` for ``DiarizationModelID/community1``. The engine never
/// downloads anything and never writes to FluidAudio's default cache; if the model is not installed it throws
/// ``AppError/modelNotInstalled(_:)`` so the UI can route through `ModelManaging.ensureAvailable` first.
///
/// Measured on AMI headset meetings (strict DER, collar 0, overlap scored): 18.1 % pooled (spike), 4 speakers found on
/// all three meetings.
public actor FluidAudioDiarizer: AppCore.Diarizer {
    /// `EngineID` of this engine.
    public static let engineID: EngineID = "fluidaudio.offline"
    /// Embedding space tag stored alongside voice profiles.
    public static let embeddingModelName = "wespeaker-community1-256d"

    public nonisolated var id: EngineID { Self.engineID }
    private let models: any ModelManaging
    private let modelID: ModelID
    private var loaded: OfflineDiarizerModels?

    /// - Parameters:
    ///   - models: The app's model manager; only `location(of:)` is used.
    ///   - modelID: Catalog id of the offline model (default ``DiarizationModelID/community1``).
    public init(models: any ModelManaging, modelID: ModelID = DiarizationModelID.community1) {
        self.models = models
        self.modelID = modelID
    }

    public func diarize(file: URL, options: DiarizationOptions) async throws -> [SpeakerTurn] {
        try await diarizeDetailed(file: file, options: options).turns
    }

    public func diarize(audio: AsyncThrowingStream<AudioChunk, any Error>, options: DiarizationOptions) async throws -> [SpeakerTurn] {
        try await diarizeDetailed(samples: DiarizationAudio.collect(audio), options: options).turns
    }

    /// Diarizes a file and also returns per-speaker centroids.
    public func diarizeDetailed(file: URL, options: DiarizationOptions) async throws -> OfflineDiarization {
        try await diarizeDetailed(samples: DiarizationAudio.samples(of: file), options: options)
    }

    /// Diarizes 16 kHz mono samples and also returns per-speaker centroids.
    public func diarizeDetailed(samples: [Float], options: DiarizationOptions) async throws -> OfflineDiarization {
        guard !samples.isEmpty else { return OfflineDiarization(turns: [], centroids: [:], embeddingModel: Self.embeddingModelName) }
        let manager = OfflineDiarizerManager(config: Self.config(for: options))
        manager.initialize(models: try await loadModels())
        do {
            let result = try await manager.process(audio: samples)
            return Self.convert(result)
        } catch is CancellationError {
            throw AppError.cancelled
        } catch let error as OfflineDiarizationError {
            if case .noSpeechDetected = error {
                return OfflineDiarization(turns: [], centroids: [:], embeddingModel: Self.embeddingModelName)
            }
            throw AppError.engineFailure(Self.engineID, reason: error.localizedDescription)
        } catch {
            throw AppError.engineFailure(Self.engineID, reason: error.localizedDescription)
        }
    }

    private func loadModels() async throws -> OfflineDiarizerModels {
        if let loaded { return loaded }
        let fresh = try await FluidOfflineModelLoader.load(model: modelID, using: models)
        loaded = fresh
        return fresh
    }

    /// Maps the app-level speaker count onto FluidAudio's clustering knobs (DIA-AC-02).
    static func config(for options: DiarizationOptions) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        switch options.speakerCount {
        case .auto: break
        case .exact(let count): config.clustering.numSpeakers = max(1, count)
        case .range(let lower, let upper):
            config.clustering.minSpeakers = max(1, lower)
            config.clustering.maxSpeakers = max(max(1, lower), upper)
        }
        return config
    }

    static func convert(_ result: DiarizationResult) -> OfflineDiarization {
        var slots: [String: Int] = [:]
        func slot(_ label: String) -> Int {
            if let known = slots[label] { return known }
            // "S3" -> 2; unknown label shapes get the next free slot.
            let parsed = Int(label.drop { !$0.isNumber }).map { max(0, $0 - 1) }
            let value = parsed ?? slots.count
            slots[label] = value
            return value
        }
        let turns = result.segments.map {
            SpeakerTurn(
                range: TimeRange(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)), slot: slot($0.speakerId))
        }.sorted { $0.range.start < $1.range.start }
        var centroids: [Int: SpeakerEmbedding] = [:]
        for (label, vector) in result.speakerDatabase ?? [:] { centroids[slot(label)] = SpeakerEmbedding(vector: vector) }
        return OfflineDiarization(turns: turns, centroids: centroids, embeddingModel: embeddingModelName)
    }
}
