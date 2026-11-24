import AppCore
import AppCoreTesting
import Foundation
import Testing
@testable import EarmarkTranslation

@Suite("MADLAD native engine policy")
struct MADLADTests {
    @Test func mappedLanguagesAreBroadButUnmappedScriptsAreNotSilentlyChanged() async {
        let engine = MADLADEngine(models: MockModelManager(), runtime: FakeNLLBRuntime())
        #expect(await engine.supportedPairs().count == 27 * 26)
        #expect(await engine.supports(pair("ta", "si")))
        #expect(await engine.supports(pair("ja", "de")))
        #expect(await !engine.supports(pair("en", "zh-Hant")))
        #expect(await !engine.supports(pair("en", "unknown")))
        #expect(await !engine.supports(pair("en", "en")))
    }

    @Test func legacyGGUFDoesNotSatisfyTheNativeCheckpointRequirement() async throws {
        let engine = MADLADEngine(models: MockModelManager(installed: ["madlad/400-3b-mt-q4k"]), runtime: FakeNLLBRuntime())
        await #expect(throws: AppError.modelNotInstalled(MADLADEngine.modelID)) {
            try await collect(engine.translate(items: items(["Hello"]), from: "en", to: "si"))
        }
    }

    @Test func sendsMADLADCodesAndKeepsSegmentIdentity() async throws {
        let runtime = FakeNLLBRuntime()
        let engine = MADLADEngine(models: MockModelManager(installed: [MADLADEngine.modelID]), runtime: runtime)
        let input = items(["வணக்கம்"])
        let output = try await collect(engine.translate(items: input, from: "ta", to: "si"))
        #expect(output.first?.segmentID == input.first?.segmentID)
        #expect(output.first?.engine == "madlad")
        #expect(await runtime.requests.first?.source == "ta")
        #expect(await runtime.requests.first?.target == "si")
        await engine.unload()
        #expect(await runtime.unloads == 1)
    }

    @Test func routerPreservesTheRequestedScriptForEngineValidation() async {
        let engine = MADLADEngine(models: MockModelManager(installed: [MADLADEngine.modelID]), runtime: FakeNLLBRuntime())
        let requested = pair("en", "zh-Hant")
        let router = DefaultTranslationRouter(
            apple: FakeEngine(id: "apple.translation", pairs: []), nllb: nil, additional: [engine], selectedEngine: { "madlad" })
        await #expect(throws: TranslationFailure.noEngine(requested)) { _ = try await router.engine(for: requested) }
    }
}
