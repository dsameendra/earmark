import AppCore
import AudioCapture
import Foundation
import Speech
import Testing

@testable import Transcription

/// Hosted CI machines are virtual and have no on-device speech engine; these checks need a real Mac.
private let appleSpeechAvailable: Bool = SpeechTranscriber.isAvailable

@Suite("AppleSpeechEngine")
struct AppleSpeechEngineTests {
    private let silence = AsyncStream<AudioChunk> { $0.finish() }

    @Test("supported languages come from SpeechTranscriber and exclude Sinhala", .enabled(if: appleSpeechAvailable, "needs the on-device speech engine"))
    func languages() async {
        let languages = await AppleSpeechEngine().supportedLanguages(model: nil)
        #expect(languages.contains("en"))
        #expect(!languages.contains("si"))
    }

    @Test("Sinhala is reported unsupported (no Apple locale)", .enabled(if: appleSpeechAvailable, "needs the on-device speech engine"))
    func sinhalaUnsupported() async {
        let engine = AppleSpeechEngine()
        #expect(await engine.assetStatus(for: "si") == .unsupported)
        do {
            for try await _ in engine.stream(audio: silence, options: TranscriptionOptions(languageMode: .single("si"), useCase: .live)) {}
            Issue.record("expected throw")
        } catch { #expect(error as? AppError == .unsupportedLanguage("si")) }
    }

    @Test("auto-detect is rejected because SpeechAnalyzer cannot identify languages")
    func autoDetectRejected() async {
        let engine = AppleSpeechEngine()
        do {
            for try await _ in engine.stream(audio: silence, options: TranscriptionOptions(languageMode: .autoDetect, useCase: .live)) {}
            Issue.record("expected throw")
        } catch { #expect(error is AppError) }
    }

    @Test("English assets are either installed or the engine reports modelNotInstalled", .enabled(if: appleSpeechAvailable, "needs the on-device speech engine"))
    func englishAssets() async throws {
        let engine = AppleSpeechEngine()
        let status = await engine.assetStatus(for: "en")
        guard status != .unsupported else { return }
        do {
            for try await _ in engine.stream(audio: silence, options: TranscriptionOptions(languageMode: .single("en"), useCase: .live)) {}
            #expect(status == .installed)
        } catch {
            #expect(status != .installed)
            #expect(error as? AppError == .modelNotInstalled(RoutingTargets.appleSpeech))
        }
    }

    /// Real SpeechAnalyzer run on the fixture; skipped unless English assets and the fixture are present.
    @Test("live stream emits partials and word-timed finals on the fixture")
    func realTranscription() async throws {
        let engine = AppleSpeechEngine()
        let status = await engine.assetStatus(for: "en")
        print("INTEGRATION apple en asset status: \(status)")
        guard status == .installed, let wav = LocalAssets.fixtureWAV else { return }
        var chunks: [AudioChunk] = []
        for try await chunk in AVFileDecoder().decode(file: wav, chunkSeconds: 1, startingAt: 5) {
            chunks.append(chunk)
            if chunks.count == 20 { break }
        }
        let audio = AsyncStream<AudioChunk> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        var partials = 0
        var finals: [Segment] = []
        for try await event in engine.stream(audio: audio, options: TranscriptionOptions(languageMode: .single("en"), useCase: .live)) {
            switch event {
            case .partial: partials += 1
            case .final(let segment): finals.append(segment)
            default: break
            }
        }
        print("INTEGRATION apple partials=\(partials) finals=\(finals.map(\.text))")
        #expect(!finals.isEmpty)
        #expect(finals.contains { !$0.words.isEmpty })
        // Times are on the media timeline (chunks start at 5 s).
        #expect(finals.allSatisfy { $0.start >= 4.9 })
    }
}
