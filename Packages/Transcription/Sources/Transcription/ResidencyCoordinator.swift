import AppCore
import Foundation

/// App-wide residency admission for the large on-device speech models (SCR-016 shared lifecycle).
///
/// Whenever one coordinated engine starts work or is prepared, every other coordinated engine that has no active
/// transcription is unloaded first, so Core ML, MLX and native-worker models are not all resident at once. An engine that is
/// transcribing is never unloaded. Engines remain individually serialized by their own gates.
public actor ResidencyCoordinator {
    private var engines: [EngineID: any TranscriptionEngine] = [:]
    private var active: [EngineID: Int] = [:]

    public init() {}

    /// Wraps `engine` so its use is admitted through this coordinator.
    public nonisolated func managing(_ engine: any TranscriptionEngine) -> any TranscriptionEngine {
        ResidencyManagedEngine(base: engine, coordinator: self)
    }

    func register(_ engine: any TranscriptionEngine) { engines[engine.id] = engine }

    /// Unloads idle peers. Returns after they have released their models.
    func admit(_ id: EngineID) async {
        for (other, engine) in engines where other != id && (active[other] ?? 0) == 0 {
            await engine.unload()
        }
    }

    /// Registers the engine on first use (an engine never used holds no model) and admits it.
    func begin(_ engine: any TranscriptionEngine) async {
        register(engine)
        await admit(engine.id)
        active[engine.id, default: 0] += 1
    }

    func end(_ id: EngineID) { active[id] = max(0, (active[id] ?? 1) - 1) }

    /// Number of in-flight transcriptions, for tests.
    func activeCount(_ id: EngineID) -> Int { active[id] ?? 0 }
}

struct ResidencyManagedEngine: TranscriptionEngine {
    let base: any TranscriptionEngine
    let coordinator: ResidencyCoordinator

    init(base: any TranscriptionEngine, coordinator: ResidencyCoordinator) {
        self.base = base
        self.coordinator = coordinator
    }

    var id: EngineID { base.id }

    func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> { await base.supportedLanguages(model: model) }

    func prepare(model: ModelID) async throws {
        await coordinator.begin(base)
        do { try await base.prepare(model: model) } catch { await coordinator.end(base.id); throw error }
        await coordinator.end(base.id)
    }

    func unload() async { await base.unload() }

    func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        relay { base.transcribe(file: file, options: options) }
    }

    func stream(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        relay { base.stream(audio: audio, options: options) }
    }

    /// Admits the engine before the underlying stream starts and releases the admission when it ends or is cancelled.
    private func relay(
        _ make: @escaping @Sendable () -> AsyncThrowingStream<TranscriptionEvent, any Error>
    ) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        let base = base, id = base.id, coordinator = coordinator
        return AsyncThrowingStream { continuation in
            let task = Task {
                await coordinator.begin(base)
                do {
                    for try await event in make() {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
                await coordinator.end(id)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
