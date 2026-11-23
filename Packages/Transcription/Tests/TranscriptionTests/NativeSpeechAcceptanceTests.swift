import AppCore
import Foundation
import Testing
@testable import Transcription

private let parakeetFolder = ProcessInfo.processInfo.environment["EARMARK_PARAKEET_MODEL"]
private let cohereFolder = ProcessInfo.processInfo.environment["EARMARK_COHERE_MODEL"]

@Suite("Native speech checkpoint acceptance", .serialized)
struct NativeSpeechAcceptanceTests {
    private func evaluate(_ engine: any TranscriptionEngine, model: ModelID) async throws {
        let file = try #require(LocalAssets.fixtureWAV)
        let reference = try String(contentsOf: #require(LocalAssets.fixtureText), encoding: .utf8)
        var segments: [Segment] = []
        for try await event in engine.transcribe(file: file, options: TranscriptionOptions(languageMode: .single("en"), useCase: .file, modelID: model)) {
            if case .final(let segment) = event { segments.append(segment) }
        }
        let text = segments.map(\.text).joined(separator: " ")
        let wer = wordErrorRate(reference: reference, hypothesis: text)
        print("NATIVE ASR \(model) segments=\(segments.count) WER=\(wer): \(text)")
        #expect(!segments.isEmpty)
        #expect(wer < 0.25)
        #expect(segments.allSatisfy { $0.languageCode == "en" && $0.start >= 0 && $0.end >= $0.start })
        for segment in segments {
            #expect(segment.words.allSatisfy { $0.start >= segment.start && $0.end <= segment.end && $0.end >= $0.start })
        }
        await engine.unload()
    }

    @Test("Parakeet v3 transcribes the real file with useful alignment", .enabled(if: parakeetFolder != nil), .timeLimit(.minutes(5)))
    func parakeetV3() async throws {
        let folder = URL(fileURLWithPath: try #require(parakeetFolder))
        try await evaluate(ParakeetEngine(locate: { _ in folder }), model: ParakeetEngine.modelV3)
    }

    @Test("Cohere transcribes the real file without truncation", .enabled(if: cohereFolder != nil), .timeLimit(.minutes(5)))
    func cohere() async throws {
        let folder = URL(fileURLWithPath: try #require(cohereFolder))
        try await evaluate(CohereEngine(locate: { _ in folder }), model: CohereEngine.modelID)
    }
}
