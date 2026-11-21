import AppCore
import Foundation

/// Scripted ASR engine: emits `events` then finishes (or throws `failure`).
public final class MockTranscriptionEngine: TranscriptionEngine {
    public let id: EngineID
    public let languages: Set<LanguageCode>
    public let events: [TranscriptionEvent]
    public let failure: AppError?
    public init(
        id: EngineID = "mock.engine", languages: Set<LanguageCode> = [.english], events: [TranscriptionEvent] = [], failure: AppError? = nil
    ) {
        self.id = id
        self.languages = languages
        self.events = events
        self.failure = failure
    }
    public func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> { languages }
    public func prepare(model: ModelID) async throws {}
    public func unload() async {}
    public func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> { run() }
    public func stream(
        audio: AsyncStream<AudioChunk>, options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        run()
    }
    private func run() -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        let events = events
        let failure = failure
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            if let failure { c.finish(throwing: failure) } else { c.finish() }
        }
    }
}

/// Audio source that replays prepared chunks.
public final class MockAudioSource: AudioSource {
    public let tag: AudioSourceTag
    private let chunks: [AudioChunk]
    public init(tag: AudioSourceTag = .mic(deviceUID: nil), chunks: [AudioChunk] = []) {
        self.tag = tag
        self.chunks = chunks
    }
    public func start() async throws -> AsyncStream<AudioChunk> {
        let chunks = chunks
        return AsyncStream { c in
            for ch in chunks { c.yield(ch) }
            c.finish()
        }
    }
    public func stop() async {}
    public var levels: AsyncStream<Float> { AsyncStream { $0.finish() } }
    public var health: AsyncStream<AudioSourceHealth> { AsyncStream { $0.finish() } }
}

/// In-memory model manager whose `ensureAvailable` emits deterministic progress.
public actor MockModelManager: ModelManaging {
    private var descriptors: [ModelDescriptor]
    private var states: [ModelID: ModelState] = [:]
    public init(descriptors: [ModelDescriptor] = [], installed: Set<ModelID> = []) {
        self.descriptors = descriptors
        for id in installed { states[id] = .installed(bytesOnDisk: 1) }
    }
    public func catalog() -> [ModelDescriptor] { descriptors }
    public func state(of model: ModelID) -> ModelState { states[model] ?? .notInstalled }
    public nonisolated func stateChanges() -> AsyncStream<(ModelID, ModelState)> { AsyncStream { $0.finish() } }
    public func installedModels() -> Set<ModelID> { Set(states.compactMap { if case .installed = $0.value { $0.key } else { nil } }) }
    public nonisolated func ensureAvailable(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error> {
        AsyncThrowingStream { c in
            Task {
                if await self.installedModels().contains(model) {
                    c.yield(.completed)
                    c.finish()
                    return
                }
                for f in [0.25, 0.5, 0.75, 1.0] { c.yield(.progress(fraction: f, bytesReceived: Int64(f * 100), bytesTotal: 100)) }
                c.yield(.verifying)
                await self.markInstalled(model)
                c.yield(.completed)
                c.finish()
            }
        }
    }
    private func markInstalled(_ id: ModelID) { states[id] = .installed(bytesOnDisk: 100) }
    public func pauseDownload(_ model: ModelID) {}
    public func resumeDownload(_ model: ModelID) {}
    public func cancelDownload(_ model: ModelID) {}
    public func delete(_ model: ModelID) throws { states[model] = .notInstalled }
    public func importModel(folder: URL, displayName: String, languages: Set<LanguageCode>) throws -> ModelDescriptor {
        let d = ModelDescriptor(
            id: ModelID("custom/\(displayName)"), displayName: displayName, kind: .asr, runtime: .coreML,
            languages: languages, sizeBytes: 0, license: LicenseInfo(spdx: "unknown"), isCustom: true)
        descriptors.append(d)
        states[d.id] = .installed(bytesOnDisk: 0)
        return d
    }
    public func diskUsage() -> DiskUsage { DiskUsage(totalBytes: 0, perModel: [:]) }
    public func location(of model: ModelID) throws -> URL {
        guard case .installed = states[model] else { throw AppError.modelNotInstalled(model) }
        return URL(fileURLWithPath: "/dev/null")
    }
}
