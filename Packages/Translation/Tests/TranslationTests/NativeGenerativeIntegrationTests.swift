import AppCore
import Darwin
import Foundation
import Testing
import TextModelProfiles
@testable import EarmarkTranslation

private let textHelper = ProcessInfo.processInfo.environment["EARMARK_NATIVE_TEXT_HELPER"]
private let ct2Helper = ProcessInfo.processInfo.environment["EARMARK_NATIVE_NLLB_HELPER"]
private let nllbFolder = ProcessInfo.processInfo.environment["EARMARK_NLLB_MODEL_DIR"]
private let generativeRoot = ProcessInfo.processInfo.environment["EARMARK_GENERATIVE_MODEL_ROOT"]

@Suite("Actual cross-backend translation ownership", .serialized,
       .enabled(if: textHelper != nil && ct2Helper != nil && nllbFolder != nil && generativeRoot != nil))
struct NativeGenerativeIntegrationTests {
    @Test func realProcessesExitBeforeSwitchingAndCancellationRestartsTheRightModel() async throws {
        let pool = CTranslate2RuntimePool(nativeExecutable: URL(fileURLWithPath: try #require(ct2Helper)),
                                         generativeExecutable: URL(fileURLWithPath: try #require(textHelper)))
        let root = URL(fileURLWithPath: try #require(generativeRoot))
        let nllb = pool.runtime(profile: CTranslate2ModelProfile.nllb)
        let hymt = pool.runtime(profile: GenerativeProfile.hymt18)
        let gemma = pool.runtime(profile: GenerativeProfile.gemma4)
        do {
            try await nllb.load(modelFolder: URL(fileURLWithPath: #require(nllbFolder)))
            let original = try await nllb.translate(["Good morning everyone."], source: "eng_Latn", target: "sin_Sinh")
            #expect(original == ["සුබ උදෑසනක් හැමෝටම."])
            let nllbPID = try #require(await pool.workerProcessIdentifier())
            try await hymt.load(modelFolder: root.appendingPathComponent("hymt18-q4"))
            let hymtPID = try #require(await pool.workerProcessIdentifier())
            #expect(nllbPID != hymtPID && Darwin.kill(nllbPID, 0) == -1)
            let text = "Do not cancel order AB-104."
            let input = items([text])
            let engine = GenerativeTranslationEngine(profile: .hymt18,
                models: FolderModelManager(folder: root.appendingPathComponent("hymt18-q4"), modelID: GenerativeTranslationEngine.modelID(for: .hymt18)), runtime: hymt)
            let translated = try await collect(engine.translate(items: input, from: "en", to: "de"))
            #expect(translated.first?.segmentID == input.first?.segmentID)
            #expect(translated.first?.engine == engine.id)
            #expect(translated.first?.text.contains("AB-104") == true)
            #expect(translated.first?.text.lowercased().contains("nicht") == true)
            await nllb.unload() // An evicted owner's release must leave Hy-MT alive.
            #expect(await pool.workerProcessIdentifier() == hymtPID)
            try await gemma.load(modelFolder: root.appendingPathComponent("gemma4-q4"))
            #expect(Darwin.kill(hymtPID, 0) == -1)
            let output = try await gemma.translate(["The meeting starts tomorrow."], source: "en", target: "de")
            #expect(output.first?.lowercased().contains("morgen") == true)
            try await nllb.load(modelFolder: URL(fileURLWithPath: #require(nllbFolder)))
            #expect(try await nllb.translate(["Good morning everyone."], source: "eng_Latn", target: "sin_Sinh") == original)
            await gemma.unload()
            try await hymt.load(modelFolder: root.appendingPathComponent("hymt18-q4"))
            let pending = Task { try await hymt.translate([String(repeating: "The meeting starts tomorrow morning. ", count: 20)], source: "en", target: "de") }
            try await Task.sleep(for: .milliseconds(100))
            let started = ContinuousClock.now
            pending.cancel()
            await #expect(throws: CancellationError.self) { try await pending.value }
            #expect(ContinuousClock.now - started < .seconds(1))
            let again = try await hymt.translate(["Hello world."], source: "en", target: "de")
            #expect(again.first?.lowercased().contains("hallo") == true)
        } catch {
            await nllb.unload(); await hymt.unload(); await gemma.unload()
            throw error
        }
        await nllb.unload(); await hymt.unload(); await gemma.unload()
        #expect(await pool.workerProcessIdentifier() == nil)
    }
}
