import AppCore
import AppCoreTesting
import FeatureHome
import FeatureLibrary
import FeatureQueue
import FeatureShell
import FeatureSupport
import Foundation
import Testing

@Suite("Consistent file defaults") @MainActor
struct FileJobDefaultsTests {
    private var catalog: [ModelDescriptor] {
        [
            ModelDescriptor(
                id: "english", displayName: "English", kind: .asr, runtime: .coreML,
                languages: [.english], sizeBytes: 1, license: LicenseInfo(spdx: "MIT")),
            ModelDescriptor(
                id: "multilingual", displayName: "Multilingual", kind: .asr, runtime: .coreML,
                languages: [.english, "fr", "es"], sizeBytes: 1, license: LicenseInfo(spdx: "MIT")),
        ]
    }

    @Test func incompatiblePreferenceKeepsTheLanguageAndUsesAutomaticRouting() async {
        let store = InMemorySettingsStore()
        await store.set(LanguageMode.single("fr-FR"), for: SettingsKey.languageMode)
        await store.set("english", for: SettingsKey.preferredModel)
        let automatic = await FileJobSettings.load(from: store, catalog: catalog)
        #expect(automatic.languageMode == .single("fr-FR") && automatic.modelID == nil)
        await store.set("multilingual", for: SettingsKey.preferredModel)
        let explicit = await FileJobSettings.load(from: store, catalog: catalog)
        #expect(explicit.modelID == "multilingual")
    }

    @Test func retranscriptionLanguageOverrideDoesNotRewriteGlobalPreferences() async {
        let store = InMemorySettingsStore()
        await store.set(LanguageMode.single(.english), for: SettingsKey.languageMode)
        await store.set("english", for: SettingsKey.preferredModel)
        let settings = await FileJobSettings.load(from: store, catalog: catalog, languageOverride: .multilingual(["fr", "es"]))
        #expect(settings.languageMode == .multilingual(["fr", "es"]) && settings.modelID == nil)
        #expect(await store.value(for: SettingsKey.languageMode, as: LanguageMode.self) == .single(.english))
    }

    @Test func shellHomeAndBatchStartWithTheSameSavedDefaults() async throws {
        let store = InMemorySettingsStore()
        await store.set(LanguageMode.single("fr"), for: SettingsKey.languageMode)
        await store.set("multilingual", for: SettingsKey.preferredModel)
        var services = AppServices.preview()
        services.settings = store
        services.models = MockModelManager(descriptors: catalog)
        let shell = ShellModel(services: services)
        await shell.enqueue([URL(fileURLWithPath: "/tmp/shell-demo.wav")])
        let home = HomeModel(services: services)
        #expect(await home.enqueue([URL(fileURLWithPath: "/tmp/home-demo.wav")]))
        let jobs = await services.jobQueue.jobs()
        #expect(jobs.count == 2)
        #expect(jobs.allSatisfy { $0.settings.languageMode == .single("fr") && $0.settings.modelID == "multilingual" })
        let batch = BatchSettingsModel(urls: [], services: services)
        await batch.prepare()
        #expect(batch.languageMode == .single("fr") && batch.modelID == "multilingual")
        batch.setSingleLanguage("es")
        await batch.prepare()
        #expect(batch.languageMode == .single("es"), "Refreshing a batch must preserve explicit edits")
    }

    @Test func aCompletedJobRefreshesTheOpenLibraryAndMarksOnlyNewItems() async throws {
        let initial = Transcript(title: "Existing", source: .file)
        let repository = InMemoryTranscripts(items: [initial])
        let queue = PlaceholderJobQueue()
        var services = AppServices.preview()
        services.transcripts = repository
        services.jobQueue = queue
        let library = LibraryModel(services: services, mode: .library)
        await library.refresh()
        let following = Task { await library.watchJobCompletions() }
        defer { following.cancel() }
        #expect(await eventually { library.isFollowingJobs })
        let added = Transcript(title: "New recording", source: .file)
        try await repository.save(added)
        _ = try await queue.enqueue(Job(kind: .transcribeFile, state: .completed, transcriptID: added.id))
        #expect(await eventually { library.items.count == 2 && library.newlyAddedIDs == [added.id] })
        #expect(library.items.contains { $0.id == initial.id })
    }
}
