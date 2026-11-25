import AppCore
import AppCoreTesting
import Foundation
import Testing
@testable import EarmarkTranslation

@Suite("Directional OPUS packs")
struct OPUSTests {
    @Test func onlyOffersTheSixImplementedDirections() async {
        let engine = OPUSTranslationEngine(models: MockModelManager(), runtime: PackRuntime())
        #expect(await engine.supportedPairs().count == 6)
        #expect(await engine.supports(pair("en", "de")))
        #expect(await engine.supports(pair("de", "en")))
        #expect(await !engine.supports(pair("de", "fr")))
        #expect(await !engine.supports(pair("en", "si")))
        #expect(await !engine.supports(pair("en", "en")))
        #expect(await !engine.supports(pair("en", "de-Cyrl")))
        #expect(await !engine.supports(pair("en-US", "de")))
    }

    @Test func missingDirectionDoesNotDownloadOrUseTheOppositePack() async throws {
        let manager = MockModelManager(installed: ["opus/en-de-ct2-int8"])
        let engine = OPUSTranslationEngine(models: manager, runtime: PackRuntime())
        await #expect(throws: AppError.modelNotInstalled("opus/de-en-ct2-int8")) {
            try await collect(engine.translate(items: items(["Hallo"]), from: "de", to: "en"))
        }
        #expect(await manager.ensureAvailableCalls().isEmpty)
    }

    @Test func packSwitchCannotRaceWithAnInFlightTranslation() async throws {
        let runtime = PackRuntime()
        let engine = OPUSTranslationEngine(runtime: runtime, locate: { URL(fileURLWithPath: "/packs/" + $0.rawValue) })
        async let german = collect(engine.translate(items: items(["Good morning"]), from: "en", to: "de"))
        async let english = collect(engine.translate(items: items(["Guten Morgen"]), from: "de", to: "en"))
        let (a, b) = try await (german, english)
        #expect(a.first?.text == "en-de-ct2-int8:de:Good morning")
        #expect(b.first?.text == "de-en-ct2-int8:en:Guten Morgen")
        #expect(a.first?.engine == "opus-mt")
        await engine.unload()
        #expect(await runtime.isUnloaded)
    }

    @Test func unsupportedPairFailsBeforeLoading() async throws {
        let runtime = PackRuntime()
        let engine = OPUSTranslationEngine(models: MockModelManager(), runtime: runtime)
        await #expect(throws: TranslationFailure.noEngine(pair("de", "fr"))) {
            try await collect(engine.translate(items: items(["Hallo"]), from: "de", to: "fr"))
        }
        #expect(await runtime.isUnloaded)
    }
}

private actor PackRuntime: NLLBRuntime {
    private var folder: URL?
    var isUnloaded: Bool { folder == nil }
    func load(modelFolder: URL) { folder = modelFolder }
    func unload() { folder = nil }
    func translate(_ texts: [String], source: String, target: String) async throws -> [String] {
        // Deliberate suspension: without an engine-wide gate a second pack load
        // changes this folder while the first request is still running.
        try await Task.sleep(for: .milliseconds(30))
        let identity = folder?.lastPathComponent ?? "unloaded"
        return texts.map { identity + ":" + target + ":" + $0 }
    }
}
