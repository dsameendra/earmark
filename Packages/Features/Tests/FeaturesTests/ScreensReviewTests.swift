import AppCore
import AppCoreTesting
import FeatureLibrary
import FeatureQueue
import FeatureShell
import FeatureSupport
import Foundation
import Testing

/// Review fixes for the screens domain: model-choice precedence, the Transcribe sheet's download and disabled states, the
/// picker's pending download and the persisted Library sort.
@Suite("Screens review") @MainActor
struct ScreensReviewTests {
    private func asr(_ id: String, _ name: String, languages: Set<LanguageCode> = [.english], size: Int64 = 100_000_000) -> ModelDescriptor {
        ModelDescriptor(
            id: ModelID(id), displayName: name, kind: .asr, runtime: .coreML, languages: languages, sizeBytes: size,
            license: LicenseInfo(spdx: "MIT"), capabilities: ModelCapabilities(file: true, autoDetectLanguage: true))
    }

    private var catalog: [ModelDescriptor] { [asr("a", "Model A"), asr("b", "Model B")] }

    private func services(
        queue: PlaceholderJobQueue = PlaceholderJobQueue(), store: InMemorySettingsStore = InMemorySettingsStore(),
        installed: Set<ModelID> = ["a"], mock: MockModelManager? = nil
    ) -> AppServices {
        var services = AppServices.preview()
        services.jobQueue = queue
        services.settings = store
        services.models = mock ?? MockModelManager(descriptors: catalog, installed: installed)
        return services
    }

    private let file = URL(fileURLWithPath: "/tmp/a.m4a")

    // MARK: Model choice precedence

    @Test func aNewerFileModelChoiceBeatsTheSheetsStaleLastPick() async {
        let store = InMemorySettingsStore()
        await store.set("a", for: SettingsKey.filesLastModel)  // picked in the sheet last week
        // The user now chooses B in the sidebar picker or Settings.
        await PreferredModel.set("b", for: .file, settings: store)
        let loaded = await FileJobSettings.load(from: store, catalog: catalog)
        #expect(loaded.modelID == "b", "files must use the model the chip and Settings show")
        await PreferredModel.set(nil, for: .file, settings: store)
        #expect(await FileJobSettings.load(from: store, catalog: catalog).modelID == nil)
    }

    @Test func theSheetsModelChoiceBecomesTheDefaultEverywhere() async {
        let store = InMemorySettingsStore()
        let batch = BatchSettingsModel(urls: [file], services: services(store: store, installed: ["a", "b"]))
        await batch.prepare()
        await batch.selectModel("b")
        #expect(await batch.submit())
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == "b", "the chip and Settings agree with the sheet")
        #expect(await PreferredModel.explicitID(for: .live, settings: store) == nil, "live captions are untouched")
    }

    // MARK: Transcribe sheet

    @Test func aCancelledDownloadReturnsToAutomatic() async {
        let mock = MockModelManager(descriptors: catalog, installed: ["a"])
        await mock.setFailure(.cancelled, for: "b")
        let batch = BatchSettingsModel(urls: [file], services: services(mock: mock))
        await batch.prepare()
        await batch.selectModel("b")
        #expect(batch.modelID == nil && batch.download == .idle && batch.canSubmit)
    }

    @Test func aFailedDownloadShowsTheReasonAndRetrySucceeds() async {
        let mock = MockModelManager(descriptors: catalog, installed: ["a"])
        await mock.setFailure(.modelDownloadFailed("b", reason: "The server returned 503."), for: "b")
        let batch = BatchSettingsModel(urls: [file], services: services(mock: mock))
        await batch.prepare()
        await batch.selectModel("b")
        guard case .failed(let id, let reason) = batch.download else {
            Issue.record("expected a failure")
            return
        }
        #expect(id == "b" && reason == "The server returned 503.")
        await mock.setFailure(nil, for: "b")
        await batch.selectModel(id)  // the sheet's Try Again
        #expect(batch.download == .idle && batch.isInstalled("b"))
    }

    @Test func cancelDownloadsIsHarmlessWhenNothingIsDownloading() async {
        let batch = BatchSettingsModel(urls: [file], services: services())
        await batch.prepare()
        await batch.cancelDownloads()
        #expect(batch.download == .idle && batch.speakerDownload == .idle)
    }

    @Test func transcribeExplainsWhyItIsDisabled() async {
        let queue = PlaceholderJobQueue(seed: [Job(kind: .transcribeFile, state: .pending, input: file)])
        let batch = BatchSettingsModel(urls: [file], services: services(queue: queue))
        await batch.prepare()
        #expect(!batch.canSubmit)
        #expect(batch.submitBlockReason?.contains("already in the queue") == true)
        batch.skipDuplicates = false
        #expect(batch.canSubmit && batch.submitBlockReason == nil)
        batch.setKind(.multilingual)
        batch.toggleLanguage(.english)  // the default language set had English only
        #expect(batch.submitBlockReason == "Choose at least one language.")
    }

    // MARK: Model picker

    @Test func aPendingDownloadRemembersTheUseCaseItWasPickedFor() async {
        let mock = MockModelManager(descriptors: catalog, installed: ["a"])
        let picker = ModelPickerModel(services: services(mock: mock))
        await picker.reload()
        await picker.select("b")
        #expect(picker.pending?.useCase == .file)
        await picker.setUseCase(.live)
        #expect(picker.pending == nil, "switching tab drops an unconfirmed request")
    }

    // MARK: Library

    @Test func theLibrarySortSurvivesARelaunch() async {
        let store = InMemorySettingsStore()
        let first = LibraryModel(services: services(store: store), mode: .library)
        await first.start()
        first.sort = .titleAsc
        // The save is fire-and-forget; give it a moment.
        for _ in 0..<50 where await store.value(for: SettingsKey.librarySort, as: String.self) == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await store.value(for: SettingsKey.librarySort, as: String.self) == "titleAsc")
        let second = LibraryModel(services: services(store: store), mode: .library)
        await second.start()
        #expect(second.sort == .titleAsc)
    }
}
