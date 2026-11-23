import AppCore
import AppCoreTesting
import FeatureHome
import FeatureLive
import FeatureSupport
import Foundation
import Testing

@testable import FeatureShell

@Suite("Responsive workspace and search") @MainActor
struct WorkspacePolishTests {
    @Test func workbenchUsesTheActualDetailColumnAndExpandsAtLargeSizes() {
        let narrow = WorkbenchLayout(width: 728, height: 600)
        #expect(narrow.actionColumns == 2 && !narrow.showsSidePanel && narrow.recentColumns == 2)
        let standard = WorkbenchLayout(width: 1208, height: 848)
        #expect(standard.actionColumns == 4 && standard.showsSidePanel && standard.recentColumns == 2)
        let wide = WorkbenchLayout(width: 2328, height: 1260)
        #expect(wide.recentColumns == 4 && wide.sidePanelWidth == 400)
        #expect(wide.bodyMinimumHeight > standard.bodyMinimumHeight)
        #expect(ShellLayout(width: 2560).contentWidth(available: 2328) == 2328)
    }

    @Test func liveKeepsControlsBesideReadableCaptionsOrStacksWhenNecessary() {
        let narrow = LiveWorkspaceLayout(width: 840)
        #expect(!narrow.stacksPanels && narrow.sidePanelWidth == 308)
        #expect(narrow.width - narrow.sidePanelWidth - 12 >= 440)  // 12 pt gap between the two panels
        #expect(LiveWorkspaceLayout(width: 780).stacksPanels)
        #expect(LiveWorkspaceLayout(width: 2100).sidePanelWidth == 340)
    }

    @Test func librarySearchCommandsFocusTheOnlySearchForThatRoute() {
        let shell = ShellModel(services: .preview())
        shell.select(.library)
        shell.presentQuickOpen()
        #expect(shell.usesLibrarySearch && !shell.isQuickOpenPresented && shell.librarySearchFocusToken == 1)
        shell.searchableLibrary.searchText = "library query"
        #expect(shell.library.searchText == "library query")
        shell.select(.recentlyDeleted)
        shell.searchableLibrary.searchText = "deleted query"
        #expect(shell.recentlyDeleted.searchText == "deleted query" && shell.library.searchText == "library query")
        shell.openTranscript(TranscriptID())
        shell.presentQuickOpen()
        #expect(!shell.usesLibrarySearch && shell.isQuickOpenPresented)
        shell.select(.home)
        #expect(!shell.isQuickOpenPresented)
    }

    @Test func sidebarArrowsMoveSelectionAndStopAtTheEdges() {
        let shell = ShellModel(services: .preview())
        shell.moveSidebarSelection(by: -1)
        #expect(shell.selection == .home)
        shell.moveSidebarSelection(by: 1)
        #expect(shell.selection == .queue)
        shell.moveSidebarSelection(by: 1)
        #expect(shell.selection == .meetings)
        shell.moveSidebarSelection(by: 100)
        #expect(shell.selection == .recentlyDeleted)
        shell.moveSidebarSelection(by: 1)
        #expect(shell.selection == .recentlyDeleted)
    }

    @Test func aNewQuickOpenSessionDoesNotShowOldResults() async {
        let transcript = Transcript(title: "Budget", source: .file)
        let model = QuickOpenModel(transcripts: InMemoryTranscripts(items: [transcript]))
        model.query = "Budget"
        await model.search()
        #expect(model.results.count == 1)
        model.reset()
        #expect(model.query.isEmpty && model.results.isEmpty && model.highlighted == 0)
    }

    @Test func fileModelStatusFollowsHardwareAndLanguageRoutingRatherThanCatalogOrder() async {
        let store = InMemorySettingsStore()
        let apple = descriptor("apple/speech-analyzer", languages: [.english], runtime: .appleAsset)
        let large = descriptor("whisperkit/large-v3-v20240930_626MB", languages: [.english, "fr"])
        let small = descriptor("whisperkit/small", languages: [.english, "fr"])
        let dedicated = descriptor("mlx/qwen3-asr-0.6b-sinhala-8bit", languages: [.sinhala], runtime: .mlx)
        let catalog = [apple, large, small, dedicated]
        #expect(await PreferredModel.resolve(in: catalog, settings: store, tier: .tier16)?.id == large.id)
        #expect(await PreferredModel.resolve(in: catalog, settings: store, tier: .tier8)?.id == small.id)
        await store.set(LanguageMode.single(.sinhala), for: SettingsKey.languageMode)
        await store.set(large.id.rawValue, for: SettingsKey.preferredModel)
        #expect(await PreferredModel.resolve(in: catalog, settings: store)?.id == dedicated.id)
        await store.set(LanguageMode.multilingual([.english, .sinhala]), for: SettingsKey.languageMode)
        #expect(Set(await PreferredModel.fileModels(in: catalog, settings: store).map(\.id)) == [large.id, dedicated.id])
    }

    @Test func multilingualFooterOnlyClaimsReadyWhenAllRequiredModelsAreReady() {
        let first = descriptor("one", languages: [.english])
        let second = descriptor("two", languages: [.sinhala])
        let partial = SidebarModelChip.make(models: [first, second], states: [first.id: .installed(bytesOnDisk: 100)])
        #expect(partial.status == .notInstalled && partial.detail.contains("1 of 2 ready"))
        let ready = SidebarModelChip.make(
            models: [first, second], states: [first.id: .installed(bytesOnDisk: 100), second.id: .installed(bytesOnDisk: 100)])
        #expect(ready.status == .ready)
        let failed = SidebarModelChip.make(model: first, state: .failed(reason: "Download was interrupted"))
        #expect(failed.detail == "Download was interrupted")
        #expect(SidebarModelChip(name: "Test", status: .downloading(fraction: 2), detail: "").fraction == 1)
    }

    @Test func livePreservesAnyChosenLanguageAndOffersCatalogLanguages() async {
        var services = AppServices.preview()
        let store = InMemorySettingsStore()
        await store.set(LanguageMode.single("fr"), for: SettingsKey.languageMode)
        services.settings = store
        services.models = MockModelManager(descriptors: [descriptor("multilingual", languages: [.english, "fr", "de", .sinhala])])
        let model = LiveModel(services: services)
        await model.loadPreferences()
        #expect(model.language.mode == .single("fr"))
        #expect(model.languageChoices.contains(LiveLanguageChoice(mode: .single("de"))))
        #expect(model.languageChoices.contains(.auto))
    }

    @Test func changingLiveLanguageClearsOnlyIncompatibleExplicitModels() async {
        var services = AppServices.preview()
        let store = InMemorySettingsStore()
        let english = descriptor("english-only", languages: [.english])
        let multilingual = descriptor("multilingual", languages: [.english, "fr", "de"])
        services.settings = store
        services.models = MockModelManager(descriptors: [english, multilingual])
        await store.set(english.id.rawValue, for: SettingsKey.preferredModelFile)
        let model = LiveModel(services: services)
        await model.loadPreferences()
        model.language = LiveLanguageChoice(mode: .single("fr"))
        #expect(
            await eventually {
                let mode = await store.value(for: SettingsKey.languageMode, as: LanguageMode.self)
                let preferred = await store.value(for: SettingsKey.preferredModelFile, as: String.self)
                return mode == .single("fr") && preferred == ""
            })
        await store.set(multilingual.id.rawValue, for: SettingsKey.preferredModelFile)
        model.language = LiveLanguageChoice(mode: .single("de"))
        #expect(
            await eventually {
                let mode = await store.value(for: SettingsKey.languageMode, as: LanguageMode.self)
                let preferred = await store.value(for: SettingsKey.preferredModelFile, as: String.self)
                return mode == .single("de") && preferred == multilingual.id.rawValue
            })
    }

    private func descriptor(
        _ id: ModelID, languages: Set<LanguageCode>, runtime: ModelRuntime = .coreML
    ) -> ModelDescriptor {
        // Same recommendation rules as the built-in catalog: the shared ModelRecommender is data-driven (SCR-011).
        let rules: [RecommendedUse] =
            switch id.rawValue {
            case "whisperkit/large-v3-v20240930_626MB": [RecommendedUse(.file, minTier: .tier16)]
            case "whisperkit/small": [RecommendedUse(.file, maxTier: .tier8)]
            case "mlx/qwen3-asr-0.6b-sinhala-8bit": [RecommendedUse(.file)]
            default: []
            }
        return ModelDescriptor(
            id: id, displayName: id.rawValue, kind: .asr, runtime: runtime, languages: languages, sizeBytes: 100,
            license: LicenseInfo(spdx: "MIT"),
            capabilities: ModelCapabilities(file: true, autoDetectLanguage: true, recommendedUse: rules))
    }
}
