import AppCore
import AppCoreTesting
import FeatureHome
import FeatureQueue
import FeatureSettings
import FeatureShell
import FeatureSupport
import Foundation
import Testing

/// SCR-013: one add flow with the Transcribe sheet, remembered choices, speaker options and greyed-out models.
@Suite("Add flow") @MainActor
struct AddFlowTests {
    private func asr(
        _ id: ModelID, _ name: String, languages: Set<LanguageCode>, size: Int64 = 100_000_000,
        capabilities: ModelCapabilities = ModelCapabilities(file: true, autoDetectLanguage: true)
    ) -> ModelDescriptor {
        ModelDescriptor(
            id: id, displayName: name, kind: .asr, runtime: .coreML, languages: languages, sizeBytes: size,
            license: LicenseInfo(spdx: "MIT"), capabilities: capabilities)
    }

    private var speakerModel: ModelDescriptor {
        ModelDescriptor(
            id: "fluidaudio/diarization-community-1", displayName: "Community-1", kind: .diarization, runtime: .coreML,
            languages: [], sizeBytes: 21_000_000, license: LicenseInfo(spdx: "CC-BY-4.0"),
            capabilities: ModelCapabilities(file: true, speakerLabels: .offline))
    }

    private var catalog: [ModelDescriptor] {
        [
            asr(
                "whisper", "Whisper", languages: [.english, "fr"],
                capabilities: ModelCapabilities(
                    file: true, autoDetectLanguage: true, recommendedUse: [RecommendedUse(.file)])),
            asr("english-only", "English Only", languages: [.english], capabilities: ModelCapabilities(file: true)),
            asr("qwen", "Qwen Sinhala", languages: [.sinhala], capabilities: ModelCapabilities(file: true)),
            asr("parakeet", "Parakeet", languages: [.english], capabilities: ModelCapabilities(live: false, file: false)),
            speakerModel,
        ]
    }

    private func services(
        queue: PlaceholderJobQueue = PlaceholderJobQueue(), store: InMemorySettingsStore = InMemorySettingsStore(),
        installed: Set<ModelID> = ["whisper"]
    ) -> AppServices {
        var services = AppServices.preview()
        services.jobQueue = queue
        services.settings = store
        services.models = MockModelManager(descriptors: catalog, installed: installed)
        return services
    }

    private let file = URL(fileURLWithPath: "/tmp/a.m4a")

    // MARK: Routing

    @Test func everyEntryPointShowsTheSheetFirstAndEnqueuesNothing() async {
        let queue = PlaceholderJobQueue()
        let shell = ShellModel(services: services(queue: queue))
        #expect(shell.handleDrop([file]))  // window drop and the importer both use this
        #expect(await eventually { shell.queue.batch != nil })
        shell.cancelAdd()
        #expect(shell.queue.batch == nil)
        #expect(await shell.home.enqueue([file]) == false)  // Home drop goes through the shell
        #expect(shell.queue.batch != nil)
        shell.cancelAdd()
        await shell.queue.requestAdd([file])  // Queue add and folders
        #expect(shell.queue.batch != nil)
        #expect(await queue.jobs().isEmpty)
    }

    @Test func confirmingTheSheetEnqueuesWithTheChosenOptionsAndOpensTheQueue() async {
        let queue = PlaceholderJobQueue()
        let shell = ShellModel(services: services(queue: queue))
        await shell.requestAdd([file])
        let batch = shell.queue.batch
        await batch?.prepare()
        batch?.diarize = true
        batch?.speakerCount = .exact(3)
        await shell.confirmAdd()
        let jobs = await queue.jobs()
        #expect(jobs.count == 1 && jobs[0].settings.diarize && jobs[0].settings.diarization == ["exact": 3])
        #expect(shell.queue.batch == nil && shell.selection == .queue)
    }

    @Test func withAskingOffFilesAreEnqueuedAtOnceWithSavedChoicesIncludingSpeakers() async {
        let store = InMemorySettingsStore()
        await store.set(false, for: SettingsKey.askBeforeAdding)
        await store.set(true, for: SettingsKey.filesDiarize)
        await store.set(4, for: SettingsKey.filesSpeakerCount)
        await store.set(LanguageMode.single("fr"), for: SettingsKey.languageMode)
        let queue = PlaceholderJobQueue()
        let shell = ShellModel(services: services(queue: queue, store: store))
        #expect(await shell.home.enqueue([file]) == false)  // routed; the shell navigates itself
        let jobs = await queue.jobs()
        #expect(jobs.count == 1)
        #expect(jobs[0].settings.diarize && jobs[0].settings.diarization == ["exact": 4])
        #expect(jobs[0].settings.languageMode == .single("fr"))
        #expect(shell.queue.batch == nil && shell.selection == .queue)
    }

    @Test func homeWithoutAShellStillCarriesTheSavedSpeakerSettings() async {
        let store = InMemorySettingsStore()
        await store.set(true, for: SettingsKey.filesDiarize)
        let queue = PlaceholderJobQueue()
        let home = HomeModel(services: services(queue: queue, store: store))
        #expect(await home.enqueue([file]))
        #expect(await queue.jobs().first?.settings.diarize == true)
    }

    // MARK: Remembered choices

    @Test func theSheetSavesWhatWasChosen() async {
        let store = InMemorySettingsStore()
        let batch = BatchSettingsModel(urls: [file], services: services(store: store))
        await batch.prepare()
        batch.setSingleLanguage("fr")
        await batch.selectModel("whisper")
        batch.diarize = true
        batch.speakerCount = .exact(2)
        #expect(await batch.submit())
        #expect(await store.value(for: SettingsKey.languageMode, as: LanguageMode.self) == .single("fr"))
        #expect(await store.value(for: SettingsKey.filesLastModel, as: String.self) == "whisper")
        #expect(await store.value(for: SettingsKey.filesDiarize, as: Bool.self) == true)
        #expect(await store.value(for: SettingsKey.filesSpeakerCount, as: Int.self) == 2)
        #expect(await store.value(for: SettingsKey.filesRecentLanguages, as: [String].self) == ["fr"])
        #expect(await store.value(for: SettingsKey.preferredModel, as: String.self) == nil, "live captions read this key")
        // The next sheet starts from those choices.
        let next = BatchSettingsModel(urls: [file], services: services(store: store))
        await next.prepare()
        #expect(next.languageMode == .single("fr") && next.modelID == "whisper" && next.diarize && next.speakerCount == .exact(2))
    }

    @Test func aSheetConfirmedWithoutChangesDoesNotRewriteLanguageOrModel() async {
        let store = InMemorySettingsStore()
        let batch = BatchSettingsModel(urls: [file], services: services(store: store))
        await batch.prepare()
        #expect(await batch.submit())
        #expect(await store.value(for: SettingsKey.languageMode, as: LanguageMode.self) == nil)
        #expect(await store.value(for: SettingsKey.filesLastModel, as: String.self) == nil)
    }

    @Test func dontAskAgainTurnsTheSettingOff() async {
        let store = InMemorySettingsStore()
        #expect(await FileJobSettings.asksBeforeAdding(in: store))
        let batch = BatchSettingsModel(urls: [file], services: services(store: store))
        await batch.prepare()
        batch.dontAskAgain = true
        #expect(await batch.submit())
        #expect(await FileJobSettings.asksBeforeAdding(in: store) == false)
    }

    @Test func generalSettingsExposesAskBeforeAddingDefaultingOn() async {
        let store = InMemorySettingsStore()
        let general = GeneralSettingsModel(store: store)
        await general.load()
        #expect(general.askBeforeAdding.value)
        await general.askBeforeAdding.set(false)
        #expect(await FileJobSettings.asksBeforeAdding(in: store) == false)
    }

    @Test func recentLanguagesAreMostRecentFirstWithoutDuplicates() {
        #expect(FileJobSettings.recent(adding: ["fr"], to: ["en", "fr", "si"]) == ["fr", "en", "si"])
        let many = (1...8).map { LanguageCode("l\($0)") }
        #expect(FileJobSettings.recent(adding: ["x"], to: many).count == FileJobSettings.maxRecentLanguages)
    }

    @Test func aSavedModelThatNoLongerFitsTheLanguageFallsBackToAutomatic() async {
        let store = InMemorySettingsStore()
        await store.set(LanguageMode.single(.sinhala), for: SettingsKey.languageMode)
        await store.set("whisper", for: SettingsKey.filesLastModel)
        let loaded = await FileJobSettings.load(from: store, catalog: catalog)
        #expect(loaded.modelID == nil)
        await store.set("", for: SettingsKey.filesLastModel)  // an explicit Automatic wins over the Settings model
        await store.set("english-only", for: SettingsKey.preferredModel)
        await store.set(LanguageMode.single(.english), for: SettingsKey.languageMode)
        #expect(await FileJobSettings.load(from: store, catalog: catalog).modelID == nil)
    }

    // MARK: Language and model rows

    @Test func sinhalaIsOfferedAndUnsupportedModelsAreGreyedWithAReason() async {
        let batch = BatchSettingsModel(urls: [file], services: services())
        await batch.prepare()
        #expect(batch.languageOptions.contains(.sinhala))
        batch.setSingleLanguage(.sinhala)
        let rows = batch.modelRows
        let whisper = rows.first { $0.id == "whisper" }
        #expect(whisper?.isEnabled == false)
        #expect(whisper?.disabledReason?.contains("No si support") == true)
        #expect(rows.first { $0.id == "qwen" }?.isEnabled == true)
        #expect(!rows.contains { $0.id == "parakeet" }, "models this build cannot run are not listed")
        #expect(!rows.contains { $0.descriptor.kind != .asr })
    }

    @Test func autoDetectGreysOutModelsThatCannotIdentifyTheLanguage() async {
        let batch = BatchSettingsModel(urls: [file], services: services())
        await batch.prepare()
        batch.setKind(.autoDetect)
        let reason = batch.modelRows.first { $0.id == "english-only" }?.disabledReason
        #expect(reason == ModelIncompatibility.noAutoDetect.message)
    }

    @Test func theRecommendedModelIsPreselectedOnlyWhenNothingIsSaved() async {
        let fresh = BatchSettingsModel(urls: [file], services: services())
        await fresh.prepare()
        #expect(fresh.modelID == "whisper" && fresh.recommendedModel?.id == "whisper")
        #expect(fresh.modelRows.first { $0.id == "whisper" }?.isRecommended == true)
        let store = InMemorySettingsStore()
        await store.set("", for: SettingsKey.filesLastModel)  // the user chose Automatic last time
        let saved = BatchSettingsModel(urls: [file], services: services(store: store))
        await saved.prepare()
        #expect(saved.modelID == nil)
    }

    // MARK: Speakers

    @Test func speakerCountMapsToTheJobDiarizationSettings() {
        #expect(SpeakerCount.auto.diarization.isEmpty)
        #expect(SpeakerCount.exact(3).diarization == ["exact": 3])
        #expect(SpeakerCount(storedValue: 0) == .auto && SpeakerCount(storedValue: 11) == .auto)
        #expect(SpeakerCount(storedValue: 10) == .exact(10))
        #expect(SpeakerCount.choices.count == 11 && SpeakerCount.choices.first == .auto)
        #expect(SpeakerCount(diarization: ["exact": 5]) == .exact(5))
    }

    @Test func speakerCountOnlyTravelsWhenSpeakersAreIdentified() async {
        let queue = PlaceholderJobQueue()
        let batch = BatchSettingsModel(urls: [file], services: services(queue: queue))
        await batch.prepare()
        batch.speakerCount = .exact(2)
        #expect(batch.jobSettings.diarization.isEmpty && !batch.jobSettings.diarize)
        batch.diarize = true
        #expect(batch.jobSettings.diarization == ["exact": 2] && batch.jobSettings.diarize)
    }

    // MARK: Voice processing (SCR-014)

    @Test func voiceProcessingDefaultsToOffAndTravelsInTheJobSettings() async {
        let queue = PlaceholderJobQueue()
        let batch = BatchSettingsModel(urls: [file], services: services(queue: queue))
        await batch.prepare()
        #expect(batch.voiceProcessing == .off && !batch.voiceProcessingEnabled && batch.jobSettings.voiceProcessing == .off)
        batch.voiceProcessingEnabled = true
        #expect(batch.voiceProcessing == .standard, "turning it on starts at Standard")
        batch.voiceProcessing = .strong
        #expect(batch.jobSettings.voiceProcessing == .strong)
        batch.voiceProcessingEnabled = false
        #expect(batch.jobSettings.voiceProcessing == .off)
        batch.voiceProcessingEnabled = true
        #expect(batch.voiceProcessing == .strong, "the toggle brings back the last level")
        #expect(await batch.submit())
        #expect(await queue.jobs().first?.settings.voiceProcessing == .strong)
    }

    @Test func perFileOverrideInheritsOrReplacesTheBatchVoiceProcessing() async {
        let other = URL(fileURLWithPath: "/tmp/other.m4a")
        let batch = BatchSettingsModel(urls: [file, other], services: services())
        await batch.prepare()
        batch.voiceProcessing = .light
        batch.updateOverride(for: other) { $0.voiceProcessing = .off }
        #expect(batch.settings(for: file).voiceProcessing == .light)
        #expect(batch.settings(for: other).voiceProcessing == .off)
        batch.updateOverride(for: other) { $0.voiceProcessing = nil }
        #expect(!batch.hasOverride(other) && batch.settings(for: other).voiceProcessing == .light)
    }

    @Test func voiceProcessingIsRememberedAndIsTheSettingsDefault() async {
        let store = InMemorySettingsStore()
        let batch = BatchSettingsModel(urls: [file], services: services(store: store))
        await batch.prepare()
        batch.voiceProcessing = .light
        #expect(await batch.submit())
        #expect(await store.value(for: SettingsKey.filesVoiceProcessing, as: String.self) == "light")
        let next = BatchSettingsModel(urls: [file], services: services(store: store))
        await next.prepare()
        #expect(next.voiceProcessing == .light)
        // Settings > General edits the same key.
        let general = GeneralSettingsModel(store: store)
        await general.load()
        #expect(general.voiceProcessingLevel == .light)
        await general.voiceProcessing.set(VoiceProcessingLevel.strong.rawValue)
        #expect(general.voiceProcessingLevel == .strong)
        #expect(await FileJobSettings.voiceProcessing(in: store) == .strong)
        // The no-sheet path reads the same default.
        let loaded = await FileJobSettings.load(from: store, catalog: [])
        #expect(loaded.voiceProcessing == .strong)
        await store.set("turbo", for: SettingsKey.filesVoiceProcessing)
        #expect(await FileJobSettings.voiceProcessing(in: store) == .off, "an unknown stored value reads as off")
    }

    @Test func aMissingSpeakerModelIsOfferedAndCanBeDownloadedFromTheSheet() async {
        let batch = BatchSettingsModel(urls: [file], services: services(installed: ["whisper"]))
        await batch.prepare()
        #expect(!batch.needsSpeakerModel)
        batch.diarize = true
        #expect(batch.needsSpeakerModel && batch.speakerModel?.id == "fluidaudio/diarization-community-1")
        #expect(batch.speakerModelSizeText.contains("MB"))
        await batch.downloadSpeakerModel()
        #expect(batch.speakerModelInstalled && !batch.needsSpeakerModel)
    }

    @Test func installedSpeakerModelNeedsNoOffer() async {
        let batch = BatchSettingsModel(
            urls: [file], services: services(installed: ["whisper", "fluidaudio/diarization-community-1"]))
        await batch.prepare()
        batch.diarize = true
        #expect(!batch.needsSpeakerModel)
    }
}
