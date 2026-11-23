import AppCore
import AudioCapture
import Foundation
import Testing
@testable import QwenASR

private let generalModel = ProcessInfo.processInfo.environment["EARMARK_QWEN_GENERAL_MODEL"]
private let generalFixture = ProcessInfo.processInfo.environment["EARMARK_QWEN_GENERAL_FIXTURE"]

@Suite("Qwen multilingual native acceptance", .serialized, .enabled(if: generalModel != nil && generalFixture != nil))
struct QwenMultilingualRealTests {
    @Test("English audio produces real words with the requested model and language", .timeLimit(.minutes(5)))
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
}
