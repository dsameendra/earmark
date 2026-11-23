import AppCore
import AudioCapture
import Foundation
import Testing

@testable import Transcription

/// Opt-in WER evaluation of voice processing with the local small Whisper model (SCR-014).
/// Run with `EARMARK_VOICE_EVAL=1 swift test --filter VoiceProcessingEvaluation`. It prints a table and asserts nothing about the
/// numbers: Whisper is noise-robust, so processing may not help, and the report is the point.
@Suite("Voice processing evaluation (opt-in; needs local model + fixtures)", .serialized)
struct VoiceProcessingEvaluationTests {
    private static let enabled = ProcessInfo.processInfo.environment["EARMARK_VOICE_EVAL"] == "1" && LocalAssets.smallModel != nil

    private func reference(_ relative: String) -> String? {
        let name = (relative as NSString).deletingPathExtension
        guard let wav = LocalAssets.search("fixtures/\(relative)", envKey: "EARMARK_FIXTURES_DIR") else { return nil }
        _ = name
        for candidate in [wav.deletingPathExtension().appendingPathExtension("txt")] + [
            wav.deletingLastPathComponent().appendingPathComponent("noisy.txt"),
        ] where FileManager.default.fileExists(atPath: candidate.path) {
            return try? String(contentsOf: candidate, encoding: .utf8)
        }
        return nil
    }

    @Test("WER by level on clean, noisy and hard fixtures", .enabled(if: enabled), .timeLimit(.minutes(30)))
    func table() async throws {
        let folder = try #require(LocalAssets.smallModel)
        let engine = WhisperKitEngine(locate: { _ in folder }, tokenizerFolder: LocalAssets.cacheRoot, defaultModel: "whisperkit/small")
        let files = [
            "en-noisy-synth-snr/clean_ref.wav", "en-noisy-synth-snr/speech84_plus_rain_snr10dB.wav",
            "en-noisy-synth-snr/speech84_plus_rain_snr0dB.wav", "en-hard-librispeech-other/other_3660.wav",
            "en-hard-librispeech-other/other_6455.wav",
        ]
        for relative in files {
            guard let wav = LocalAssets.search("fixtures/\(relative)", envKey: "EARMARK_FIXTURES_DIR"), let text = reference(relative) else {
                print("EVAL skip \(relative) (missing)")
                continue
            }
            var row = "EVAL \(relative):"
            for level in VoiceProcessingLevel.allCases {
                let options = TranscriptionOptions(
                    languageMode: .single("en"), useCase: .file, modelID: "whisperkit/small", voiceProcessing: level)
                let started = Date()
                let out = try await collect(FileTranscriptionPipeline().run(file: wav, options: options, engine: engine))
                let wer = wordErrorRate(reference: text, hypothesis: out.segments.map(\.text).joined(separator: " "))
                row += String(format: "  %@=%.3f (%.1fs)", level.rawValue, wer, Date().timeIntervalSince(started))
            }
            print(row)
        }
        await engine.unload()
    }
}
