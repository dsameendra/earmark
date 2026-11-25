import AppCore
import Foundation
import Testing
@testable import Transcription

private actor Probe {
    var unloads: [EngineID] = []
    func unloaded(_ id: EngineID) { unloads.append(id) }
}

private struct FakeEngine: TranscriptionEngine {
    let id: EngineID
    let probe: Probe
    var hold: Duration = .milliseconds(1)
    func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> { ["en"] }
    func prepare(model: ModelID) async throws {}
    func unload() async { await probe.unloaded(id) }
    func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        let hold = hold
        return AsyncThrowingStream { continuation in
            Task { try? await Task.sleep(for: hold); continuation.yield(.progress(fraction: 1, mediaTime: 0)); continuation.finish() }
        }
    }
    func stream(audio: AsyncStream<AudioChunk>, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        transcribe(file: URL(fileURLWithPath: "/dev/null"), options: options)
    }
}

private let options = TranscriptionOptions(languageMode: .single("en"), useCase: .file)

@Suite("App-wide model residency")
struct ResidencyCoordinatorTests {
    private func drain(_ stream: AsyncThrowingStream<TranscriptionEvent, any Error>) async throws {
        for try await _ in stream {}
    }

    @Test("starting one engine unloads an idle peer but never itself")
    func unloadsIdlePeer() async throws {
        let probe = Probe(), coordinator = ResidencyCoordinator()
        let a = coordinator.managing(FakeEngine(id: "a", probe: probe)), b = coordinator.managing(FakeEngine(id: "b", probe: probe))
        try await drain(a.transcribe(file: URL(fileURLWithPath: "/x"), options: options))
        #expect(await probe.unloads.isEmpty)
        try await drain(b.transcribe(file: URL(fileURLWithPath: "/x"), options: options))
        #expect(await probe.unloads == ["a"])
        #expect(await coordinator.activeCount("b") == 0)
    }

    @Test("an engine that is transcribing is never unloaded by another engine's start")
    func keepsActiveEngine() async throws {
        let probe = Probe(), coordinator = ResidencyCoordinator()
        let a = coordinator.managing(FakeEngine(id: "a", probe: probe, hold: .milliseconds(400)))
        let b = coordinator.managing(FakeEngine(id: "b", probe: probe))
        let running = Task { try await drain(a.transcribe(file: URL(fileURLWithPath: "/x"), options: options)) }
        try await Task.sleep(for: .milliseconds(100))
        try await drain(b.transcribe(file: URL(fileURLWithPath: "/x"), options: options))
        try await running.value
        #expect(await probe.unloads.isEmpty)
        #expect(await coordinator.activeCount("a") == 0)
    }

    @Test("a cancelled stream releases its admission")
    func cancellationReleases() async throws {
        let probe = Probe(), coordinator = ResidencyCoordinator()
        let a = coordinator.managing(FakeEngine(id: "a", probe: probe, hold: .seconds(30)))
        let task = Task { try await drain(a.transcribe(file: URL(fileURLWithPath: "/x"), options: options)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await coordinator.activeCount("a") == 1)
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(await coordinator.activeCount("a") == 0)
    }
}
