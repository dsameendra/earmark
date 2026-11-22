import AppCore
import FeatureLive
import FeatureSupport
import Foundation
import Observation

/// Quick language choices in the menu (MENU-AC-09).
public enum MenuLanguageChoice: String, CaseIterable, Identifiable, Sendable {
    case english, sinhala, auto
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .english: "English"
        case .sinhala: "Sinhala (experimental)"
        case .auto: "Auto-detect"
        }
    }
    public var mode: LanguageMode {
        switch self {
        case .english: .single(.english)
        case .sinhala: .single(.sinhala)
        case .auto: .autoDetect
        }
    }
    public init(mode: LanguageMode) {
        switch mode {
        case .single(let code) where code.primary == .sinhala: self = .sinhala
        case .autoDetect, .multilingual: self = .auto
        default: self = .english
        }
    }
}

/// Event-driven state for the menu bar item. No timers: every update comes from a protocol stream.
@MainActor @Observable
public final class MenuBarModel {
    public private(set) var inputs = MenuBarInputs()
    public private(set) var captionPreview: [CaptionLine] = []
    public private(set) var devices: [AudioDevice] = []
    public private(set) var errorMessage: String?
    public var autoRecord = false
    public var language: MenuLanguageChoice = .english
    /// `nil` means the system default input.
    public var inputDeviceUID: String?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var jobStates: [JobID: JobState] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init(services: AppServices) { self.services = services }

    /// Current status derived from inputs.
    public var status: MenuBarStatus { MenuBarStatus.resolve(inputs) }

    /// Why Start is unavailable, or `nil` when it can start (edge case: no input device).
    public var startDisabledReason: String? { devices.isEmpty ? "No input device available" : nil }

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
                for job in await services.jobQueue.jobs() { self?.track(job.id, job.state) }
                for await event in services.jobQueue.events() {
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
    }

    /// Stops following services.
    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    private func track(_ id: JobID, _ state: JobState?) {
        jobStates[id] = state
        inputs.runningJobs = jobStates.values.filter { $0 == .running }.count
    }

    private func loadPreferences() async {
        autoRecord = await services.settings.value(for: SettingsKey.autoRecord, as: Bool.self) ?? false
        if let mode = await services.settings.value(for: SettingsKey.languageMode, as: LanguageMode.self) {
            language = MenuLanguageChoice(mode: mode)
        }
        let uid = await services.settings.value(for: SettingsKey.inputDeviceUID, as: String.self)
        inputDeviceUID = (uid?.isEmpty ?? true) ? nil : uid
    }

    private func reloadDevices() async {
        devices = await services.audioDevices.devices().filter(\.isInput)
        // MENU-AC-10: a vanished mic falls back to the system default.
        if let uid = inputDeviceUID, !devices.contains(where: { $0.id == uid }) { await setInputDevice(nil) }
    }

    /// Starts live captions with `choice` (MENU-AC-03).
    public func startLive(_ choice: LiveSourceChoice) async {
        // Same defaults as the Live screen: "Save as transcript" and speaker labels for system audio.
        let save = await services.settings.value(for: SettingsKey.liveSaveAsTranscript, as: Bool.self) ?? false
        var config = LiveSessionConfig(
            source: choice.captureSource, languageMode: language.mode, diarize: choice != .mic, saveAsTranscript: save)
        switch choice {
        case .mic: config.source = .mic(deviceUID: inputDeviceUID)
        case .micAndSystem: config.source = .micAndSystem(deviceUID: inputDeviceUID, lanes: true)
        case .system: break
        }
        do {
            try await services.live.start(config)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Starts dictation, or finishes the running session (MENU-AC-02: status shows "Dictation armed" while listening).
    public func toggleDictation() async { await services.dictation?.toggle() }

    public func stopLive() async { _ = await services.live.stop() }

    public func setAutoRecord(_ value: Bool) async {
        autoRecord = value
        await services.settings.set(value, for: SettingsKey.autoRecord)
    }

    public func setLanguage(_ choice: MenuLanguageChoice) async {
        language = choice
        await services.settings.set(choice.mode, for: SettingsKey.languageMode)
    }

    public func setInputDevice(_ uid: String?) async {
        inputDeviceUID = uid
        await services.settings.set(uid ?? "", for: SettingsKey.inputDeviceUID)
    }
}
