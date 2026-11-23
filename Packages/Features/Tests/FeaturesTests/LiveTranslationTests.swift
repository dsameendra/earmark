import AppCore
import FeatureLive
import FeatureMenuBar
import FeatureSupport
import Foundation
import Testing

private actor TranslationRecordingLive: LiveSessionControlling {
    private(set) var configs: [LiveSessionConfig] = []
    func start(_ config: LiveSessionConfig) async throws { configs.append(config) }
    func stop() async -> TranscriptID? { nil }
    nonisolated func state() -> AsyncStream<LiveSessionState> { AsyncStream { $0.yield(.idle); $0.finish() } }
    nonisolated func lines() -> AsyncStream<[CaptionLine]> { AsyncStream { $0.finish() } }
}

private struct TranslationPreparationStub: TranslationPreparing {
    let result: TranslationReadiness
    func targets(from source: LanguageCode) async -> [(language: LanguageCode, readiness: TranslationReadiness)] { [("en", result)] }
    func readiness(source: LanguageCode, target: LanguageCode) async -> TranslationReadiness { result }
    func prepareApplePack(source: LanguageCode, target: LanguageCode) async -> Bool { false }
}

@Suite("Live translation configuration") @MainActor
struct LiveTranslationConfigurationTests {
    @Test("legacy preset is migrated once; later styling does not change translation")
    func migratesLegacyPresetOnce() async {
        let settings = InMemorySettingsStore()
        let old = CaptionPreset(name: "Bilingual", showTranslation: true)
        let initial = await LiveTranslationPreferences.load(settings: settings, legacyPreset: old)
        #expect(initial.isEnabled)
        let next = await LiveTranslationPreferences.load(settings: settings, legacyPreset: CaptionPreset(name: "Subtle"))
        #expect(next.isEnabled)
        await settings.set(false, for: SettingsKey.liveTranslationEnabled)
        let disabled = await LiveTranslationPreferences.load(settings: settings, legacyPreset: old)
        #expect(!disabled.isEnabled)
    }

    @Test("translation is independent of an ordinary Subtle preset")
    func independentOfAppearance() async throws {
        let store = InMemorySettingsStore()
        await store.set(true, for: SettingsKey.liveTranslationEnabled)
        await store.set("de", for: SettingsKey.translationTarget)
        let live = TranslationRecordingLive()
        var services = AppServices.preview()
        services.live = live; services.settings = store
        services.translation = TranslationPreparationStub(result: .ready)
        let model = LiveModel(services: services)
        await model.loadPreferences()
        #expect(!model.preset.showTranslation)
        await model.start()
        #expect(try #require(await live.configs.first).translateTo == "de")
    }

    @Test("missing target refuses to capture untranslated audio")
    func missingTarget() async {
        let live = TranslationRecordingLive()
        var services = AppServices.preview(); services.live = live
        let model = LiveModel(services: services)
        model.translationEnabled = true
        await model.start()
        #expect(await live.configs.isEmpty)
        if case .failed(let reason) = model.state { #expect(reason.contains("target language")) }
        else { Issue.record("Expected target-language error") }
    }

    @Test("missing translation model is explained before capture")
    func missingModel() async {
        let live = TranslationRecordingLive()
        var services = AppServices.preview(); services.live = live
        services.translation = TranslationPreparationStub(result: .needsModel("nllb/200-distilled-600M"))
        let model = LiveModel(services: services)
        model.translationEnabled = true; model.translationTarget = "de"
        await model.start()
        #expect(await live.configs.isEmpty)
        if case .failed(let reason) = model.state { #expect(reason.contains("Settings > Models")) }
        else { Issue.record("Expected model setup error") }
    }

    @Test("preferences are saved in order before starting")
    func savesBeforeStart() async {
        let store = InMemorySettingsStore()
        var services = AppServices.preview(); services.settings = store
        let model = LiveModel(services: services)
        model.translationEnabled = true; model.translationTarget = "fr"
        model.translationEngine = "nllb"; model.translationTarget = "de"
        await model.start()
        #expect(await store.value(for: SettingsKey.translationTarget, as: String.self) == "de")
        #expect(await store.value(for: SettingsKey.translationEngine, as: String.self) == "nllb")
    }

    @Test("menu-bar capture shares the live translation setting")
    func menuBarUsesSameConfiguration() async throws {
        let store = InMemorySettingsStore()
        await store.set(true, for: SettingsKey.liveTranslationEnabled)
        await store.set("de", for: SettingsKey.translationTarget)
        let live = TranslationRecordingLive()
        var services = AppServices.preview(); services.settings = store; services.live = live
        services.translation = TranslationPreparationStub(result: .ready)
        await MenuBarModel(services: services).startLive(.mic)
        #expect(try #require(await live.configs.first).translateTo == "de")
    }
}
