import AppCore
import FeatureLive
import FeatureSupport
import Foundation
import Observation

/// Capture choices share the catalog-backed language seam with the main Live screen.
public typealias MenuLanguageChoice = TranscriptionLanguageChoice

/// Event-driven state for the menu bar item. No timers: every update comes from a protocol stream.
@MainActor @Observable
public final class MenuBarModel {
    public private(set) var inputs = MenuBarInputs()
    public private(set) var captionPreview: [CaptionLine] = []
    public private(set) var devices: [AudioDevice] = []
    public private(set) var errorMessage: String?
    /// True when the last capture failed for a missing permission, so the popup offers an inline "Request access".
    public private(set) var permissionBlocked = false
    /// Microphone and System Audio Recording, the permissions menu-bar capture needs.
    @ObservationIgnored public let permissionGate: PermissionGateModel
    public private(set) var modelSummary = "Choosing a local model…"
    public var autoRecord = false
    public var language: MenuLanguageChoice = .english {
        didSet { languageChoices = MenuLanguageChoice.options(catalog: catalog, including: language.mode) }
    }
    public private(set) var languageChoices: [MenuLanguageChoice] = [.auto, .english]
    /// `nil` means the system default input.
    public var inputDeviceUID: String?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var jobStates: [JobID: JobState] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var catalog: [ModelDescriptor] = []
    @ObservationIgnored private var modelSummaryGeneration = 0
    @ObservationIgnored private var devicesLoaded = false

    public init(services: AppServices) {
        self.services = services
        permissionGate = PermissionGateModel(kinds: [.microphone, .systemAudioRecording], service: services.permissions)
    }

    /// Current status derived from inputs.
    public var status: MenuBarStatus { MenuBarStatus.resolve(inputs) }

    /// Why Start is unavailable, or `nil` when it can start (edge case: no input device).
    public var startDisabledReason: String? { startDisabledReason(for: .mic) }

    /// System audio does not require a connected microphone.
    public func startDisabledReason(for choice: LiveSourceChoice) -> String? {
        choice.usesMicrophone && devices.isEmpty ? "No input device available" : nil
    }

    /// `true` when the app wired dictation (the menu offers the toggle only then).
    public var isDictationAvailable: Bool { services.dictation != nil }

    /// `true` while dictation is listening.
    public var isDictating: Bool { inputs.dictationArmed }

    public var isLiveRunning: Bool { inputs.liveState == .running || inputs.liveState == .starting }

    /// Starts following all services. Call once at launch; idempotent.
    public func start() {
        guard tasks.isEmpty else { return }
        let services = services
        tasks = [
            Task { [weak self] in
                await self?.loadPreferences()
                await self?.reloadModelSummary()
                for await state in services.live.state() { self?.inputs.liveState = state }
            },
            Task { [weak self] in
                for await lines in services.live.lines() { self?.captionPreview = Array(lines.suffix(3)) }
            },
            Task { [weak self] in
                for await event in services.meetingDetector.events() {
                    switch event {
                    case .started(let app, _): self?.inputs.detectedMeeting = app
                    case .ended: self?.inputs.detectedMeeting = nil
                    }
                }
            },
            Task { [weak self] in
                let events = services.jobQueue.events()
                for job in await services.jobQueue.jobs() { self?.track(job.id, job.state) }
                for await event in events {
                    switch event {
                    case .updated(let job): self?.track(job.id, job.state)
                    case .removed(let id): self?.track(id, nil)
                    }
                }
            },
            Task { [weak self] in
                guard let control = services.dictation else { return }
                for await listening in control.isListening() { self?.inputs.dictationArmed = listening }
            },
            Task { [weak self] in
                await self?.reloadDevices()
                for await _ in services.audioDevices.changes() { await self?.reloadDevices() }
            },
        ]
        followCaptureAndPreferences()
    }

    private func followCaptureAndPreferences() {
        let services = services
        if let capture = services.meetingCapture {
            tasks.append(
                Task { [weak self] in
                    for await state in capture.state() {
                        switch state {
                        case .capturing(_, let mode, _):
                            self?.inputs.isRecordingMeeting = mode.recordsAudio
                            self?.inputs.isTranscribingMeeting = !mode.recordsAudio
                        default:
                            self?.inputs.isRecordingMeeting = false
                            self?.inputs.isTranscribingMeeting = false
                        }
                    }
                })
        }
        tasks.append(
            Task { [weak self] in
                let changes = services.models.stateChanges()
                await self?.reloadModelSummary()
                for await _ in changes { await self?.reloadModelSummary() }
            })
        let keys =
            [SettingsKey.languageMode, SettingsKey.preferredModelFile, SettingsKey.inputDeviceUID, SettingsKey.autoRecord]
            + MeetingApp.allCases.map { SettingsKey.meetingPolicy($0.rawValue) }
        for key in keys {
            let changes = services.settings.changes(for: key)
            tasks.append(
                Task { [weak self] in
                    for await _ in changes {
                        await self?.loadPreferences()
                        await self?.reloadModelSummary()
                    }
                })
        }
    }

    /// Stops following services.
    public func stop() {
        for task in tasks { task.cancel() }
        tasks = []
    }

    private func track(_ id: JobID, _ state: JobState?) {
        jobStates[id] = state
        inputs.runningJobs = jobStates.values.filter { $0 == .running }.count
    }

    private func loadPreferences() async {
        autoRecord = await Self.loadAutoRecord(from: services.settings)
        if let mode = await services.settings.value(for: SettingsKey.languageMode, as: LanguageMode.self) {
            language = MenuLanguageChoice(mode: mode)
        }
        let uid = await services.settings.value(for: SettingsKey.inputDeviceUID, as: String.self)
        inputDeviceUID = (uid?.isEmpty ?? true) ? nil : uid
    }

    private func reloadModelSummary() async {
        modelSummaryGeneration += 1
        let generation = modelSummaryGeneration
        let catalog = await services.models.catalog()
        guard generation == modelSummaryGeneration, !Task.isCancelled else { return }
        self.catalog = catalog
        languageChoices = MenuLanguageChoice.options(catalog: catalog, including: language.mode)
        let descriptors = await PreferredModel.fileModels(in: catalog, settings: services.settings, tier: services.hardware.profile.tier)
        guard generation == modelSummaryGeneration, !Task.isCancelled else { return }
        guard !descriptors.isEmpty else {
            modelSummary = "Choose a speech model in Settings."
            return
        }
        var states: [ModelState] = []
        for descriptor in descriptors { states.append(await services.models.state(of: descriptor.id)) }
        guard generation == modelSummaryGeneration, !Task.isCancelled else { return }
        let ready = states.filter { if case .installed = $0 { true } else { false } }.count
        let names = descriptors.map(\.displayName).joined(separator: " + ")
        if descriptors.count > 1 {
            modelSummary =
                ready == descriptors.count
                ? "\(descriptors.count) speech models ready on this Mac"
                : "\(ready) of \(descriptors.count) speech models ready · Review Models in Settings"
        } else {
            modelSummary = "\(names) · \(Self.modelStateText(states[0]))"
        }
    }

    private static func modelStateText(_ state: ModelState) -> String {
        switch state {
        case .installed: "On this Mac"
        case .notInstalled: "Download in Settings"
        case .downloading(let fraction): "Downloading \(Int((fraction * 100).rounded()))%"
        case .paused: "Download paused"
        case .failed: "Download needs attention"
        }
    }

    private func reloadDevices() async {
        devices = await services.audioDevices.devices().filter(\.isInput)
        devicesLoaded = true
        // MENU-AC-10: a vanished mic falls back to the system default for capture. The saved choice is kept (it applies
        // again when the device returns) and the picker shows it as disconnected.
    }

    /// True when the saved microphone is not connected right now.
    public var inputDeviceIsMissing: Bool {
        guard devicesLoaded, let uid = inputDeviceUID else { return false }
        return !devices.contains { $0.id == uid }
    }

    /// The device Live capture will use: the Live override, else the global choice, while connected; otherwise the system default.
    func effectiveInputDeviceUID() async -> String? {
        let liveOverride = await services.settings.value(for: SettingsKey.liveInputDeviceUID, as: String.self)
        let chosen = MicrophonePreference.resolve(override: liveOverride, global: inputDeviceUID)
        return devicesLoaded ? MicrophonePreference.effective(chosen, connected: devices).uid : chosen
    }

    /// Starts live captions with `choice` (MENU-AC-03).
    public func startLive(_ choice: LiveSourceChoice) async {
        // Same defaults as the Live screen: "Save as transcript" and speaker labels for system audio.
        let save = await services.settings.value(for: SettingsKey.liveSaveAsTranscript, as: Bool.self) ?? false
        let preset = await services.liveExtras?.activePreset()
        let translation = await LiveTranslationPreferences.load(settings: services.settings, legacyPreset: preset)
        let readiness = await translation.readiness(languageMode: language.mode, using: services.translation)
        if let message = await LiveTranslationPreferences.setupMessage(readiness, models: services.models) {
            errorMessage = message
            return
        }
        var config = LiveSessionConfig(
            source: choice.captureSource, languageMode: language.mode, diarize: choice != .mic,
            translateTo: translation.isEnabled ? translation.target : nil, saveAsTranscript: save)
        let uid = await effectiveInputDeviceUID()
        switch choice {
        case .mic: config.source = .mic(deviceUID: uid)
        case .micAndSystem: config.source = .micAndSystem(deviceUID: uid, lanes: true)
        case .system: break
        }
        do {
            try await services.live.start(config)
            errorMessage = nil
            permissionBlocked = false
        } catch {
            errorMessage = Self.captureMessage(error)
            if case .permissionDenied = error as? AppError { permissionBlocked = true }
        }
    }

    /// Clears the inline message without hiding capture controls.
    public func dismissError() {
        errorMessage = nil
        permissionBlocked = false
    }

    private static func captureMessage(_ error: any Error) -> String? {
        guard let error = error as? AppError else {
            return "Live captions could not start. Open Earmark to review the audio and model settings."
        }
        switch error {
        case .cancelled: return nil
        case .permissionDenied:
            return "Audio access is needed. Open Privacy & Permissions in Settings to allow it, then try again."
        case .deviceUnavailable:
            return "No microphone is available. Reconnect it or choose another input."
        case .modelNotInstalled:
            return "Download a compatible speech model in Settings → Models, then try again."
        case .unsupportedLanguage(let code):
            return "No speech model is available for \(TranscriptionLanguageChoice.name(code)). Choose another language or model."
        case .outOfMemory:
            return "There is not enough memory. Close another demanding app or choose a smaller speech model."
        case .engineFailure(_, let reason), .modelDownloadFailed(_, let reason), .captureSilent(let reason), .other(let reason):
            return reason
        default:
            return "Live captions could not start. Open Earmark to review the audio and model settings."
        }
    }

    /// Starts dictation, or finishes the running session (MENU-AC-02: status shows "Dictation armed" while listening).
    public func toggleDictation() async { await services.dictation?.toggle() }

    public func stopLive() async { _ = await services.live.stop() }

    /// MTG-AC-17: "Auto-record meetings" is on when any app's policy is auto-transcribe + record. A policy stored by the
    /// Meetings screen wins over the legacy flag, which only applies to apps without one.
    static func loadAutoRecord(from settings: any SettingsStore) async -> Bool {
        let legacy = await settings.value(for: SettingsKey.autoRecord, as: Bool.self) ?? false
        for app in MeetingApp.allCases {
            let policy = await settings.value(for: SettingsKey.meetingPolicy(app.rawValue), as: MeetingPolicy.self)
            if (policy?.behavior ?? (legacy ? .autoTranscribeAndRecord : .askFirst)) == .autoTranscribeAndRecord { return true }
        }
        return false
    }

    /// Toggles auto-record for every supported meeting app by changing its stored policy (the same policy the Meetings
    /// screen edits and the meeting runtime reads); turning it off returns the apps to "Ask first".
    public func setAutoRecord(_ value: Bool) async {
        autoRecord = value
        for app in MeetingApp.allCases {
            var policy =
                await services.settings.value(for: SettingsKey.meetingPolicy(app.rawValue), as: MeetingPolicy.self)
                ?? MeetingPolicy(app: app)
            if value {
                policy.behavior = .autoTranscribeAndRecord
            } else if policy.behavior == .autoTranscribeAndRecord {
                policy.behavior = .askFirst
            }
            await services.settings.set(policy, for: SettingsKey.meetingPolicy(app.rawValue))
        }
        await services.settings.set(value, for: SettingsKey.autoRecord)
    }

    public func setLanguage(_ choice: MenuLanguageChoice) async {
        language = choice
        await choice.persist(to: services.settings, catalog: await services.models.catalog())
    }

    public func setInputDevice(_ uid: String?) async {
        inputDeviceUID = uid
        await services.settings.set(uid ?? "", for: SettingsKey.inputDeviceUID)
    }
}
