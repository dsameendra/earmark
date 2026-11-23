import AppCore
import AudioCapture
import Foundation
import Testing
@testable import QwenASR

private let generalModel = ProcessInfo.processInfo.environment["EARMARK_QWEN_GENERAL_MODEL"]
private let generalFixture = ProcessInfo.processInfo.environment["EARMARK_QWEN_GENERAL_FIXTURE"]
private let multilingualFixtures = ProcessInfo.processInfo.environment["EARMARK_QWEN_MULTILINGUAL_FIXTURES"]

@Suite("Qwen multilingual native acceptance", .serialized, .enabled(if: generalModel != nil))
struct QwenMultilingualRealTests {
    @Test("English audio produces real words with the requested model and language", .enabled(if: generalFixture != nil), .timeLimit(.minutes(5)))
    func english() async throws {
        let model = try #require(generalModel)
        let fixture = try #require(generalFixture)
        let engine = QwenSinhalaEngine(locate: { _ in URL(fileURLWithPath: model) }, defaultModel: QwenModelProfile.multilingual06)
        let chunks = AsyncStream<AudioChunk> { continuation in
            let task = Task {
                do {
                    for try await chunk in AVFileDecoder().decode(file: URL(fileURLWithPath: fixture), chunkSeconds: 5, startingAt: 0) {
                        if chunk.startSeconds >= 15 { break }
                        continuation.yield(chunk)
                    }
                } catch { Issue.record(error) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        var segments: [Segment] = []
        for try await event in engine.stream(audio: chunks, options: TranscriptionOptions(languageMode: .single("en"), useCase: .file)) {
            if case .final(let segment) = event { segments.append(segment) }
        }
        let text = segments.map(\.text).joined(separator: " ")
        print("QWEN multilingual native English: \(text)")
        #expect(text.split(separator: " ").count >= 10)
        #expect(segments.allSatisfy { $0.languageCode == "en" && $0.words.isEmpty })
        #expect(!text.contains("<asr_text>"))
        await engine.unload()
    }

    /// Small checkpoint smoke gate, not a language-wide accuracy benchmark.
    /// The external fixture folder contains the pinned FLEURS provenance manifest.
    @Test("Four FLEURS languages retain their language and transcription", .enabled(if: multilingualFixtures != nil),
          .timeLimit(.minutes(5)), arguments: ["fr", "de", "es", "ja"])
    func multilingual(language: String) async throws {
        let folder = URL(fileURLWithPath: try #require(multilingualFixtures))
        let model = URL(fileURLWithPath: try #require(generalModel))
        let reference = try String(contentsOf: folder.appendingPathComponent(language + ".txt"), encoding: .utf8)
        let engine = QwenSinhalaEngine(locate: { _ in model }, defaultModel: QwenModelProfile.multilingual06)
        var segments: [Segment] = []
        for try await event in engine.transcribe(
            file: folder.appendingPathComponent(language + ".wav"),
            options: TranscriptionOptions(languageMode: .single(LanguageCode(language)), useCase: .file)
        ) {
            if case .final(let segment) = event { segments.append(segment) }
        }
        let text = segments.map(\.text).joined(separator: " ")
        let cer = Self.characterErrorRate(reference: reference, hypothesis: text)
        print("QWEN native \(language) CER=\(cer): \(text)")
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { $0.languageCode?.rawValue == language && $0.words.isEmpty })
        #expect(cer < 0.35)
        #expect(!text.contains("<asr_text>"))
        await engine.unload()
    }

    @Test("Unsegmented FLEURS diagnostic isolates model decoding from VAD", .enabled(if: multilingualFixtures != nil),
          .timeLimit(.minutes(5)), arguments: ["fr", "de", "es", "ja"])
    func unsegmented(language: String) async throws {
        let folder = URL(fileURLWithPath: try #require(multilingualFixtures))
        let recognizer = try await MLXQwenRecognizer.load(folder: URL(fileURLWithPath: #require(generalModel)))
        var samples: [Float] = []
        for try await chunk in AVFileDecoder().decode(file: folder.appendingPathComponent(language + ".wav"), chunkSeconds: 30, startingAt: 0) {
            samples += chunk.samples
        }
        let output = try await recognizer.recognize(samples: samples, maxTokens: 256, language: QwenModelProfile.languageNames[LanguageCode(language)])
        let reference = try String(contentsOf: folder.appendingPathComponent(language + ".txt"), encoding: .utf8)
        let cer = Self.characterErrorRate(reference: reference, hypothesis: output.text)
        print("QWEN unsegmented \(language) CER=\(cer): \(output.text)")
        #expect(cer < 0.35)
    }

    private static func characterErrorRate(reference: String, hypothesis: String) -> Double {
        func normalized(_ text: String) -> [Unicode.Scalar] {
            Array(text.lowercased().precomposedStringWithCanonicalMapping.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            })
        }
        let expected = normalized(reference), actual = normalized(hypothesis)
        var row = Array(0...expected.count)
        for (i, character) in actual.enumerated() {
            var next = [i + 1]
            for (j, other) in expected.enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (character == other ? 0 : 1)))
            }
            row = next
        }
        return Double(row[expected.count]) / Double(max(1, expected.count))
    }
}
