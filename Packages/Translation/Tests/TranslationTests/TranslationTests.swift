import AppCore
import AppCoreTesting
import Foundation
import Testing
import Translation

@testable import EarmarkTranslation

@Suite("Apple engine")
struct AppleEngineTests {
    @Test("Apple availability and execution preserve Chinese writing systems")
    func scriptsArePreserved() async throws {
        let backend = FakeAppleBackend(languages: ["zh-Hans", "zh-Hant"], installed: [pair("zh-Hans", "zh-Hant")])
        let engine = AppleTranslationEngine(backend: backend)
        #expect(await engine.supports(pair("zh-CN", "zh-TW")))
        let output = try await collect(engine.translate(items: items(["汉字"]), from: "zh-CN", to: "zh-TW"))
        #expect(output.first?.text == "[zh-Hant] 汉字")
    }
    @Test("installed pair translates, in order, with ids preserved")
    func installed() async throws {
        let backend = FakeAppleBackend(installed: [pair("en", "de")])
        let engine = AppleTranslationEngine(backend: backend)
        let input = items(["Hello", "World"])
        let out = try await collect(engine.translate(items: input, from: "en", to: "de"))
        #expect(out.map(\.text) == ["[de] Hello", "[de] World"])
        #expect(out.map(\.segmentID) == input.map(\.segmentID))
        #expect(out.allSatisfy { $0.engine == "apple.translation" && !$0.isLowConfidence })
    }

    @Test("language pack not installed maps to modelNotInstalled (TRN-AC-15 hook)")
    func notInstalled() async {
        let engine = AppleTranslationEngine(backend: FakeAppleBackend(installed: []))
        await #expect(throws: AppError.modelNotInstalled("apple/translation")) {
            _ = try await collect(engine.translate(items: items(["Hi"]), from: "en", to: "de"))
        }
    }

    @Test("unsupported pair and Sinhala are rejected")
    func unsupported() async {
        let engine = AppleTranslationEngine(backend: FakeAppleBackend(languages: ["en", "si", "de"], installed: allPairs(["en", "si", "de"])))
        await #expect(throws: AppError.unsupportedLanguage("si")) {
            _ = try await collect(engine.translate(items: items(["Hi"]), from: "en", to: "si"))
        }
        #expect(await !engine.supports(pair("si", "en")))
    }

    @Test("Apple response IDs are reordered and incomplete, duplicate, unrelated or blank results fail")
    func responseValidation() throws {
        #expect(try SystemAppleTranslationBackend.orderedResponses([("1", "Zwei"), ("0", "Eins")], count: 2) == ["Eins", "Zwei"])
        for responses: [(String?, String)] in [ [("0", "Eins")], [("0", "Eins"), ("0", "Doppelt")],
            [("2", "Falsch"), ("0", "Eins")], [(nil, "Falsch"), ("0", "Eins")], [("0", "Eins"), ("1", "  ")] ] {
            #expect(throws: (any Error).self) { try SystemAppleTranslationBackend.orderedResponses(responses, count: 2) }
        }
    }

    @Test("Apple framework errors map to AppError")
    func errorMapping() {
        #expect(AppleTranslationEngine.map(Translation.TranslationError.notInstalled, to: "de") == .modelNotInstalled("apple/translation"))
        #expect(AppleTranslationEngine.map(Translation.TranslationError.unsupportedLanguagePairing, to: "de") == .unsupportedLanguage("de"))
        #expect(AppleTranslationEngine.map(Translation.TranslationError.alreadyCancelled, to: "de") == .cancelled)
        if case .engineFailure("apple.translation", _) = AppleTranslationEngine.map(Translation.TranslationError.internalError, to: "de") {} else {
            Issue.record("expected engineFailure")
        }
    }

    @Test("region subtags normalise to the primary language")
    func primarySubtag() async throws {
        let backend = FakeAppleBackend(installed: [pair("en", "de")])
        let engine = AppleTranslationEngine(backend: backend)
        let out = try await collect(engine.translate(items: items(["Hi"]), from: "en-US", to: "de-DE"))
        #expect(out.first?.text == "[de] Hi")
    }
}

@Suite("NLLB engine")
struct NLLBEngineTests {
    private func engine(installed: Bool, runtime: FakeNLLBRuntime = FakeNLLBRuntime()) -> NLLBEngine {
        let manager = MockModelManager(installed: installed ? ["nllb/200-distilled-600M"] : [])
        return NLLBEngine(models: manager, runtime: runtime)
    }

    @Test("missing model surfaces modelNotInstalled and never loads the runtime")
    func missing() async {
        let runtime = FakeNLLBRuntime()
        let e = engine(installed: false, runtime: runtime)
        await #expect(throws: AppError.modelNotInstalled("nllb/200-distilled-600M")) {
            _ = try await collect(e.translate(items: items(["x"]), from: "si", to: "en"))
        }
        #expect(await runtime.loadedFolder == nil)
    }

    @Test("Sinhala to English uses FLORES codes and is not low confidence")
    func siEn() async throws {
        let runtime = FakeNLLBRuntime()
        let e = engine(installed: true, runtime: runtime)
        let out = try await collect(e.translate(items: items(["a", "b"]), from: "si", to: "en"))
        #expect(out.map(\.text) == ["<eng_Latn> a", "<eng_Latn> b"])
        #expect(out.allSatisfy { !$0.isLowConfidence })
        #expect(await runtime.requests.first?.source == "sin_Sinh")
    }

    @Test("English to Sinhala is flagged low confidence (TRN-AC-07)")
    func enSi() async throws {
        let e = engine(installed: true)
        let out = try await collect(e.translate(items: items(["hello"]), from: "en", to: "si"))
        #expect(out.first?.isLowConfidence == true)
        #expect(out.first?.engine == "nllb")
    }

    @Test("pair support: Sinhala and English, no identical pair, no unknown language")
    func support() async {
        let e = engine(installed: true)
        #expect(await e.supports(pair("si", "en")))
        #expect(await e.supports(pair("en", "si")))
        #expect(await !e.supports(pair("en", "en")))
        #expect(await !e.supports(pair("en", "xx")))
    }

    @Test("unsupported writing systems never load or call NLLB")
    func unsupportedScripts() async throws {
        let runtime = FakeNLLBRuntime()
        let e = engine(installed: true, runtime: runtime)
        #expect(await !e.supports(pair("en", "zh-Cyrl")))
        #expect(await !e.supports(pair("en-Cyrl", "si")))
        #expect(NLLBLanguages.code(for: "zh-TW") == "zho_Hant")
        #expect(NLLBLanguages.code(for: "zh-Hans") == "zho_Hans")
        #expect(NLLBLanguages.code(for: "en-Latn") == "eng_Latn")
        do {
            _ = try await collect(e.translate(items: items(["hello"]), from: "en", to: "zh-Cyrl"))
            Issue.record("unsupported script was translated")
        } catch {}
        #expect(await runtime.loadedFolder == nil)
        #expect(await runtime.requests.isEmpty)
    }

    @Test("all checkpoint language tokens are mapped once; ambiguous scripts and merged dialects remain distinct")
    func completeInventory() async throws {
        #expect(NLLBLanguages.codes.count == 202)
        #expect(Set(NLLBLanguages.codes.values).count == 202)
        #expect(NLLBLanguages.code(for: "ace") == nil)
        #expect(NLLBLanguages.code(for: "sat") == nil)
        #expect(NLLBLanguages.code(for: "sat-Olck") == nil)
        #expect(NLLBLanguages.code(for: "sat-Beng") == "sat_Beng")
        #expect(NLLBLanguages.code(for: "ks") == nil)
        #expect(NLLBLanguages.code(for: "ks-Arab") == "kas_Arab")
        #expect(NLLBLanguages.code(for: "ks-Deva") == "kas_Deva")
        #expect(NLLBLanguages.code(for: "ajp") == "ajp_Arab")
        #expect(NLLBLanguages.code(for: "apc") == "apc_Arab")
        #expect(NLLBLanguages.code(for: "ak") == "aka_Latn")
        #expect(NLLBLanguages.code(for: "tw") == "twi_Latn")
        let runtime = FakeNLLBRuntime()
        let restricted = NLLBEngine(models: MockModelManager(installed: ["nllb/200-distilled-600M"]), runtime: runtime, languages: ["en-Latn", "si"])
        #expect(await restricted.supports(pair("en-US", "si")))
        #expect(await !restricted.supports(pair("en", "de")))
        let e = engine(installed: true, runtime: runtime)
        #expect(await e.supports(pair("zh-Hans", "zh-Hant")))
        #expect(await e.supports(pair("ks-Arab", "ks-Deva")))
        #expect(await !e.supports(pair("en-Latn", "eng")))
        _ = try await collect(e.translate(items: items(["test"]), from: "ks-Arab", to: "ks-Deva"))
        #expect(await runtime.requests.first?.source == "kas_Arab")
        #expect(await runtime.requests.first?.target == "kas_Deva")
    }

    @Test("unload releases the runtime")
    func unload() async {
        let runtime = FakeNLLBRuntime()
        let e = engine(installed: true, runtime: runtime)
        await e.unload()
        #expect(await runtime.unloads == 1)
    }
}

@Suite("Router")
struct RouterTests {
    @Test("distinct scripts route directly and pivot endpoints never lose their script")
    func scriptRoutes() async throws {
        let script = FakeEngine(id: "script", pairs: [pair("zh-Hans", "zh-Hant")])
        let first = FakeEngine(id: "first", pairs: [pair("sr-Latn", "en")])
        let second = FakeEngine(id: "second", pairs: [pair("en", "fr")])
        let router = DefaultTranslationRouter(apple: FakeEngine(id: "none", pairs: []), nllb: nil,
                                              cache: nil, additional: [script, first, second])
        #expect(try await router.engine(for: pair("zh-Hans", "zh-Hant")).id == "script")
        let pivot = try await router.engine(for: pair("sr-Latn", "fr"))
        #expect(pivot.id.rawValue.hasPrefix("pivot:"))
        let translated = try await collect(pivot.translate(items: items(["tekst"]), from: "sr-Latn", to: "fr"))
        #expect(translated.first?.text.contains("first:en:") == true)
        var events: [TranslationEvent] = []
        for try await event in TranslationCoordinator(router: router).translate(
            segments: [Segment(start: 0, end: 1, text: "汉字")], source: "zh-Hans", target: "zh-Hant") { events.append(event) }
        #expect(events.contains { if case .segment = $0 { true } else { false } })
        #expect(!events.contains { if case .skipped = $0 { true } else { false } })
    }
    @Test("automatic selection prefers an installed model; explicit selection retains its installation error")
    func installedPreference() async throws {
        let apple = FakeEngine(id: "apple.translation", pairs: [pair("en", "de")])
        let local = FakeEngine(id: "local", pairs: [pair("en", "de")])
        let router = DefaultTranslationRouter(apple: apple, nllb: nil, additional: [local], isReady: { engine, _ in engine == "local" })
        #expect(try await router.engine(for: pair("en", "de")).id == "local")
        let selected = DefaultTranslationRouter(apple: apple, nllb: nil, additional: [local], selectedEngine: { "apple.translation" }, isReady: { _, _ in false })
        #expect(try await selected.engine(for: pair("en", "de")).id == "apple.translation")
        let missing = DefaultTranslationRouter(apple: apple, nllb: nil, additional: [local], isReady: { _, _ in false })
        #expect(try await missing.engine(for: pair("en", "de")).id == "apple.translation")
    }

    let apple = FakeEngine(id: "apple.translation", pairs: allPairs(["en", "de", "fr", "ja", "hi"]))
    let nllb = FakeEngine(id: "nllb", pairs: allPairs(["si", "en", "ta", "hi", "bn", "ur"]))
    func router(cache: TranslationCache? = nil) -> DefaultTranslationRouter { .init(apple: apple, nllb: nllb, cache: cache) }

    @Test("Apple-supported pair goes to Apple (TRN-AC-01)")
    func appleFirst() async throws {
        #expect(try await router().engine(for: pair("en", "de")).id == "apple.translation")
        #expect(try await router().engine(for: pair("hi", "en")).id == "apple.translation")
    }

    @Test("Sinhala pairs go to NLLB and never to Apple (TRN-AC-02)")
    func sinhala() async throws {
        let greedyApple = FakeEngine(id: "apple.translation", pairs: allPairs(["en", "si", "de"]))
        let r = DefaultTranslationRouter(apple: greedyApple, nllb: nllb, cache: nil)
        #expect(try await r.engine(for: pair("si", "en")).id == "nllb")
        #expect(try await r.engine(for: pair("en", "si")).id == "nllb")
        await #expect(throws: TranslationFailure.noEngine(pair("de", "si")).self) {
            // de -> si needs a pivot; en->si is NLLB but de->en is not offered by the (nllb-only) fake here
            _ = try await DefaultTranslationRouter(apple: FakeEngine(id: "apple.translation", pairs: []), nllb: self.nllb, cache: nil)
                .engine(for: pair("de", "si"))
        }
    }

    @Test("Apple-unsupported non-Sinhala pair falls to NLLB")
    func nllbFallback() async throws {
        #expect(try await router().engine(for: pair("ta", "en")).id == "nllb")
        #expect(try await router().engine(for: pair("en", "ur")).id == "nllb")
    }

    @Test("Sinhala to a non-English Apple language pivots through English (row 5/6)")
    func pivot() async throws {
        let engine = try await router().engine(for: pair("si", "de"))
        let out = try await collect(engine.translate(items: items(["x"]), from: "si", to: "de"))
        #expect(out.first?.text == "apple.translation:de:nllb:en:x")
        #expect(out.first?.engine.rawValue.hasPrefix("pivot:") == true)
        let back = try await router().engine(for: pair("fr", "si"))
        let out2 = try await collect(back.translate(items: items(["y"]), from: "fr", to: "si"))
        #expect(out2.first?.text == "nllb:si:apple.translation:en:y")
    }

    @Test("pivot keeps low confidence from either hop")
    func pivotLowConfidence() async throws {
        let weakNLLB = FakeEngine(id: "nllb", pairs: allPairs(["si", "en"]), lowConfidence: true)
        let r = DefaultTranslationRouter(apple: apple, nllb: weakNLLB, cache: nil)
        let engine = try await r.engine(for: pair("de", "si"))
        let out = try await collect(engine.translate(items: items(["z"]), from: "de", to: "si"))
        #expect(out.first?.isLowConfidence == true)
    }

    @Test("same language and unknown source are clear failures (TRN-AC-06)")
    func skips() async {
        await #expect(throws: TranslationFailure.sameLanguage("en")) { _ = try await router().engine(for: pair("en", "en-GB")) }
        await #expect(throws: TranslationFailure.unknownSource) { _ = try await router().engine(for: pair("und", "en")) }
        await #expect(throws: TranslationFailure.unknownSource) { _ = try await router().engine(for: pair("", "en")) }
    }

    @Test("no NLLB installed build: Sinhala has no engine")
    func noNLLB() async {
        let r = DefaultTranslationRouter(apple: apple, nllb: nil, cache: nil)
        await #expect(throws: TranslationFailure.noEngine(pair("si", "en"))) { _ = try await r.engine(for: pair("si", "en")) }
    }

    @Test("router is deterministic for fixed capabilities")
    func pure() async throws {
        let ids = try await (0..<5).asyncMap { _ in try await router().engine(for: pair("en", "ja")).id }
        #expect(Set(ids.map(\.rawValue)).count == 1)
    }
}

extension Sequence {
    func asyncMap<T>(_ f: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out.append(try await f(e)) }
        return out
    }
}

@Suite("Batching, cache, cancellation")
struct BatchingTests {
    @Test("bounded batches, empty text skipped, per-segment results")
    func batches() async throws {
        let backend = FakeAppleBackend(installed: [pair("en", "de")])
        let engine = AppleTranslationEngine(backend: backend, maxItems: 10, maxCharacters: 100_000)
        var input = items((0..<95).map { "line \($0)" })
        input.insert(TranslationItem(segmentID: SegmentID(), text: "   "), at: 3)
        let out = try await collect(engine.translate(items: input, from: "en", to: "de"))
        #expect(out.count == 95)
        #expect(await backend.maxBatch <= 10)
        #expect(await backend.calls == 10)
    }

    @Test("an empty result fails the batch before attaching any translated rows")
    func blankBatchOutput() async {
        var result: [TranslatedSegment] = []
        do {
            for try await item in streamInBatches(items: items(["One", "Two"]), maxItems: 8, maxCharacters: 100, engine: "test", lowConfidence: false, translateBatch: { _ in ["Eins", " "] }) { result.append(item) }
            Issue.record("blank translation succeeded")
        } catch {}
        #expect(result.isEmpty)
    }

    @Test("character budget splits batches")
    func charBudget() async throws {
        let backend = FakeAppleBackend(installed: [pair("en", "de")])
        let engine = AppleTranslationEngine(backend: backend, maxItems: 100, maxCharacters: 20)
        _ = try await collect(engine.translate(items: items(Array(repeating: "0123456789", count: 6)), from: "en", to: "de"))
        #expect(await backend.maxBatch == 2)
    }

    @Test("cancelling the stream stops work within 1 s (TRN-AC-16)")
    func cancel() async throws {
        let backend = FakeAppleBackend(installed: [pair("en", "de")])
        await backend.setDelay(.milliseconds(150))
        let engine = AppleTranslationEngine(backend: backend, maxItems: 1)
        let start = ContinuousClock.now
        let task = Task { try await collect(engine.translate(items: items((0..<200).map(String.init)), from: "en", to: "de")) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await backend.calls < 10)
    }

    @Test("cache: repeats skip the engine; key includes pair and engine")
    func cache() async throws {
        let inner = FakeEngine(id: "apple.translation", pairs: allPairs(["en", "de", "fr"]))
        let cache = TranslationCache()
        let engine = CachingTranslationEngine(inner, cache: cache)
        let a = items(["same", "other"])
        _ = try await collect(engine.translate(items: a, from: "en", to: "de"))
        let again = try await collect(engine.translate(items: a, from: "en", to: "de"))
        #expect(inner.calls.count == 1)
        #expect(again.map(\.segmentID) == a.map(\.segmentID))
        #expect(again.map(\.text) == ["apple.translation:de:same", "apple.translation:de:other"])
        _ = try await collect(engine.translate(items: a, from: "en", to: "fr"))
        #expect(inner.calls.count == 2)
        // a different segment with identical text is also a hit, and whitespace is ignored in the key
        let dup = [TranslationItem(segmentID: SegmentID(), text: " same ")]
        let hit = try await collect(engine.translate(items: dup, from: "en", to: "de"))
        #expect(hit.first?.segmentID == dup[0].segmentID)
        #expect(inner.calls.count == 2)
        #expect(TranslationCacheKey(text: "a", pair: pair("en", "de"), engine: "x") != TranslationCacheKey(text: "a", pair: pair("en", "de"), engine: "y"))
    }

    @Test("cache evicts oldest beyond capacity and preserves low confidence")
    func eviction() async {
        let cache = TranslationCache(capacity: 2)
        for i in 0..<3 { await cache.store(.init(text: "t\(i)", isLowConfidence: i == 2), for: .init(text: "k\(i)", pair: pair("en", "si"), engine: "nllb")) }
        #expect(await cache.count == 2)
        #expect(await cache.value(for: .init(text: "k0", pair: pair("en", "si"), engine: "nllb")) == nil)
        #expect(await cache.value(for: .init(text: "k2", pair: pair("en", "si"), engine: "nllb"))?.isLowConfidence == true)
    }
}

@Suite("Track (parallel translation)")
struct TrackTests {
    @Test("saved script-specific tracks neither read nor replace another writing system")
    func savedScripts() throws {
        let original = seg("Original", translations: [SegmentTranslation(language: "zh-Hans", text: "简体", engine: "test")])
        var track = TranslatedTrack(language: "zh-Hant", segments: [original])
        #expect(track.entries.first?.translated == nil)
        track.apply(TranslatedSegment(segmentID: original.id, text: "繁體", engine: "test"))
        let saved = try #require(track.applied(to: [original]).first)
        #expect(saved.translations.count == 2)
        #expect(TranslatedTrack(language: "zh-CN", segments: [saved]).entries.first?.translated == "简体")
        #expect(TranslatedTrack(language: "zh-TW", segments: [saved]).entries.first?.translated == "繁體")
    }

    @Test("applying results keeps the original untouched (TRN-AC-04)")
    func apply() {
        let segments = [seg("Hello"), seg("World"), seg("ignored", ignored: true), seg("  ")]
        var track = TranslatedTrack(language: "de", segments: segments)
        #expect(track.pendingIDs.count == 2)
        track.apply(TranslatedSegment(segmentID: segments[0].id, text: "Hallo", engine: "apple.translation"))
        let stored = track.applied(to: segments)
        #expect(stored.map(\.text) == segments.map(\.text))
        #expect(stored[0].translations == [SegmentTranslation(language: "de", text: "Hallo", engine: "apple.translation")])
        #expect(stored[1].translations.isEmpty)
        #expect(track.fractionTranslated == 0.5)
    }

    @Test("view modes: original, translated, bilingual (TRN-AC-08)")
    func modes() {
        let segments = [seg("Hello"), seg("World")]
        var track = TranslatedTrack(language: "si", segments: segments)
        track.apply(TranslatedSegment(segmentID: segments[0].id, text: "ආයුබෝවන්", engine: "nllb", isLowConfidence: true))
        let orig = track.lines(mode: .original)
        #expect(orig.map(\.primary) == ["Hello", "World"] && orig.allSatisfy { $0.secondary == nil && !$0.isLowConfidence })
        let tr = track.lines(mode: .translated)
        #expect(tr[0].primary == "ආයුබෝවන්" && tr[0].isLowConfidence)
        #expect(tr[1].primary == "World" && tr[1].isMissingTranslation)
        let bi = track.lines(mode: .bilingual)
        #expect(bi[0].primary == "Hello" && bi[0].secondary == "ආයුබෝවන්" && bi[0].isLowConfidence)
        #expect(bi[1].secondary == nil && bi[1].isMissingTranslation)
        #expect(TranslationViewMode.allCases.map(\.rawValue) == ["original", "translated", "bilingual"])
        #expect(track.containsLowConfidence)
    }

    @Test("editing a segment marks its translation stale; re-translate clears it (TRN-AC-10)")
    func stale() {
        let segments = [seg("Hello")]
        var track = TranslatedTrack(language: "de", segments: segments)
        track.apply(TranslatedSegment(segmentID: segments[0].id, text: "Hallo", engine: "apple.translation"))
        #expect(track.staleIDs.isEmpty)
        track.updateOriginal(segments[0].id, text: "Hello there")
        #expect(track.staleIDs == [segments[0].id] && track.pendingIDs == [segments[0].id])
        #expect(track.lines(mode: .translated)[0].isStale && track.lines(mode: .translated)[0].primary == "Hallo")
        track.apply(TranslatedSegment(segmentID: segments[0].id, text: "Hallo da", engine: "apple.translation"))
        #expect(track.staleIDs.isEmpty)
    }

    @Test("rebuilding from persisted segments finds the track and derives low confidence")
    func rebuild() {
        let persisted = seg("Hello", translations: [SegmentTranslation(language: "si", text: "x", engine: "nllb"), SegmentTranslation(language: "de", text: "y", engine: "apple.translation")])
        let track = TranslatedTrack(language: "si", segments: [persisted])
        #expect(track.entries[0].translated == "x" && track.entries[0].isLowConfidence)
        #expect(TranslatedTrack(language: "de", segments: [persisted]).entries[0].isLowConfidence == false)
    }
}

@Suite("Coordinator")
struct CoordinatorTests {
    func run(_ c: TranslationCoordinator, _ segs: [Segment], source: LanguageCode?, target: LanguageCode, only: Set<SegmentID>? = nil) async throws -> [TranslationEvent] {
        var events: [TranslationEvent] = []
        for try await e in c.translate(segments: segs, source: source, target: target, only: only) { events.append(e) }
        return events
    }
    func router(apple: FakeEngine? = nil) -> DefaultTranslationRouter {
        .init(
            apple: apple ?? FakeEngine(id: "apple.translation", pairs: allPairs(["en", "de"])),
            nllb: FakeEngine(id: "nllb", pairs: allPairs(["en", "si"])), cache: nil)
    }

    @Test("translates non-ignored segments with progress and per-segment events (TRN-AC-05)")
    func happy() async throws {
        let segs = [seg("a"), seg("b", ignored: true), seg("c")]
        let events = try await run(.init(router: router()), segs, source: "en", target: "de")
        #expect(events.first == .started(total: 2))
        let results = events.compactMap { if case .segment(let s) = $0 { s } else { nil } }
        #expect(results.map(\.segmentID) == [segs[0].id, segs[2].id])
        #expect(events.last == .finished(translated: 2))
        #expect(events.contains(.progress(done: 2, total: 2)))
    }

    @Test("same language and unknown source skip with a message (TRN-AC-06)")
    func skip() async throws {
        let same = try await run(.init(router: router()), [seg("a")], source: "en", target: "en-US")
        if case .skipped(.sameLanguage, let message) = same.first { #expect(!message.isEmpty) } else { Issue.record("expected skip") }
        let unknown = try await run(.init(router: router()), [seg("a")], source: nil, target: "de")
        if case .skipped(.unknownSource, _) = unknown.first {} else { Issue.record("expected skip") }
    }

    @Test("selection restricts the segments")
    func selection() async throws {
        let segs = [seg("a"), seg("b")]
        let events = try await run(.init(router: router()), segs, source: "en", target: "de", only: [segs[1].id])
        #expect(events.first == .started(total: 1))
    }

    @Test("engine failure is retryable and earlier results survive (TRN-AC-13)")
    func failure() async throws {
        let backend = FakeAppleBackend(installed: [pair("en", "de")])
        let apple = AppleTranslationEngine(backend: backend, maxItems: 1)
        let flaky = DefaultTranslationRouter(apple: apple, nllb: nil, cache: nil)
        let segs = [seg("a"), seg("b"), seg("c")]
        var track = TranslatedTrack(language: "de", segments: segs)
        // first pass fails on the 2nd batch
        await backend.setFailureAfter(1)
        var caught: (any Error)?
        do {
            for try await e in TranslationCoordinator(router: flaky).translate(segments: segs, source: "en", target: "de") {
                if case .segment(let s) = e { track.apply(s) }
            }
        } catch { caught = error }
        #expect(caught != nil && TranslationCoordinator.isRetryable(caught!))
        #expect(track.untranslatedIDs.count == 2 && track.entries[0].translated != nil)
        // retry only the pending ones
        await backend.setFailureAfter(nil)
        for try await e in TranslationCoordinator(router: flaky).translate(segments: segs, source: "en", target: "de", only: Set(track.pendingIDs)) {
            if case .segment(let s) = e { track.apply(s) }
        }
        #expect(track.fractionTranslated == 1)
    }

    @Test("retry classification")
    func retryable() {
        #expect(TranslationCoordinator.isRetryable(AppError.engineFailure("nllb", reason: "x")))
        #expect(!TranslationCoordinator.isRetryable(AppError.modelNotInstalled("nllb/200-distilled-600M")))
        #expect(!TranslationCoordinator.isRetryable(TranslationFailure.unknownSource))
    }
}

extension FakeAppleBackend {
    func setFailureAfter(_ n: Int?) { failAfter = n }
}

@Suite("Dictation and live")
struct LiveDictationTests {
    @Test("dictation falls back to the original on failure")
    func fallback() async {
        let failing = FakeEngine(id: "apple.translation", pairs: allPairs(["en", "de"]), failure: AppError.engineFailure("apple.translation", reason: "x"))
        let r = DefaultTranslationRouter(apple: failing, nllb: nil, cache: nil)
        let out = await DictationTranslator(router: r).translateBeforeInsert("hello", from: "en", to: "de")
        #expect(out == .init(text: "hello", didTranslate: false, isLowConfidence: false))
    }

    @Test("dictation translates when fast and falls back on timeout (TRN-AC-12)")
    func timeout() async {
        let backend = FakeAppleBackend(installed: [pair("en", "de")])
        let r = DefaultTranslationRouter(apple: AppleTranslationEngine(backend: backend), nllb: nil, cache: nil)
        let ok = await DictationTranslator(router: r, timeout: .seconds(2)).translateBeforeInsert("hello", from: "en", to: "de")
        #expect(ok.didTranslate && ok.text == "[de] hello")
        await backend.setDelay(.seconds(5))
        let start = ContinuousClock.now
        let slow = await DictationTranslator(router: r, timeout: .milliseconds(150)).translateBeforeInsert("hello", from: "en", to: "de")
        #expect(!slow.didTranslate && slow.text == "hello")
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("live: at most one translation per interval, stale lines dropped (TRN-AC-09)")
    func throttle() async throws {
        let engine = FakeEngine(id: "apple.translation", pairs: allPairs(["en", "de"]))
        let r = DefaultTranslationRouter(apple: engine, nllb: nil, cache: nil)
        let clock = FakeClock()
        let live = LiveTranslator(router: r, pair: pair("en", "de"), minInterval: .seconds(1), clock: { clock.now }, sleep: { await clock.sleep($0) })
        var received: [String] = []
        let reader = Task { for await s in live.results { received.append(s.text) } }
        for i in 0..<5 { await live.submit(TranslationItem(segmentID: SegmentID(), text: "line\(i)")) }
        try await Task.sleep(for: .milliseconds(300))
        await live.stop()
        await reader.value
        // first line starts immediately; the other four collapse into one (the newest)
        #expect(engine.calls.count <= 2)
        #expect(engine.calls.last == ["line4"] || engine.calls.count == 1)
        #expect(await live.droppedCount >= 3)
        // spacing: the fake clock advanced by the throttle wait between starts
        #expect(clock.slept.allSatisfy { $0 > .zero })
    }
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    private var _slept: [Duration] = []
    var now: ContinuousClock.Instant { lock.withLock { current } }
    var slept: [Duration] { lock.withLock { _slept } }
    func sleep(_ d: Duration) async {
        lock.withLock {
            current = current.advanced(by: d)
            _slept.append(d)
        }
    }
}


@Suite("Explicit translation engine selection")
struct TranslationSelectionTests {
    @Test("explicit NLLB choice is honored even when Apple supports the pair")
    func honorsChoice() async throws {
        let pair = LanguagePair(source: "en", target: "hi")
        let apple = FakeEngine(id: "apple.translation", pairs: [pair])
        let nllb = FakeEngine(id: "nllb", pairs: [pair])
        let router = DefaultTranslationRouter(apple: apple, nllb: nllb, selectedEngine: { "nllb" })
        #expect(try await router.engine(for: pair).id == "nllb")
    }

    @Test("explicit unsupported engine does not silently fall back")
    func refusesFallback() async {
        let pair = LanguagePair(source: "si", target: "en")
        let router = DefaultTranslationRouter(
            apple: FakeEngine(id: "apple.translation", pairs: []), nllb: FakeEngine(id: "nllb", pairs: [pair]),
            selectedEngine: { "apple.translation" })
        await #expect(throws: TranslationFailure.noEngine(pair)) { _ = try await router.engine(for: pair) }
    }

    @Test("engine policy is enforced before returning a cached engine")
    func policy() async {
        let pair = LanguagePair(source: "si", target: "en")
        let router = DefaultTranslationRouter(
            apple: FakeEngine(id: "apple.translation", pairs: []), nllb: FakeEngine(id: "nllb", pairs: [pair]),
            isAllowed: { $0 != "nllb" })
        await #expect(throws: TranslationFailure.noEngine(pair)) { _ = try await router.engine(for: pair) }
    }

    @Test("additional registered native engines participate in automatic and explicit routing")
    func additionalEngine() async throws {
        let pair = LanguagePair(source: "fr", target: "de")
        let engine = FakeEngine(id: "test.native", pairs: [pair])
        let router = DefaultTranslationRouter(
            apple: FakeEngine(id: "apple.translation", pairs: []), nllb: nil, additional: [engine])
        #expect(try await router.engine(for: pair).id == engine.id)
    }
}
