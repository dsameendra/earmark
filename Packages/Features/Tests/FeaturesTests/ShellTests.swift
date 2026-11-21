import AppCore
import FeatureHome
import FeatureLive
import FeatureMenuBar
import FeatureSettings
import FeatureShell
import FeatureSupport
import Foundation
import Testing

@Suite @MainActor struct ShellTests {
    @Test func sidebarListsSixSectionsHomeFirst() {
        #expect(AppSection.allCases.map(\.title) == ["Home", "Queue", "Meetings", "Live", "Library", "Recently Deleted"])
        #expect(AppSection.allCases.map(\.shortcutNumber) == [1, 2, 3, 4, 5, 6])  // NAV-AC-02
    }

    @Test func firstLaunchSelectsHome() async {
        let model = ShellModel(services: .preview())
        await model.restore()
        #expect(model.selection == .home)  // NAV-AC-01
    }

    @Test func lastSectionIsPersistedAndRestored() async {  // NAV-AC-15
        let store = InMemorySettingsStore()
        var services = AppServices.preview()
        services.settings = store
        let first = ShellModel(services: services)
        first.select(.library)
        try? await Task.sleep(for: .milliseconds(100))
        let second = ShellModel(services: services)
        await second.restore()
        #expect(second.selection == .library)
        #expect(await SectionPersistence(store: store).load() == .library)
    }

    @Test func dropEnqueuesAndNavigatesToQueue() async {  // NAV-AC-05
        let queue = PlaceholderJobQueue()
        var services = AppServices.preview()
        services.jobQueue = queue
        let model = ShellModel(services: services)
        await model.enqueue([URL(fileURLWithPath: "/tmp/a.m4a")])
        #expect(await queue.jobs().count == 1)
        #expect(model.selection == .queue)
    }

    @Test func quickOpenFindsTitles() async {  // NAV-AC-03
        let item = Transcript(title: "Budget review", source: .file)
        let model = QuickOpenModel(transcripts: InMemoryTranscripts(items: [item]))
        model.query = "budget"
        await model.search()
        #expect(model.highlightedResult?.id == item.id)
    }

    @Test func jobsSummaryAggregates() {  // NAV-AC-06
        let jobs = [
            Job(kind: .transcribeFile, state: .running, progress: 0.5), Job(kind: .transcribeFile, state: .pending, progress: 0),
            Job(kind: .transcribeFile, state: .failed),
        ]
        let summary = ActiveJobsSummary(jobs: jobs)
        #expect(summary.running == 1 && summary.pending == 1 && summary.failed == 1)
        #expect(summary.aggregateProgress == 0.25)
    }

    @Test func homeDownloadsMissingModelBeforeContinuing() async {  // NAV-AC-07
        let descriptor = ModelDescriptor(
            id: "m1", displayName: "Test", kind: .asr, runtime: .coreML, languages: [.english], sizeBytes: 1,
            license: LicenseInfo(spdx: "MIT"))
        var services = AppServices.preview()
        services.models = MockModelManagerForTests(descriptor: descriptor)
        let home = HomeModel(services: services)
        #expect(await home.ensureDefaultModel())
        #expect(home.download == nil)
    }

    @Test func liveShowsLinesAndStops() async {  // NAV-AC-13
        let live = LiveModel(services: .preview())
        let watchers = Task { await live.watchLines() }
        let states = Task { await live.watchState() }
        try? await Task.sleep(for: .milliseconds(100))  // let the watchers subscribe
        await live.start()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(live.isRunning)
        #expect(live.lines.first?.isVolatile == true)
        await live.stop()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!live.isRunning)
        watchers.cancel()
        states.cancel()
    }
}

@Suite @MainActor struct MenuBarTests {
    @Test func statusPriorityAndText() {  // MENU-AC-02
        #expect(MenuBarStatus.resolve(MenuBarInputs()) == .idle)
        #expect(MenuBarStatus.resolve(MenuBarInputs(runningJobs: 2)) == .queueRunning(2))
        #expect(MenuBarStatus.resolve(MenuBarInputs(dictationArmed: true, runningJobs: 1)) == .dictationArmed)
        #expect(MenuBarStatus.resolve(MenuBarInputs(detectedMeeting: .zoom, runningJobs: 1)) == .meetingDetected(.zoom))
        #expect(MenuBarStatus.resolve(MenuBarInputs(liveState: .running, detectedMeeting: .zoom)) == .liveCaptions)
        let recording = MenuBarStatus.resolve(MenuBarInputs(liveState: .running, isRecordingMeeting: true))
        #expect(recording == .meetingRecording && recording.isRecording)  // MENU-AC-07
    }

    @Test func modelReflectsLiveSessionWithinHalfSecond() async {
        let model = MenuBarModel(services: .preview())
        model.start()
        try? await Task.sleep(for: .milliseconds(100))  // let the stream tasks subscribe
        await model.startLive(.mic)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.status == .liveCaptions)
        #expect(model.isLiveRunning)
        await model.stopLive()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.status == .idle)
        model.stop()
    }

    @Test func languagePickerPersistsDefault() async {  // MENU-AC-09
        let store = InMemorySettingsStore()
        var services = AppServices.preview()
        services.settings = store
        let model = MenuBarModel(services: services)
        await model.setLanguage(.sinhala)
        #expect(await store.value(for: SettingsKey.languageMode, as: LanguageMode.self) == .single(.sinhala))
    }

    @Test func settingsCoverAllSectionsAndDockPreferenceDefaultsOn() async {  // SET-AC-01, MENU-AC-08
        #expect(SettingsSection.allCases.count == 15)
        let store = InMemorySettingsStore()
        #expect(await GeneralSettingsModel.loadShowDockIcon(from: store))
        let general = GeneralSettingsModel(store: store)
        await general.setShowDockIcon(false)
        #expect(await GeneralSettingsModel.loadShowDockIcon(from: store) == false)
    }
}

/// Minimal manager whose model is "not installed" until `ensureAvailable` runs.
private struct MockModelManagerForTests: ModelManaging {
    let descriptor: ModelDescriptor
    func catalog() async -> [ModelDescriptor] { [descriptor] }
    func state(of model: ModelID) async -> ModelState { .notInstalled }
    func stateChanges() -> AsyncStream<(ModelID, ModelState)> { AsyncStream { _ in } }
    func installedModels() async -> Set<ModelID> { [] }
    func ensureAvailable(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(fraction: 0.5, bytesReceived: 1, bytesTotal: 2))
            continuation.yield(.completed)
            continuation.finish()
        }
    }
    func pauseDownload(_ model: ModelID) async {}
    func resumeDownload(_ model: ModelID) async {}
    func cancelDownload(_ model: ModelID) async {}
    func delete(_ model: ModelID) async throws {}
    func importModel(folder: URL, displayName: String, languages: Set<LanguageCode>) async throws -> ModelDescriptor { descriptor }
    func diskUsage() async -> DiskUsage { DiskUsage(totalBytes: 0, perModel: [:]) }
    func location(of model: ModelID) async throws -> URL { throw AppError.modelNotInstalled(model) }
}
