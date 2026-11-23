import AppCore
import Foundation
import Testing
@testable import Transcription

@Suite("Native speech adapter contracts")
struct NativeAdapterContractTests {
    @Test("unknown Parakeet checkpoints do not acquire or load artifacts")
    func parakeetRejectsUnknownModel() async {
        let engine = ParakeetEngine(locate: { _ in Issue.record("Unexpected model lookup"); return URL(fileURLWithPath: "/nonexistent") })
        #expect(await engine.supportedLanguages(model: "unknown") == [])
        do { try await engine.prepare(model: "unknown"); Issue.record("Expected model rejection") }
        catch { #expect(error as? AppError == .modelNotInstalled("unknown")) }
        #expect(await engine.supportedLanguages(model: ParakeetEngine.modelV3).count == 25)
        #expect(await engine.supportedLanguages(model: ParakeetEngine.modelUltra) == ParakeetEngine.languages)
    }

    @Test("Cohere accepts 14 languages, but refuses Live and unknown models")
    func cohereContracts() async {
        let engine = CohereEngine(locate: { _ in Issue.record("Unexpected model lookup"); return URL(fileURLWithPath: "/nonexistent") })
        #expect(await engine.supportedLanguages(model: nil).count == 14)
        #expect(await engine.supportedLanguages(model: "unknown") == [])
        do { try await engine.prepare(model: "unknown"); Issue.record("Expected model rejection") }
        catch { #expect(error as? AppError == .modelNotInstalled("unknown")) }
        do {
            for try await _ in engine.stream(audio: AsyncStream { $0.finish() }, options: TranscriptionOptions(languageMode: .single("en"), useCase: .live)) {}
            Issue.record("File-only engine must refuse Live")
        } catch { #expect(String(describing: error).contains("file transcription only")) }
    }
}
