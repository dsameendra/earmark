import AppCore
import AudioCapture
import FeatureSupport
import Foundation
import LiveCaptions
import os

/// Builds the capture lanes for a live session over the `AudioCapture` sources (LIVE-AC-04): Mic, System, one app, or
/// Mic + System as two labelled lanes ("You" mic, "Them" system). Sources are single use, so each session gets new ones.
/// Also fans the level of every running lane into one meter stream for the Live screen.
final class LiveAudioProvider: LiveAudioProviding, Sendable {
    private let permissions: any PermissionsServicing
    private let settings: any SettingsStore
    private let deviceProvider: any AudioDeviceProviding
    private let levelBus = FeatureSupport.Broadcaster<Float>()
    private let laneLevels = OSAllocatedUnfairLock<[Int: Float]>(initialState: [:])

    init(permissions: any PermissionsServicing, settings: any SettingsStore, deviceProvider: any AudioDeviceProviding) {
        self.permissions = permissions
        self.settings = settings
        self.deviceProvider = deviceProvider
    }

    func levels() -> AsyncStream<Float> { levelBus.stream() }

    func lanes(for source: CaptureSource) async throws -> [LiveAudioLane] {
        let voiceProcessing = await settings.value(for: SettingsKey.voiceProcessing, as: Bool.self) ?? false
        func mic(_ uid: String?) -> MicrophoneSource {
            MicrophoneSource(
                deviceUID: uid, voiceProcessing: voiceProcessing, permissions: permissions, deviceProvider: deviceProvider)
        }
        let lanes: [LiveAudioLane]
        switch source {
        case .mic(let uid):
            lanes = [LiveAudioLane(source: mic(uid), diarize: false)]
        case .system:
            lanes = [LiveAudioLane(source: SystemAudioSource(target: .system, permissions: permissions))]
        case .app(let bundleID):
            lanes = [LiveAudioLane(source: SystemAudioSource(target: .app(bundleID: bundleID), permissions: permissions))]
        case .micAndSystem(let uid, let labelled):
            // Both lanes feed one caption list; labelled lanes tag the mic "You" and the system audio "Them".
            lanes = [
                LiveAudioLane(label: labelled ? "You" : nil, source: mic(uid), diarize: false),
                LiveAudioLane(label: labelled ? "Them" : nil, source: SystemAudioSource(target: .system, permissions: permissions)),
            ]
        }
        laneLevels.withLock { $0 = [:] }
        for (index, lane) in lanes.enumerated() {
            let stream = lane.source.levels
            Task.detached { [levelBus, laneLevels] in
                for await level in stream {
                    let loudest = laneLevels.withLock { levels -> Float in
                        levels[index] = level
                        return levels.values.max() ?? level
                    }
                    levelBus.send(loudest)
                }
                laneLevels.withLock { _ = $0.removeValue(forKey: index) }
                levelBus.send(laneLevels.withLock { $0.values.max() ?? 0 })
            }
        }
        return lanes
    }
}

/// App-side `LiveSessionExtras`: pause, level meter, notices, the caption overlay (bound to the orchestrator) and presets.
/// The overlay follows the session itself, instead of `CaptionOverlayController.bind(to:)`, so the "Show overlay" toggle
/// can suppress it without a flash.
final class LiveExtrasService: LiveSessionExtras, Sendable {
    private let session: LiveSessionOrchestrator
    private let audio: LiveAudioProvider
    private let overlay: CaptionOverlayController
    private let presetStore: CaptionPresetStore
    private let settings: any SettingsStore
    private let noticeBus = FeatureSupport.Broadcaster<LiveNotice>()
    private let isRunning = OSAllocatedUnfairLock(initialState: false)

    init(
        session: LiveSessionOrchestrator, audio: LiveAudioProvider, overlay: CaptionOverlayController,
        presetStore: CaptionPresetStore, settings: any SettingsStore
    ) {
        self.session = session
        self.audio = audio
        self.overlay = overlay
        self.presetStore = presetStore
        self.settings = settings
    }

    /// Starts following the session (call once, from the main actor).
    @MainActor func start() {
        let lines = session.lines()
        let states = session.state()
        let events = session.events()
        Task { @MainActor [overlay] in
            for await next in lines { overlay.model.ingest(next) }
        }
        Task { @MainActor [self] in
            for await state in states {
                switch state {
                case .running:
                    isRunning.withLock { $0 = true }
                    overlay.model.isCaptioning = true
                    if await isOverlayEnabled() { await overlay.show(preset: await presetStore.activeOrDefault()) }
                case .idle, .failed:
                    isRunning.withLock { $0 = false }
                    overlay.model.isCaptioning = false
                    overlay.model.isPaused = false
                    await overlay.hide()
                    overlay.model.reset()
                case .starting, .stopping:
                    break
                }
            }
        }
        Task { @MainActor [self] in
            for await event in events {
                if case .paused = event { overlay.setPaused(true) }
                if case .resumed = event { overlay.setPaused(false) }
                if let notice = Self.notice(for: event) { noticeBus.send(notice) }
            }
        }
    }

    static func notice(for event: LiveSessionEvent) -> LiveNotice? {
        switch event {
        case .paused: LiveNotice(kind: .paused, message: "Paused. Audio is not being transcribed.")
        case .resumed: LiveNotice(kind: .resumed, message: "Resumed.")
        case .deviceFallback(let name):
            LiveNotice(kind: .info, message: "The input device went away. Using \(name ?? "the system default") instead.")
        case .captureProblem(let error):
            if case .captureSilent = error {
                LiveNotice(
                    kind: .problem,
                    message: "No audio is arriving. Check the microphone and System Audio Recording permissions in System Settings.")
            } else {
                LiveNotice(kind: .problem, message: String(describing: error))
            }
        case .speakerLimitReached: LiveNotice(kind: .info, message: "More than four speakers. Extra voices are labelled More speakers.")
        case .checkpointFailed(let reason): LiveNotice(kind: .warning, message: "Could not save the transcript so far: \(reason)")
        }
    }

    // MARK: LiveSessionExtras

    func setPaused(_ paused: Bool) async {
        if paused { await session.pause() } else { await session.resume() }
    }

    func levels() -> AsyncStream<Float> { audio.levels() }
    func notices() -> AsyncStream<LiveNotice> { noticeBus.stream() }

    func setOverlayEnabled(_ enabled: Bool) async {
        await settings.set(enabled, for: SettingsKey.liveOverlayEnabled)
        guard isRunning.withLock({ $0 }) else { return }
        if enabled { await overlay.show(preset: await presetStore.activeOrDefault()) } else { await overlay.hide() }
    }

    func isOverlayEnabled() async -> Bool { await settings.value(for: SettingsKey.liveOverlayEnabled, as: Bool.self) ?? true }

    func presets() async -> [CaptionPreset] { (try? await presetStore.all()) ?? CaptionPresetCatalog.builtIns }
    func activePreset() async -> CaptionPreset { await presetStore.activeOrDefault() }
    func setActivePreset(_ id: PresetID) async {
        await presetStore.setActive(id)
        if isRunning.withLock({ $0 }), await isOverlayEnabled() { await overlay.show(preset: await presetStore.activeOrDefault()) }
    }

    func commit(_ preset: CaptionPreset) async -> CaptionPreset {
        var result = preset
        do {
            if CaptionPresetCatalog.isBuiltIn(preset.id) || preset.isBuiltIn {
                result = try await presetStore.saveAs(preset, name: "\(preset.name) (custom)")
                await presetStore.setActive(result.id)
            } else {
                try await presetStore.update(preset)
            }
        } catch {
            AppLog.logger("liveExtras").error("Could not save caption preset: \(String(describing: error), privacy: .public)")
        }
        if isRunning.withLock({ $0 }), await isOverlayEnabled() { await overlay.show(preset: result) }
        return result
    }
}

extension CaptionPresetStore {
    fileprivate func activeOrDefault() async -> CaptionPreset {
        (try? await activePreset()) ?? CaptionPresetCatalog.defaultPreset
    }
}
