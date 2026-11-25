import AppCore
import AppCoreTesting
import FeatureLive
import FeatureSettings
import FeatureSupport
import Testing

@Suite("Catalog translation engine choices") @MainActor
struct TranslationEngineChoiceTests {
    private func descriptor(_ id: ModelID, engine: EngineID, runnable: Bool = true) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: id.rawValue, kind: .translation, runtime: .other, engine: engine,
                        languages: ["en", "si", "fr"], sizeBytes: 100, license: LicenseInfo(spdx: "Apache-2.0"),
                        capabilities: ModelCapabilities(file: runnable, translation: runnable))
    }

    @Test func groupsExecutableVariantsAndExcludesUnavailableWeights() {
        let catalog = [descriptor("madlad/native", engine: "madlad"), descriptor("madlad/legacy", engine: "madlad", runnable: false),
                       descriptor("pair/one", engine: "opus-mt"), descriptor("pair/two", engine: "opus-mt"),
                       descriptor("other/unavailable", engine: "not-shipped", runnable: false)]
        let choices = TranslationEngineChoice.choices(in: catalog, selected: "auto")
        #expect(choices.map(\.id) == ["auto", "apple", "madlad", "opus-mt"])
        #expect(choices.allSatisfy { !$0.isUnavailable })
    }

    @Test func settingsPreservesAnUnavailableSavedChoice() async {
        let store = InMemorySettingsStore()
        await store.set("old-engine", for: SettingsKey.translationEngine)
        let model = TranslationSettingsModel(store: store, models: MockModelManager())
        await model.load()
        #expect(model.engine.value == "old-engine")
        #expect(model.engineChoices.last?.id == "old-engine")
        #expect(model.engineChoices.last?.isUnavailable == true)
        #expect(await store.value(for: SettingsKey.translationEngine, as: String.self) == "old-engine")
    }

    @Test func settingsAndLiveUseTheSameInstalledRuntimeCatalog() async {
        let store = InMemorySettingsStore()
        let models = MockModelManager(descriptors: [descriptor("madlad/native", engine: "madlad")])
        var services = AppServices.preview()
        services.models = models
        services.settings = store
        let live = LiveModel(services: services)
        let settings = TranslationSettingsModel(store: store, models: models)
        await live.loadPreferences()
        await settings.load()
        #expect(live.translationEngineChoices == settings.engineChoices)
        #expect(live.translationEngineChoices.contains { $0.id == "madlad" && !$0.isUnavailable })
    }
}
