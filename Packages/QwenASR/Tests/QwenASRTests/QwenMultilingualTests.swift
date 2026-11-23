import AppCore
import AudioCapture
import Foundation
import Testing
@testable import QwenASR

private actor LanguageAwareRecognizer: SinhalaRecognizing {
    private(set) var languages: [String?] = []
    let detected: String?
    let text: String
    init(detected: String?, text: String) { self.detected = detected; self.text = text }
    func recognize(samples: [Float], maxTokens: Int) async throws -> String { text }
    func recognize(samples: [Float], maxTokens: Int, language: String?) async throws -> QwenRecognition {
        languages.append(language)
        return QwenRecognition(text: text, language: detected ?? language)
    }
}

@Suite("Qwen multilingual checkpoint profiles")
struct QwenMultilingualTests {
    private func recognize(model: ModelID, mode: LanguageMode, recognizer: LanguageAwareRecognizer) async throws -> [Segment] {
        let engine = QwenSinhalaEngine(
            locate: { _ in FileManager.default.temporaryDirectory }, defaultModel: model,
            vad: AmplitudeVAD(), loader: { _ in recognizer })
        let audio = AsyncStream<AudioChunk> {
            $0.yield(AudioChunk(samples: Array(repeating: 0.2, count: 24_000), startSeconds: 0, source: .file))
            $0.finish()
        }
        var segments: [Segment] = []
        for try await event in engine.stream(audio: audio, options: TranscriptionOptions(languageMode: mode, useCase: .live)) {
            if case .final(let segment) = event { segments.append(segment) }
        }
        return segments
    }

    @Test("general Hindi survives specialist script guard and uses the correct prompt")
    func hindi() async throws {
        let recognizer = LanguageAwareRecognizer(detected: nil, text: "यह एक परीक्षण है")
        let out = try await recognize(model: QwenModelProfile.multilingual06, mode: .single("hi"), recognizer: recognizer)
        #expect(out.first?.text == "यह एक परीक्षण है")
        #expect(out.first?.languageCode == "hi")
        #expect(await recognizer.languages == ["Hindi"])
    }

    @Test("auto mode retains the model's detected language")
    func detection() async throws {
        let recognizer = LanguageAwareRecognizer(detected: "French", text: "Bonjour le monde")
        let out = try await recognize(model: QwenModelProfile.multilingual17, mode: .autoDetect, recognizer: recognizer)
        #expect(out.first?.languageCode == "fr")
        #expect(await recognizer.languages.count == 1)
        #expect(await recognizer.languages.first! == nil)
    }

    @Test("unrecognized language headers are not labeled Sinhala")
    func unknownDetection() async throws {
        let out = try await recognize(
            model: QwenModelProfile.multilingual06, mode: .autoDetect,
            recognizer: LanguageAwareRecognizer(detected: "unexpected", text: "words"))
        #expect(out.first?.languageCode == "und")
    }

    @Test("general checkpoints do not inherit specialist Sinhala support")
    func rejectsSinhala() async {
        do {
            _ = try await recognize(model: QwenModelProfile.multilingual06, mode: .single("si"), recognizer: LanguageAwareRecognizer(detected: nil, text: "wrong"))
            Issue.record("General Qwen must reject Sinhala")
        } catch { #expect(error as? AppError == .unsupportedLanguage("si")) }
        #expect(QwenModelProfile.profile(for: "unknown/model") == nil)
    }
}
