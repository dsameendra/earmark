import AppCore
import FeatureLive
import FeatureMenuBar
import FeatureSupport
import Foundation
import Testing

private actor RecordingLive: LiveSessionControlling {
    private(set) var configs: [LiveSessionConfig] = []
    private let stateBus = Broadcaster<LiveSessionState>()
    private let linesBus = Broadcaster<[CaptionLine]>()
    nonisolated let stateSubscriptions = SubscriptionCount()
    var transcriptID: TranscriptID?

    func start(_ config: LiveSessionConfig) async throws {
        configs.append(config)
        stateBus.send(.running)
    }
    func stop() async -> TranscriptID? {
        stateBus.send(.idle)
        return transcriptID
    }
    func setTranscriptID(_ id: TranscriptID?) { transcriptID = id }
    nonisolated func state() -> AsyncStream<LiveSessionState> {
        stateSubscriptions.hit()
        return stateBus.stream(initial: .idle)
    }
    nonisolated func lines() -> AsyncStream<[CaptionLine]> { linesBus.stream(initial: []) }
}

private final class FakeExtras: LiveSessionExtras, @unchecked Sendable {
    private let lock = NSLock()
    private var _paused: [Bool] = []
    private var _committed: [CaptionPreset] = []
    let levelBus = Broadcaster<Float>()
    let noticeBus = Broadcaster<LiveNotice>()
    let levelSubscriptions = SubscriptionCount()
    let noticeSubscriptions = SubscriptionCount()
    var paused: [Bool] { lock.withLock { _paused } }
    var committed: [CaptionPreset] { lock.withLock { _committed } }
    var overlay = true

    func setPaused(_ paused: Bool) async { lock.withLock { _paused.append(paused) } }
    func levels() -> AsyncStream<Float> {
        levelSubscriptions.hit()
        return levelBus.stream()
    }
    func notices() -> AsyncStream<LiveNotice> {
        noticeSubscriptions.hit()
        return noticeBus.stream()
    }
    func setOverlayEnabled(_ enabled: Bool) async { overlay = enabled }
    func isOverlayEnabled() async -> Bool { overlay }
    func presets() async -> [CaptionPreset] { [CaptionPreset(name: "Subtle")] }
    func activePreset() async -> CaptionPreset { CaptionPreset(name: "Subtle") }
    func setActivePreset(_ id: PresetID) async {}
    func commit(_ preset: CaptionPreset) async -> CaptionPreset {
        lock.withLock { _committed.append(preset) }
        return preset
    }
}

@Suite @MainActor struct LiveScreenTests {
    private func make(live: RecordingLive = RecordingLive(), extras: FakeExtras? = FakeExtras()) -> (LiveModel, RecordingLive, FakeExtras?, InMemorySettingsStore) {
        let store = InMemorySettingsStore()
        var services = AppServices.preview()
        services.live = live
        services.settings = store
        services.liveExtras = extras
        return (LiveModel(services: services), live, extras, store)
    }

    @Test func defaultsToEnglishAndStartsWithChosenSourceAndDevice() async throws {
        let (model, live, _, _) = make()
        #expect(model.language == .english)
        model.source = .micAndSystem
        model.deviceUID = "uid-1"
        model.saveAsTranscript = true
        let states = Task { await model.watchState() }
        #expect(await eventually { live.stateSubscriptions.value > 0 })
        await model.start()
        let config = try #require(await live.configs.first)
        #expect(config.source == .micAndSystem(deviceUID: "uid-1", lanes: true))
        #expect(config.languageMode == .single(.english))
        #expect(config.saveAsTranscript)
        #expect(config.diarize)
        states.cancel()
    }

    @Test func micOnlyDoesNotDiarize() async throws {
        let (model, live, _, _) = make()
        await model.start()
        #expect(await live.configs.first?.diarize == false)
    }

    @Test func pauseForwardsToExtrasAndNoticesFollow() async throws {
        let (model, live, extras, _) = make()
        let extrasValue = try #require(extras)
        let states = Task { await model.watchState() }
        let notices = Task { await model.watchNotices() }
        #expect(await eventually { live.stateSubscriptions.value > 0 && extrasValue.noticeSubscriptions.value > 0 })
        await model.start()
        #expect(await eventually { model.isRunning })
        await model.togglePause()
        #expect(model.isPaused)
        #expect(extrasValue.paused == [true])
        extrasValue.noticeBus.send(LiveNotice(kind: .resumed, message: "Resumed"))
        #expect(await eventually { !model.isPaused })
        #expect(!model.isPaused)
        states.cancel()
        notices.cancel()
    }

    @Test func levelsAreOnlyShownWhileRunning() async throws {
        let (model, live, extras, _) = make()
        let extrasValue = try #require(extras)
        let states = Task { await model.watchState() }
        let levels = Task { await model.watchLevels() }
        #expect(await eventually { live.stateSubscriptions.value > 0 && extrasValue.levelSubscriptions.value > 0 })
        extrasValue.levelBus.send(0.8)
        // Negative check: a level while idle must never show. A bounded window cannot fail spuriously under load (a late
        // delivery still sees `isRunning == false` because the session has not been started yet).
        #expect(await eventually(timeout: .milliseconds(200)) { model.level != 0 } == false)
        await model.start()
        #expect(await eventually { model.isRunning })
        extrasValue.levelBus.send(0.8)
        #expect(await eventually { model.level > 0.5 })
        states.cancel()
        levels.cancel()
    }

    @Test func preferencesPersistAndReload() async throws {
        let (model, _, _, store) = make()
        model.saveAsTranscript = true
        model.language = .sinhala
        model.source = .system
        #expect(
            await eventually {
                let saved = await store.value(for: SettingsKey.liveSaveAsTranscript, as: Bool.self)
                let language = await store.value(for: SettingsKey.languageMode, as: LanguageMode.self)
                return saved == true && language == .single(.sinhala)
            })
        #expect(await store.value(for: SettingsKey.liveSaveAsTranscript, as: Bool.self) == true)
        #expect(await store.value(for: SettingsKey.languageMode, as: LanguageMode.self) == .single(.sinhala))
        var services = AppServices.preview()
        services.settings = store
        let reloaded = LiveModel(services: services)
        await reloaded.loadPreferences()
        #expect(reloaded.source == .system && reloaded.language == .sinhala && reloaded.saveAsTranscript)
    }

    @Test func presetEditsAreCommittedAfterDebounce() async throws {
        let (model, _, extras, _) = make()
        let extrasValue = try #require(extras)
        await model.loadPreferences()
        var edited = model.preset
        edited.visibleLines = 3
        model.updatePreset(edited)
        #expect(model.preset.visibleLines == 3)
        #expect(await eventually { extrasValue.committed.last?.visibleLines == 3 })  // after the debounce
        #expect(extrasValue.committed.last?.visibleLines == 3)
    }

    @Test func overlayToggleIsForwarded() async throws {
        let (model, _, extras, _) = make()
        let extrasValue = try #require(extras)
        await model.setOverlayEnabled(false)
        #expect(!model.overlayEnabled)
        #expect(!extrasValue.overlay)
    }

    @Test func failedStartSurfacesAsFailedState() async {
        struct Failing: LiveSessionControlling {
            func start(_ config: LiveSessionConfig) async throws { throw AppError.deviceUnavailable }
            func stop() async -> TranscriptID? { nil }
            func state() -> AsyncStream<LiveSessionState> { AsyncStream { _ in } }
            func lines() -> AsyncStream<[CaptionLine]> { AsyncStream { _ in } }
        }
        var services = AppServices.preview()
        services.live = Failing()
        let model = LiveModel(services: services)
        await model.start()
        if case .failed = model.state {} else { Issue.record("expected failed state") }
    }
}

@Suite @MainActor struct MenuBarDictationTests {
    @Test func dictationToggleArmsStatusAndCallsApp() async throws {
        let bus = Broadcaster<Bool>()
        let calls = CallCounter()
        let subscriptions = SubscriptionCount()
        var services = AppServices.preview()
        services.dictation = DictationMenuControl(
            isListening: {
                subscriptions.hit()
                return bus.stream(initial: false)
            }, toggle: { await calls.increment() })
        let model = MenuBarModel(services: services)
        #expect(model.isDictationAvailable)
        model.start()
        #expect(await eventually { subscriptions.value > 0 })
        await model.toggleDictation()
        #expect(await calls.value == 1)
        bus.send(true)
        #expect(await eventually { model.isDictating })
        #expect(model.isDictating)
        #expect(model.status == .dictationArmed)
        model.stop()
    }

    @Test func menuBarStartHonoursSaveAsTranscriptAndDiarization() async throws {
        let live = RecordingLive()
        let store = InMemorySettingsStore()
        await store.set(true, for: SettingsKey.liveSaveAsTranscript)
        var services = AppServices.preview()
        services.live = live
        services.settings = store
        let model = MenuBarModel(services: services)
        await model.startLive(.system)
        let config = try #require(await live.configs.first)
        #expect(config.saveAsTranscript)
        #expect(config.diarize)
    }

    @Test func noDictationControlMeansUnavailable() {
        #expect(!MenuBarModel(services: .preview()).isDictationAvailable)
    }
}

private actor CallCounter {
    var value = 0
    func increment() { value += 1 }
}
