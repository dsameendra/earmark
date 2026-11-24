import AppCore
import AppCoreTesting
import Foundation
import Testing

@testable import EarmarkTranslation

/// Opt-in real-engine checks: `EARMARK_HW_SMOKE=1 swift test --filter HardwareSmoke`.
/// NLLB additionally needs `EARMARK_NLLB_PYTHON` (a python with ctranslate2 + sentencepiece) and `EARMARK_NLLB_MODEL_DIR`
/// (the downloaded CT2 int8 folder, kept in a gitignored cache; never committed).
private let smokeEnabled = ProcessInfo.processInfo.environment["EARMARK_HW_SMOKE"] == "1"

private let english = [
    "Good morning everyone.", "The meeting starts in five minutes.", "Can we review the budget before Friday?",
    "Please send me the updated report by tomorrow afternoon.",
    "We decided to postpone the launch because the tests are still failing.",
]

private func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

@Suite("HardwareSmoke", .enabled(if: smokeEnabled))
struct HardwareSmokeTests {
    @Test("Apple Translation en to de/fr/ja on this Mac")
    func apple() async throws {
        let engine = AppleTranslationEngine()
        for target in ["de", "fr", "ja"] as [LanguageCode] {
            let status = await SystemAppleTranslationBackend().status(from: "en", to: target)
            print("SMOKE apple en->\(target) status=\(status)")
            guard status == .installed else { continue }
            let clock = ContinuousClock()
            let start = clock.now
            let out = try await collect(engine.translate(items: items(english), from: "en", to: target))
            let elapsed = ms(clock.now - start)
            print(String(format: "SMOKE apple en->%@ %d segments in %.0f ms (first call includes session setup)", target.rawValue, out.count, elapsed))
            for (src, o) in zip(english, out) { print("SMOKE   \(src) => \(o.text)") }
            let start2 = clock.now
            _ = try await collect(engine.translate(items: items(english), from: "en", to: target))
            print(String(format: "SMOKE apple en->%@ warm: %.0f ms", target.rawValue, ms(clock.now - start2)))
            #expect(out.count == english.count)
            #expect(zip(english, out).allSatisfy { source, output in !output.text.isEmpty && output.text != source })
        }
        // Sinhala is unsupported by Apple
        #expect(await !engine.supports(pair("en", "si")))
    }

    @Test("Apple supportedLanguages and Sinhala status")
    func languages() async {
        let backend = SystemAppleTranslationBackend()
        let langs = await backend.supportedLanguages()
        print("SMOKE apple supported languages: \(langs.count) \(langs.map(\.rawValue).sorted().joined(separator: ","))")
        print("SMOKE apple en->si: \(await backend.status(from: "en", to: "si"))")
        #expect(!langs.isEmpty)
    }

    @Test("NLLB en<->si via CTranslate2 worker")
    func nllb() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let python = env["EARMARK_NLLB_PYTHON"], let dir = env["EARMARK_NLLB_MODEL_DIR"] else {
            print("SMOKE nllb skipped: EARMARK_NLLB_PYTHON / EARMARK_NLLB_MODEL_DIR not set")
            return
        }
        let runtime = CTranslate2WorkerRuntime(pythonExecutable: URL(fileURLWithPath: python))
        let clock = ContinuousClock()
        let loadStart = clock.now
        try await runtime.load(modelFolder: URL(fileURLWithPath: dir))
        print(String(format: "SMOKE nllb load: %.0f ms", ms(clock.now - loadStart)))

        let manager = FolderModelManager(folder: URL(fileURLWithPath: dir))
        let engine = NLLBEngine(models: manager, runtime: runtime)
        let enSi = try await { () -> [TranslatedSegment] in
            let t = clock.now
            let out = try await collect(engine.translate(items: items(english), from: "en", to: "si"))
            print(String(format: "SMOKE nllb en->si %d segments: %.0f ms", out.count, ms(clock.now - t)))
            return out
        }()
        for (src, o) in zip(english, enSi) { print("SMOKE   \(src) => \(o.text) [lowConfidence=\(o.isLowConfidence)]") }
        #expect(enSi.allSatisfy { $0.isLowConfidence })

        let siBack = enSi.map { TranslationItem(segmentID: $0.segmentID, text: $0.text) }
        let t = clock.now
        let back = try await collect(engine.translate(items: siBack, from: "si", to: "en"))
        print(String(format: "SMOKE nllb si->en %d segments: %.0f ms", back.count, ms(clock.now - t)))
        for (src, o) in zip(english, back) { print("SMOKE   roundtrip \(src) => \(o.text)") }
        #expect(back.count == english.count && back.allSatisfy { !$0.isLowConfidence })
        await engine.unload()
    }
}

/// Minimal `ModelManaging` that reports the NLLB model as installed at a fixed folder.
