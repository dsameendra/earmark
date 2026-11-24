import AppCore
import Foundation
import Testing

@testable import EarmarkTranslation

private let nativePath = ProcessInfo.processInfo.environment["EARMARK_NATIVE_NLLB_HELPER"]
private let nativeModel = ProcessInfo.processInfo.environment["EARMARK_NLLB_MODEL_DIR"]
private let marianModel = ProcessInfo.processInfo.environment["EARMARK_MARIAN_MODEL_DIR"]
private let madladModel = ProcessInfo.processInfo.environment["EARMARK_MADLAD_MODEL_DIR"]

@Suite("Native worker integration", .serialized, .enabled(if: nativePath != nil && nativeModel != nil))
struct NativeWorkerTests {
    @Test func translatesCancelsAndRestartsWithoutPython() async throws {
        let helper = try #require(nativePath)
        let folder = try #require(nativeModel)
        let runtime = CTranslate2WorkerRuntime(nativeExecutable: URL(fileURLWithPath: helper))
        try await runtime.load(modelFolder: URL(fileURLWithPath: folder))
        let output = try await runtime.translate(["Good morning everyone."], source: "eng_Latn", target: "sin_Sinh")
        #expect(output == ["සුබ උදෑසනක් හැමෝටම."])
        let pending = Task {
            try await runtime.translate(
                Array(repeating: String(repeating: "The meeting starts in five minutes. ", count: 15), count: 8), source: "eng_Latn",
                target: "sin_Sinh")
        }
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("A cancelled native request returned translations")
        } catch { #expect(error is CancellationError) }
        #expect(clock.now - start < .seconds(1), "Cancellation must release the native request promptly")
        let again = try await runtime.translate(["Good morning everyone."], source: "eng_Latn", target: "sin_Sinh")
        #expect(again == output, "Cancellation must not poison subsequent requests")
        await runtime.unload()
    }
}

@Suite("Native model-family switching", .serialized,
       .enabled(if: nativePath != nil && nativeModel != nil && madladModel != nil && marianModel != nil))
struct NativeFamilySwitchingTests {
    @Test func poolSwitchesAllThreeArchitecturesAndReloadsTheEvictedCheckpoint() async throws {
        let pool = CTranslate2RuntimePool(nativeExecutable: URL(fileURLWithPath: try #require(nativePath)))
        let nllb = pool.runtime(profile: .nllb)
        let madladRuntime = pool.runtime(profile: .madlad)
        let marian = pool.runtime(profile: .marian)
        let folder = URL(fileURLWithPath: try #require(madladModel))
        let madlad = MADLADEngine(models: FolderModelManager(folder: folder, modelID: MADLADEngine.modelID), runtime: madladRuntime)
        try await nllb.load(modelFolder: URL(fileURLWithPath: #require(nativeModel)))
        let original = try await nllb.translate(["Good morning everyone."], source: "eng_Latn", target: "sin_Sinh")
        let translated = try await collect(madlad.translate(items: items(["The meeting starts tomorrow morning."]), from: "en", to: "fr"))
        #expect(translated.first?.text == "La réunion commence demain matin.")
        #expect(translated.first?.engine == "madlad")
        try await marian.load(modelFolder: URL(fileURLWithPath: #require(marianModel)))
        #expect(try await marian.translate(["Hello world."], source: "en", target: "de") == ["Hallo Welt."])
        // This old owner has been evicted: its release must leave Marian usable.
        await madlad.unload()
        #expect(try await marian.translate(["Hello world."], source: "en", target: "de") == ["Hallo Welt."])
        #expect(try await nllb.translate(["Good morning everyone."], source: "eng_Latn", target: "sin_Sinh") == original)
        await marian.unload()
        await nllb.unload()
    }
}

@Suite("Native OPUS worker integration", .serialized, .enabled(if: nativePath != nil && marianModel != nil))
struct NativeOPUSWorkerTests {
    @Test func usesMarianProfileThroughTheShippingProtocol() async throws {
        let runtime = CTranslate2WorkerRuntime(
            nativeExecutable: URL(fileURLWithPath: try #require(nativePath)), profile: .marian)
        let folder = URL(fileURLWithPath: try #require(marianModel))
        let engine = OPUSTranslationEngine(runtime: runtime, locate: { model in
            guard model == "opus/en-de-ct2-int8" else { throw AppError.modelNotInstalled(model) }
            return folder
        })
        let input = items(["The meeting starts tomorrow morning.", "Hello world."])
        let output = try await collect(engine.translate(items: input, from: "en", to: "de"))
        #expect(output.map(\.text) == ["Das Treffen beginnt morgen früh.", "Hallo Welt."])
        #expect(output.map(\.segmentID) == input.map(\.segmentID))
        #expect(output.allSatisfy { $0.engine == "opus-mt" && !$0.isLowConfidence })
        await engine.unload()
        // Loading and translating again must restart the native helper cleanly.
        let again = try await collect(engine.translate(items: items(["Hello world."]), from: "en", to: "de"))
        #expect(again.first?.text == "Hallo Welt.")
        await engine.unload()
    }
}
