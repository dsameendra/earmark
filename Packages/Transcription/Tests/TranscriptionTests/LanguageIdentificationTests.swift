import AppCore
import AudioCapture
import Foundation
import Testing

@testable import Transcription

@Suite("Restricted language scoring (T25, LANG-AC-05/06)")
struct RestrictedLanguageScoringTests {
    private let logits: [String: Float] = ["en": 8, "si": 3, "hi": 5, "ta": 1, "de": 0]

    @Test("restricted scores are renormalised over the candidates and sorted")
    func renormalised() {
        let scores = RestrictedLanguageScoring.scores(logits: logits, candidates: ["en", "si"], minimumMass: 0.02)
        #expect(scores.map(\.language) == ["en", "si"])
        #expect(abs(scores.map(\.probability).reduce(0, +) - 1) < 1e-9)
        // softmax over {en: 8, si: 3} only: hi (5) must not steal mass from the restricted distribution
        #expect(abs(scores[0].probability - 1 / (1 + exp(-5.0))) < 1e-6)
    }

    @Test("a winner outside the candidate set yields no answer when the candidates hold almost no mass")
    func outsideSet() {
        let skewed: [String: Float] = ["en": 20, "de": 0, "fr": 0]
        #expect(RestrictedLanguageScoring.scores(logits: skewed, candidates: ["de", "fr"], minimumMass: 0.02).isEmpty)
    }

    @Test("a candidate-set that holds enough mass is still answered even if another language wins overall")
    func foreignWinnerWithMass() {
        // Sinhala audio that Whisper labels Hindi: {en, si} still separates si from en.
        let sinhalaAsHindi: [String: Float] = ["hi": 6, "si": 4.5, "en": -2, "ta": 2]
        let scores = RestrictedLanguageScoring.scores(logits: sinhalaAsHindi, candidates: ["en", "si"], minimumMass: 0.02)
        #expect(scores.first?.language == "si")
        #expect((scores.first?.probability ?? 0) > 0.99)
    }

    @Test("regional tags compare by primary subtag; unknown candidates and empty logits are empty")
    func edgeCases() {
        #expect(RestrictedLanguageScoring.scores(logits: logits, candidates: ["en-US"], minimumMass: 0).first?.language == "en")
        #expect(RestrictedLanguageScoring.scores(logits: logits, candidates: ["xx"], minimumMass: 0).isEmpty)
        #expect(RestrictedLanguageScoring.scores(logits: [:], candidates: ["en"], minimumMass: 0).isEmpty)
        #expect(RestrictedLanguageScoring.scores(logits: ["en": .nan, "de": 1], candidates: ["en"], minimumMass: 0).count <= 1)
    }

    @Test("an empty candidate set means all languages")
    func allLanguages() {
        let scores = RestrictedLanguageScoring.scores(logits: logits, candidates: [], minimumMass: 0)
        #expect(scores.count == logits.count)
        #expect(scores.first?.language == "en")
    }
}

@Suite("withDeadline hang guard (T25)")
struct DeadlineTests {
    @Test("returns the value of a fast operation")
    func fast() async throws {
        let value = try await withDeadline(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test("propagates the operation's error")
    func failure() async {
        await #expect(throws: AppError.self) {
            try await withDeadline(.seconds(5)) { () -> Int in throw AppError.other("boom") }
        }
    }

    @Test("an uncancellable operation that never returns cannot hang the caller")
    func wedged() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        // Blocks a thread with no cooperative cancellation, like a stuck Core ML prediction.
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(.milliseconds(300)) { () -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }  // never resumed
                return 1
            }
        }
        #expect(clock.now - start < .seconds(3))
    }

    @Test("caller cancellation returns promptly")
    func cancelled() async throws {
        let task = Task {
            try await withDeadline(.seconds(60)) { () -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// Real-model language ID on local assets (skipped when the model or fixtures are missing).
@Suite("Whisper language ID integration (needs local model + fixtures)", .serialized)
struct WhisperLanguageIDIntegrationTests {
    static let sinhalaDir: URL? = LocalAssets.search(".model-cache/sinhala-eval/slr30_wav", envKey: "EARMARK_SINHALA_EVAL")
    static let available = LocalAssets.available && sinhalaDir != nil

    private func engine() throws -> WhisperKitEngine {
        let folder = try #require(LocalAssets.smallModel)
        return WhisperKitEngine(locate: { _ in folder }, tokenizerFolder: LocalAssets.cacheRoot, defaultModel: "whisperkit/small")
    }

    private func firstChunk(_ url: URL, seconds: TimeInterval = 30) async throws -> AudioChunk {
        for try await chunk in AVFileDecoder().decode(file: url, chunkSeconds: seconds, startingAt: 0) { return chunk }
        throw AppError.other("empty audio")
    }

    /// Measures Sinhala-vs-English identification restricted to {en, si}: 40 SLR30 Sinhala clips (CC BY-SA) and the LibriSpeech
    /// fixture cut into 5 English clips. Prints the accuracy (recorded in the T25 report).
    @Test("restricted {en, si} identification on Sinhala and English clips", .enabled(if: available), .timeLimit(.minutes(5)))
    func sinhalaVersusEnglish() async throws {
        let engine = try engine()
        let identifier = WhisperLanguageIdentifier(engine: engine, model: "whisperkit/small")
        let dir = try #require(Self.sinhalaDir)
        let clips = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
        var sinhalaCorrect = 0
        var sinhalaEmpty = 0
        let clock = ContinuousClock()
        var totalTime: Duration = .zero
        for url in clips {
            let chunk = try await firstChunk(url)
            let start = clock.now
            let scores = try await identifier.identify(chunk: chunk, candidates: ["en", "si"])
            totalTime += clock.now - start
            if scores.isEmpty { sinhalaEmpty += 1 } else if scores.first?.language == "si" { sinhalaCorrect += 1 }
        }
        var englishCorrect = 0
        let wav = try #require(LocalAssets.fixtureWAV)
        var englishCount = 0
        for try await chunk in AVFileDecoder().decode(file: wav, chunkSeconds: 6, startingAt: 0) {
            guard englishCount < 10 else { break }
            englishCount += 1
            let scores = try await identifier.identify(chunk: chunk, candidates: ["en", "si"])
            if scores.first?.language == "en" { englishCorrect += 1 }
        }
        print(
            "LID {en,si}: Sinhala \(sinhalaCorrect)/\(clips.count) correct (\(sinhalaEmpty) empty), English \(englishCorrect)/\(englishCount) correct, mean \(totalTime / max(1, clips.count)) per clip"
        )
        #expect(Double(sinhalaCorrect) / Double(max(1, clips.count)) >= 0.8)
        #expect(Double(englishCorrect) / Double(max(1, englishCount)) >= 0.9)
        await engine.unload()
    }

    @Test("repeated identification never hangs and stays fast", .enabled(if: LocalAssets.available), .timeLimit(.minutes(3)))
    func repeated() async throws {
        let engine = try engine()
        let identifier = WhisperLanguageIdentifier(engine: engine, model: "whisperkit/small")
        let wav = try #require(LocalAssets.fixtureWAV)
        let chunk = try await firstChunk(wav, seconds: 10)
        for _ in 0..<10 {
            let scores = try await identifier.identify(chunk: chunk, candidates: ["en", "de", "fr"])
            #expect(scores.first?.language == "en")
        }
        await engine.unload()
    }

    @Test("a timeout discards the model and the engine recovers", .enabled(if: LocalAssets.available), .timeLimit(.minutes(3)))
    func recoversFromTimeout() async throws {
        let engine = try engine()
        let wav = try #require(LocalAssets.fixtureWAV)
        let chunk = try await firstChunk(wav, seconds: 10)
        await #expect(throws: LanguageIDError.timedOut) {
            _ = try await engine.detectLanguage(samples: chunk.samples, candidates: ["en"], model: "whisperkit/small", timeout: .milliseconds(1))
        }
        let scores = try await engine.detectLanguage(samples: chunk.samples, candidates: ["en", "de"], model: "whisperkit/small")
        #expect(scores.first?.language == "en")
        await engine.unload()
    }
}
