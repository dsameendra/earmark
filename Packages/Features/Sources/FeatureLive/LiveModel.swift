import AppCore
import FeatureSupport
import Foundation
import Observation

/// Source choices offered for live captions (NAV-AC-13, MENU-AC-03).
public enum LiveSourceChoice: String, CaseIterable, Identifiable, Sendable {
    case mic, system, micAndSystem
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .mic: "Microphone"
        case .system: "System Audio"
        case .micAndSystem: "Mic + System"
        }
    }

    /// Symbol name for the picker (rule A3: symbols reach the view through the model).
    public var systemImage: String {
        switch self {
        case .mic: "mic"
        case .system: "speaker.wave.2"
        case .micAndSystem: "person.2.wave.2"
        }
    }

    /// The matching capture source (default device for the mic).
    public var captureSource: CaptureSource {
        switch self {
        case .mic: .mic(deviceUID: nil)
        case .system: .system
        case .micAndSystem: .micAndSystem(deviceUID: nil, lanes: true)
        }
    }

    /// The capture source using a specific input device (ignored for system audio).
    public func captureSource(deviceUID: String?) -> CaptureSource {
        switch self {
        case .mic: .mic(deviceUID: deviceUID)
        case .system: .system
        case .micAndSystem: .micAndSystem(deviceUID: deviceUID, lanes: true)
        }
    }

    /// Whether the choice involves an input device.
    public var usesMicrophone: Bool { self != .system }
}

/// Language modes offered on the Live screen; English is the default.
public enum LiveLanguageChoice: String, CaseIterable, Identifiable, Sendable {
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

/// Drives the Live screen from `LiveSessionControlling` plus the optional `LiveSessionExtras`.
@MainActor @Observable
public final class LiveModel {
    public private(set) var state: LiveSessionState = .idle
    public private(set) var lines: [CaptionLine] = []
    public var source: LiveSourceChoice = .mic { didSet { if source != oldValue { persist(SettingsKey.liveSource, source.rawValue) } } }
    public var language: LiveLanguageChoice = .english {
        didSet { if language != oldValue { persist(SettingsKey.languageMode, language.mode) } }
    }
    /// `nil` means the system default input.
    public var deviceUID: String? { didSet { if deviceUID != oldValue { persist(SettingsKey.liveInputDeviceUID, deviceUID ?? "") } } }
    public var saveAsTranscript = false {
        didSet { if saveAsTranscript != oldValue { persist(SettingsKey.liveSaveAsTranscript, saveAsTranscript) } }
    }
    public private(set) var overlayEnabled = true
    public private(set) var isPaused = false
    /// Smoothed 0...1 input level (0 when no session is running).
    public private(set) var level: Float = 0
    public private(set) var devices: [AudioDevice] = []
    public private(set) var notice: LiveNotice?
    public private(set) var savedTranscriptID: TranscriptID?
    public private(set) var presets: [CaptionPreset] = []
    public private(set) var preset: CaptionPreset = CaptionPreset(name: "Subtle")

    @ObservationIgnored private let live: any LiveSessionControlling
    @ObservationIgnored private let extras: (any LiveSessionExtras)?
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let audioDevices: any AudioDeviceProviding
    @ObservationIgnored private var isLoadingPreferences = false

    public init(services: AppServices) {
        live = services.live
        extras = services.liveExtras
        settings = services.settings
        audioDevices = services.audioDevices
    }

    public var isRunning: Bool { state == .running || state == .starting }
    public var hasExtras: Bool { extras != nil }

    /// Why Start is unavailable, or `nil` when it can start.
    public var startDisabledReason: String? {
        if source.usesMicrophone, devices.isEmpty, source == .mic { return "No input device available" }
        return nil
    }

    /// The preset editor is shown while captions can be styled (always, when the overlay is available).
    public var canEditPreset: Bool { extras != nil }

    // MARK: Following services

    /// Follows session state until cancelled.
    public func watchState() async {
        for await next in live.state() {
            state = next
            if !isRunning { level = 0; isPaused = false }
        }
    }

    /// Follows caption lines until cancelled. Volatile lines finalize in place (same id).
    public func watchLines() async {
        for await next in live.lines() { lines = next }
    }

    /// Follows the input level meter until cancelled.
    public func watchLevels() async {
        guard let extras else { return }
        for await next in extras.levels() {
            guard isRunning else { level = 0; continue }
            // Fast attack, slower release so the meter is readable.
            level = next > level ? next : level * 0.7 + next * 0.3
        }
    }

    /// Follows session notices (device fallback, silent capture, pause) until cancelled.
    public func watchNotices() async {
        guard let extras else { return }
        for await next in extras.notices() {
            switch next.kind {
            case .paused: isPaused = true
            case .resumed: isPaused = false
            default: break
            }
            notice = next
        }
    }

    /// Follows the input device list until cancelled.
    public func watchDevices() async {
        await reloadDevices()
        for await _ in audioDevices.changes() { await reloadDevices() }
    }

    private func reloadDevices() async {
        devices = await audioDevices.devices().filter(\.isInput)
        // A vanished device falls back to the system default (MENU-AC-10).
        if let uid = deviceUID, !devices.contains(where: { $0.id == uid }) { deviceUID = nil }
    }

    /// Loads saved preferences and presets. Call once when the screen appears.
    public func loadPreferences() async {
        isLoadingPreferences = true
        defer { isLoadingPreferences = false }
        if let raw = await settings.value(for: SettingsKey.liveSource, as: String.self), let value = LiveSourceChoice(rawValue: raw) {
            source = value
        }
        if let mode = await settings.value(for: SettingsKey.languageMode, as: LanguageMode.self) {
            language = LiveLanguageChoice(mode: mode)
        }
        let uid = await settings.value(for: SettingsKey.liveInputDeviceUID, as: String.self)
        let global = await settings.value(for: SettingsKey.inputDeviceUID, as: String.self)
        let chosen = (uid?.isEmpty ?? true) ? global : uid
        deviceUID = (chosen?.isEmpty ?? true) ? nil : chosen
        saveAsTranscript = await settings.value(for: SettingsKey.liveSaveAsTranscript, as: Bool.self) ?? false
        if let extras {
            overlayEnabled = await extras.isOverlayEnabled()
            presets = await extras.presets()
            preset = await extras.activePreset()
        }
    }

    private func persist<T: Codable & Sendable>(_ key: String, _ value: T) {
        guard !isLoadingPreferences else { return }
        let settings = settings
        Task { await settings.set(value, for: key) }
    }

    // MARK: Actions

    public func start() async {
        notice = nil
        savedTranscriptID = nil
        // Live translation (LIVE-AC-13): lines are translated into the default target when the preset shows translations.
        var target: LanguageCode?
        if preset.showTranslation || preset.translatedOnly,
            let raw = await settings.value(for: SettingsKey.translationTarget, as: String.self), !raw.isEmpty
        {
            target = LanguageCode(raw)
        }
        let config = LiveSessionConfig(
            source: source.captureSource(deviceUID: deviceUID), languageMode: language.mode, diarize: source != .mic,
            translateTo: target, saveAsTranscript: saveAsTranscript, presetID: preset.id)
        do {
            try await live.start(config)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    public func stop() async {
        let id = await live.stop()
        if saveAsTranscript { savedTranscriptID = id }
    }

    public func togglePause() async {
        guard let extras, isRunning else { return }
        let next = !isPaused
        isPaused = next
        await extras.setPaused(next)
    }

    public func setOverlayEnabled(_ enabled: Bool) async {
        overlayEnabled = enabled
        await extras?.setOverlayEnabled(enabled)
    }

    public func selectPreset(_ id: PresetID) async {
        guard let extras else { return }
        await extras.setActivePreset(id)
        preset = await extras.activePreset()
    }

    /// Applies a preset edit immediately (the overlay restyles live) and persists it.
    public func updatePreset(_ edited: CaptionPreset) {
        preset = edited
        guard let extras else { return }
        pendingCommit?.cancel()
        pendingCommit = Task { [weak self] in
            // Debounce slider drags.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let committed = await extras.commit(edited)
            guard let self, !Task.isCancelled else { return }
            if committed.id != edited.id { preset = committed }
            presets = await extras.presets()
        }
    }

    @ObservationIgnored private var pendingCommit: Task<Void, Never>?

    static func describe(_ error: any Error) -> String {
        if let app = error as? AppError { return String(describing: app) }
        return String(describing: error)
    }
}
