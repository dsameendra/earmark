import AppCore
import AudioCapture
import Foundation
import Testing

@testable import Transcription

/// Measures Apple live-caption latency with the English fixture fed in real time (100 ms chunks, like capture).
///
/// Findings (macOS 27.2, 2026-11-22): engine start-up is ~10 ms, and chunk size (20/100/500 ms), analyzer priority and
/// model retention, `prepareToAnalyze`, `fastResults` and `ignoresResourceLimits` make no difference. `SpeechTranscriber`
/// emits volatile results in blocks of about 2 s of audio, so the first partial arrives ~1.4 s after speech starts (all
/// words of the block at once) and later ones follow the same cadence. A leading 3 s of silence shifts the first partial
/// by exactly 3 s, which rules out start-up cost. `DictationTranscriber` updates every 0.2-0.3 s but starts ~1.1 s after
/// speech and is less accurate, so it was not adopted. The test therefore guards against regressions only.
@Suite("Apple live latency (real time, needs installed assets + fixture)", .serialized)
struct AppleLiveLatencyTests {
    /// Speech onset of the first utterance (media seconds), from the fixture's energy profile.
    static let firstOnset = 0.45

    @Test("first partial latency stays bounded", .timeLimit(.minutes(2)))
    func firstPartialLatency() async throws {
        let engine = AppleSpeechEngine()
        guard await engine.assetStatus(for: "en") == .installed, let wav = LocalAssets.fixtureWAV else { return }
        try await engine.prepare(model: RoutingTargets.appleSpeech)
        let (audio, t0) = try await realTimeAudio(file: wav, seconds: 12)
        var firstPartial: Double?
        var firstFinal: Double?
        let options = TranscriptionOptions(languageMode: .single("en"), useCase: .live)
        for try await event in engine.stream(audio: audio, options: options) {
            let wall = (ContinuousClock.now - t0).secondsValue
            switch event {
            case .partial(let partial) where firstPartial == nil && !partial.text.isEmpty: firstPartial = wall
            case .final where firstFinal == nil: firstFinal = wall
            default: break
            }
        }
        let latency = (firstPartial ?? 99) - Self.firstOnset
        print(
            "INTEGRATION apple-live first partial \(String(format: "%.2f", latency))s after onset "
                + "(first final at \(firstFinal.map { String(format: "%.2f", $0) } ?? "none")s)")
        #expect(latency < 2.5)
    }
}
