import AppCore
import AppCoreTesting
import FeatureMenuBar
import FeatureSettings
import FeatureSupport
import Foundation
import Testing

@Suite("Settings and quick controls") @MainActor
struct SettingsMenuPolishTests {
    @Test func settingsSidebarKeepsEverySectionReachableOnce() {
        let sections = SettingsSectionGroup.allCases.flatMap(\.sections)
        #expect(sections.count == SettingsSection.allCases.count)
        #expect(Set(sections) == Set(SettingsSection.allCases))
        #expect(Set(sections).count == sections.count)
        #expect(sections.allSatisfy { !$0.summary.isEmpty })
    }

    @Test func catalogLanguageChoicesPreserveFrenchAndMultilingualModes() {
        let catalog = [model("global", languages: [.english, .sinhala, "fr", "ja"])]
        let french = TranscriptionLanguageChoice(mode: .single("fr"))
        #expect(french.mode == .single("fr"))
        #expect(french != .english)
        let options = TranscriptionLanguageChoice.options(catalog: catalog, including: french.mode)
        #expect(options.first == .auto)
        #expect(options.contains(french))
        #expect(options.filter { if case .single = $0.mode { true } else { false } }.count == 4)
        let multilingual = TranscriptionLanguageChoice(mode: .multilingual(["fr", "ja"]))
        #expect(TranscriptionLanguageChoice.options(catalog: [], including: multilingual.mode).contains(multilingual))
        #expect(multilingual != .auto)
        #expect(TranscriptionLanguageChoice.options(catalog: [], including: .single("fr")).contains(french))
    }

    @Test func menuTracksExternalLanguageAndModelPreferences() async {
        let store = InMemorySettingsStore()
        var services = AppServices.preview()
        services.settings = store
        services.models = MockModelManager(descriptors: [model("english", languages: [.english]), model("french", languages: ["fr"])])
        let menu = MenuBarModel(services: services)
        menu.start()
        defer { menu.stop() }
        #expect(await eventually { menu.modelSummary.contains("english") })
        await store.set(LanguageMode.single("fr"), for: SettingsKey.languageMode)
        #expect(await eventually { menu.language.mode == .single("fr") && menu.modelSummary.contains("french") })
        #expect(menu.languageChoices.contains(TranscriptionLanguageChoice(mode: .single("fr"))))
    }

    @Test func menuShowsActualMeetingCaptureAndStopsItsIndicator() async throws {
        let capture = FakeCapture()
        var services = AppServices.preview()
        services.meetingCapture = capture
        let menu = MenuBarModel(services: services)
        menu.start()
        defer { menu.stop() }
        #expect(await eventually { capture.stateSubscriptions.value > 0 })
        try await capture.start(app: .zoom, mode: .transcribeAndRecord)
        #expect(await eventually { menu.status == .meetingRecording && menu.status.isRecording })
        _ = await capture.stop()
        #expect(await eventually { !menu.status.isRecording })
        try await capture.start(app: .zoom, mode: .transcribeOnly)
        #expect(await eventually { menu.status == .meetingTranscribing && menu.status.isRecording })
    }

    @Test func systemAudioDoesNotRequireAnInputDevice() {
        let menu = MenuBarModel(services: .preview())
        #expect(menu.startDisabledReason(for: .mic) != nil)
        #expect(menu.startDisabledReason(for: .system) == nil)
        #expect(menu.startDisabledReason(for: .micAndSystem) != nil)
        #expect(MenuBarStatus.liveCaptions.isRecording)
        #expect(MenuBarStatus.dictationArmed.isRecording)
    }

    @Test func menuCaptureFailureExplainsRecoveryAndCanBeDismissed() async {
        var services = AppServices.preview()
        services.live = UnavailableInputLive()
        let menu = MenuBarModel(services: services)
        await menu.startLive(.mic)
        #expect(menu.errorMessage?.contains("No microphone") == true)
        #expect(menu.errorMessage?.contains("deviceUnavailable") == false)
        menu.dismissError()
        #expect(menu.errorMessage == nil)
    }

    @Test func detectionDoesNotMaskAnActiveDictationIndicator() {
        let status = MenuBarStatus.resolve(MenuBarInputs(detectedMeeting: .zoom, dictationArmed: true))
        #expect(status == .dictationArmed)
        #expect(status.isRecording)
    }

    @Test func menuModelSummaryUsesHardwareTierAndAllRequiredModels() async {
        var services = AppServices.preview()
        services.hardware = SmallMenuHardware()
        services.models = MockModelManager(descriptors: [
            model("whisperkit/large-v3-v20240930_626MB", languages: [.english]),
            model("whisperkit/small", languages: [.english]),
        ])
        let small = MenuBarModel(services: services)
        small.start()
        #expect(await eventually { small.modelSummary.contains("whisperkit/small") })
        small.stop()

        let store = InMemorySettingsStore()
        await store.set(LanguageMode.multilingual([.english, "fr"]), for: SettingsKey.languageMode)
        services.settings = store
        services.models = MockModelManager(
            descriptors: [model("english", languages: [.english]), model("french", languages: ["fr"])], installed: ["english"])
        let multi = MenuBarModel(services: services)
        multi.start()
        defer { multi.stop() }
        #expect(await eventually { multi.modelSummary.contains("1 of 2") })
        #expect(multi.language.mode == .multilingual([.english, "fr"]))
        #expect(multi.languageChoices.contains(multi.language))
    }

    private func model(_ id: String, languages: Set<LanguageCode>) -> ModelDescriptor {
        ModelDescriptor(
            id: ModelID(id), displayName: id, kind: .asr, runtime: .coreML, languages: languages,
            sizeBytes: 1, license: LicenseInfo(spdx: "MIT"))
    }
}

private struct UnavailableInputLive: LiveSessionControlling {
    func start(_ config: LiveSessionConfig) async throws { throw AppError.deviceUnavailable }
    func stop() async -> TranscriptID? { nil }
    func state() -> AsyncStream<LiveSessionState> { AsyncStream { $0.finish() } }
    func lines() -> AsyncStream<[CaptionLine]> { AsyncStream { $0.finish() } }
}

private struct SmallMenuHardware: HardwareTierProviding {
    let profile = HardwareProfile(chip: "Test", memoryBytes: 8 << 30, performanceCores: 4, tier: .tier8)
    func isOnBattery() -> Bool { false }
    func memoryPressure() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func thermalPressure() -> AsyncStream<ThermalPressure> { AsyncStream { $0.finish() } }
}
