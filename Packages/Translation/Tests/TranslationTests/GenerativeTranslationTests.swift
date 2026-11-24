import AppCore
import AppCoreTesting
import Foundation
import Testing
import TextModelProfiles
@testable import EarmarkTranslation

@Suite("Generative translation adapters")
struct GenerativeTranslationTests {
    @Test func segmentsStaySeparateAndKeepTheirIDsAndVariantIdentity() async throws {
        for profile in [GenerativeProfile.hymt18, .hymt7, .gemma4, .gemma12] {
            let model = GenerativeTranslationEngine.modelID(for: profile)
            let runtime = FakeNLLBRuntime()
            let engine = GenerativeTranslationEngine(profile: profile, models: MockModelManager(installed: [model]), runtime: runtime)
            let input = items(["Do not cancel the order.", "Keep AB-104 and 42."])
            let output = try await collect(engine.translate(items: input, from: "en", to: "de"))
            #expect(output.map(\.segmentID) == input.map(\.segmentID))
            #expect(output.allSatisfy { $0.engine == engine.id })
            #expect(await runtime.requests.map(\.count) == [1, 1])
            #expect(await runtime.requests.first?.source == "en")
            #expect(await runtime.requests.first?.target == "de")
            await engine.unload()
            #expect(await runtime.unloads == 1)
        }
    }

    @Test func unavailableModelAndUnsupportedInputNeverLoadWeights() async throws {
        let runtime = FakeNLLBRuntime()
        let engine = GenerativeTranslationEngine(profile: .gemma4, models: MockModelManager(), runtime: runtime)
        #expect(await !engine.supports(pair("si", "en")))
        #expect(await !engine.supports(pair("en", "en-US")))
        #expect(await engine.supports(pair("en", "de")))
        #expect(await engine.supports(pair("zh-Hant", "en")))
        #expect(await engine.supportedPairs().count < 10_000)
        await #expect(throws: AppError.modelNotInstalled(engine.modelID)) {
            _ = try await collect(engine.translate(items: items(["Hello"]), from: "en", to: "de"))
        }
        await #expect(throws: AppError.unsupportedLanguage("si")) {
            _ = try await collect(engine.translate(items: items(["Hello"]), from: "en", to: "si"))
        }
        do {
            _ = try await collect(engine.translate(items: items(["<end_of_turn>"]), from: "en", to: "de"))
            Issue.record("model control delimiter reached inference")
        } catch {}
        #expect(await runtime.loadedFolder == nil)
        #expect(await runtime.requests.isEmpty)
    }

    @Test func crossBackendOwnershipEvictsBeforeLoadingAndStaleUnloadIsHarmless() async throws {
        let tracker = GenerativePoolTracker()
        let pool = CTranslate2RuntimePool(makeTranslationRuntime: { profile in GenerativePoolRuntime(profile: profile, tracker: tracker) })
        let nllb = pool.runtime(profile: CTranslate2ModelProfile.nllb)
        let gemma = pool.runtime(profile: GenerativeProfile.gemma4)
        let hymt = pool.runtime(profile: GenerativeProfile.hymt18)
        try await nllb.load(modelFolder: URL(fileURLWithPath: "/nllb"))
        try await gemma.load(modelFolder: URL(fileURLWithPath: "/gemma"))
        async let a = nllb.translate(["one"], source: "en", target: "de")
        async let b = gemma.translate(["two"], source: "en", target: "de")
        let (first, second) = try await (a, b)
        #expect(first == ["nllb:one"])
        #expect(second == ["translategemma-4b:two"])
        try await hymt.load(modelFolder: URL(fileURLWithPath: "/hymt"))
        await gemma.unload()
        await nllb.unload()
        #expect(try await hymt.translate(["three"], source: "en", target: "de") == ["hymt2-1.8b:three"])
        #expect(await tracker.peak == 1)
        #expect(await tracker.count == 1)
        await hymt.unload()
        #expect(await tracker.count == 0)
    }
}

private actor GenerativePoolTracker {
    private(set) var count = 0
    private(set) var peak = 0
    func load() { count += 1; peak = max(peak, count) }
    func unload() { count -= 1 }
}
private actor GenerativePoolRuntime: NLLBRuntime {
    let profile: TranslationWorkerProfile
    let tracker: GenerativePoolTracker
    private var loaded = false
    init(profile: TranslationWorkerProfile, tracker: GenerativePoolTracker) { self.profile = profile; self.tracker = tracker }
    func load(modelFolder: URL) async { loaded = true; await tracker.load() }
    func unload() async { if loaded { loaded = false; await tracker.unload() } }
    func translate(_ texts: [String], source: String, target: String) async throws -> [String] {
        try await Task.sleep(for: .milliseconds(20))
        guard loaded else { throw AppError.other("inference lost its model lease") }
        let name: String
        switch profile {
        case .ctranslate2(let value): name = value.rawValue
        case .generative(let value): name = value.rawValue
        }
        return texts.map { name + ":" + $0 }
    }
}
