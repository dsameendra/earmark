import AppCore
import AppCoreTesting
import Foundation
import Testing

@testable import Dictation

@Suite("Post-processing pipeline")
struct PipelineTests {
    private func pipeline(
        rules: MemoryRules = MemoryRules(), translation: (any TranslationRouter)? = nil
    ) -> (DictationPipeline, SpyProcessor) {
        let spy = SpyProcessor()
        return (DictationPipeline(postProcessor: spy, rules: rules, translation: translation), spy)
    }

    @Test func ignoreThenReplacementThenPunctuation() async throws {
        let rules = MemoryRules(
            ignore: [IgnoreRule(pattern: "um")], replace: [ReplacementRule(find: "gonna", replacement: "going to")])
        let (p, spy) = pipeline(rules: rules)
        var s = DictationSettings()
        s.autoPunctuation = true
        let out = try #require(await p.finalize(segments: [seg("um"), seg("i am gonna go")], settings: s))
        #expect(out.text == "I am going to go.")
        let ctx = try #require(spy.contexts.withLock { $0.first })
        #expect(ctx.ignoreRules.count == 1 && ctx.replacementRules.count == 1)
    }

    @Test func disabledAndDeletedRulesAreNotPassed() async throws {
        let rules = MemoryRules(
            ignore: [IgnoreRule(pattern: "a", isEnabled: false), IgnoreRule(pattern: "b", deletedAt: Date())],
            replace: [ReplacementRule(find: "x", replacement: "y", isEnabled: false)])
        let (p, spy) = pipeline(rules: rules)
        _ = await p.finalize(segments: [seg("hi")], settings: DictationSettings())
        let ctx = try #require(spy.contexts.withLock { $0.first })
        #expect(ctx.ignoreRules.isEmpty && ctx.replacementRules.isEmpty)
    }

    @Test func textThatBecomesEmptyIsNotInserted() async {
        let (p, _) = pipeline(rules: MemoryRules(ignore: [IgnoreRule(pattern: "um")]))
        let out = await p.finalize(segments: [seg("um")], settings: DictationSettings())
        #expect(out == nil)
        #expect(await p.finalize(segments: [], settings: DictationSettings()) == nil)
    }

    @Test func translatesBeforeInsertWhenEnabled() async throws {
        let (p, _) = pipeline(translation: FixedTranslationRouter())
        var s = DictationSettings()
        s.translateBeforeInsert = true
        s.translationTarget = .sinhala
        let out = try #require(await p.finalize(segments: [seg("hello")], settings: s))
        #expect(out.text == "[si] hello")
        #expect(out.language == .sinhala)
        #expect(!out.translationFailed)
    }

    @Test func translationFailureInsertsOriginalAndFlags() async throws {
        let (p, _) = pipeline(translation: ThrowingTranslationRouter())
        var s = DictationSettings()
        s.translateBeforeInsert = true
        s.translationTarget = .sinhala
        let out = try #require(await p.finalize(segments: [seg("hello")], settings: s))
        #expect(out.text == "hello")
        #expect(out.translationFailed)
    }

    @Test func sameLanguageSkipsTranslation() async throws {
        let (p, _) = pipeline(translation: ThrowingTranslationRouter())
        var s = DictationSettings()
        s.translateBeforeInsert = true
        s.translationTarget = "en-GB"
        let out = try #require(await p.finalize(segments: [seg("hello", lang: "en-US")], settings: s))
        #expect(out.text == "hello" && !out.translationFailed)
    }
}

private struct StubRouter: EngineRouter {
    var plan: EnginePlan
    func plan(for request: RoutingRequest) throws -> EnginePlan {
        #expect(request.useCase == .dictation)
        return plan
    }
}

@Suite("Engine routing for dictation")
struct EngineRoutingTests {
    private func provider(_ assignment: EngineAssignment, engines: [EngineID: any TranscriptionEngine]) -> RoutedEngineProvider {
        RoutedEngineProvider(
            router: StubRouter(plan: EnginePlan(assignments: [assignment])), tier: { .tier16 }, installedModels: { [] }, engines: engines)
    }

    @Test func englishRoutesToSpeechAnalyzerEngine() async throws {
        let apple = MockTranscriptionEngine(id: "apple.speechanalyzer")
        let p = provider(EngineAssignment(language: .english, engine: "apple.speechanalyzer", model: nil), engines: ["apple.speechanalyzer": apple])
        let r = try await p.resolve(DictationSettings())
        #expect(r.engine.id == "apple.speechanalyzer" && !r.isExperimental)
    }

    @Test func sinhalaRoutesToSinhalaEngineFlaggedExperimental() async throws {
        let si = MockTranscriptionEngine(id: "qwen3.si")
        let p = provider(
            EngineAssignment(language: .sinhala, engine: "qwen3.si", model: "qwen3/si", isExperimental: true), engines: ["qwen3.si": si])
        var s = DictationSettings()
        s.languageMode = .single(.sinhala)
        let r = try await p.resolve(s)
        #expect(r.engine.id == "qwen3.si" && r.isExperimental && r.model == "qwen3/si")
    }

    @Test func missingModelAndMissingEngineThrow() async {
        let needs = provider(EngineAssignment(language: nil, engine: "e", model: "m", requiresDownload: true), engines: [:])
        await #expect(throws: AppError.modelNotInstalled("m")) { _ = try await needs.resolve(DictationSettings()) }
        let missing = provider(EngineAssignment(language: nil, engine: "e", model: nil), engines: [:])
        await #expect(throws: AppError.self) { _ = try await missing.resolve(DictationSettings()) }
    }
}

@Suite("History")
struct HistoryTests {
    @Test func recordsSearchesLimitsAndClears() async {
        let repo = MemoryHistory()
        let h = DictationHistory(repository: repo)
        let s = DictationSettings()
        for i in 0..<5 {
            await h.record("note \(i)", language: .english, settings: s, now: Date(timeIntervalSince1970: Double(i)))
        }
        await h.record("buy milk", language: .english, settings: s, now: Date(timeIntervalSince1970: 10))
        #expect(await h.entries(matching: nil, limit: 3).count == 3)
        #expect(await h.entries(matching: "milk", limit: 10).map(\.text) == ["buy milk"])
        #expect(await h.entries(matching: "  ", limit: 100).count == 6)
        await h.clear()
        #expect(await h.entries(matching: nil, limit: 10).isEmpty)
    }

    @Test func disabledHistorySavesNothing() async {
        let repo = MemoryHistory()
        var s = DictationSettings()
        s.historyEnabled = false
        let wrote = await DictationHistory(repository: repo).record("x", language: nil, settings: s)
        #expect(!wrote)
        #expect(await repo.entries.isEmpty)
    }

    @Test func settingsRoundTripThroughStore() async {
        let store = MemorySettings()
        var s = DictationSettings()
        s.mode = .toggle
        s.combo = KeyCombo(keyCode: 2, modifiers: ModifierMask.control)
        s.languageMode = .multilingual([.english, .sinhala])
        s.historyLimit = 50
        await s.save(to: store)
        #expect(await DictationSettings.load(from: store) == s)
        #expect(await DictationSettings.load(from: MemorySettings()) == DictationSettings())
    }
}
