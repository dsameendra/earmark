import AppCore
import DesignSystem
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
    public var symbol: DSSymbol {
        switch self {
        case .mic: .dictation
        case .system: .systemAudio
        case .micAndSystem: .meetings
        }
    }

    /// Stock fallback name of `symbol`.
    public var systemImage: String { symbol.systemImageName }

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

    /// The permissions this source needs.
    public var requiredPermissions: [PermissionKind] {
        switch self {
        case .mic: [.microphone]
        case .system: [.systemAudioRecording]
        case .micAndSystem: [.microphone, .systemAudioRecording]
        }
    }
}

/// Shared catalog-driven language choice, also used by the menu-bar controls.
public typealias LiveLanguageChoice = TranscriptionLanguageChoice

/// Drives the Live screen from `LiveSessionControlling` plus the optional `LiveSessionExtras`.
@MainActor @Observable
public final class LiveModel {
    public private(set) var state: LiveSessionState = .idle
    public private(set) var lines: [CaptionLine] = []
    public private(set) var languageChoices: [LiveLanguageChoice] = [.auto, .english]
    public var source: LiveSourceChoice = .mic { didSet { if source != oldValue { persist(SettingsKey.liveSource, source.rawValue) } } }
    public var language: LiveLanguageChoice = .english {
        didSet { if language != oldValue { persistLanguage() } }
    }
    /// `nil` means the system default input.
    public var deviceUID: String? { didSet { if deviceUID != oldValue { persist(SettingsKey.liveInputDeviceUID, deviceUID ?? "") } } }
    public var saveAsTranscript = false {
        didSet { if saveAsTranscript != oldValue { persist(SettingsKey.liveSaveAsTranscript, saveAsTranscript) } }
    }
    public var translationEnabled = false { didSet { saveTranslationPreferences() } }
    public var translationTarget = "" { didSet { saveTranslationPreferences() } }
    public var translationEngine = "auto" { didSet { saveTranslationPreferences() } }
    public private(set) var translationLanguages: [LanguageCode] = []
    public private(set) var translationPreparation: TranslationReadiness?
    @ObservationIgnored private let translation: (any TranslationPreparing)?
    @ObservationIgnored private var translationSaveTask: Task<Void, Never>?

    public private(set) var overlayEnabled = true
    public private(set) var isPaused = false
    /// Smoothed 0...1 input level (0 when no session is running).
    public private(set) var level: Float = 0
    public private(set) var devices: [AudioDevice] = []
    /// Inputs that are really connected, `nil` until the first device read.
    @ObservationIgnored private var connectedDevices: [AudioDevice]?
    public private(set) var notice: LiveNotice?
    public private(set) var savedTranscriptID: TranscriptID?
    public private(set) var presets: [CaptionPreset] = []
    public private(set) var preset: CaptionPreset = CaptionPreset(name: "Subtle")

    /// Microphone and System Audio Recording; the banner shows only what the chosen source needs.
    @ObservationIgnored public let permissionGate: PermissionGateModel
    @ObservationIgnored private let live: any LiveSessionControlling
    @ObservationIgnored private let extras: (any LiveSessionExtras)?
    @ObservationIgnored private let models: any ModelManaging
    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let audioDevices: any AudioDeviceProviding
    @ObservationIgnored private var isLoadingPreferences = false
    @ObservationIgnored private var languageSaveTask: Task<Void, Never>?

    public init(services: AppServices) {
        translation = services.translation
        live = services.live
        extras = services.liveExtras
        settings = services.settings
        models = services.models
        audioDevices = services.audioDevices
        permissionGate = PermissionGateModel(kinds: [.microphone, .systemAudioRecording], service: services.permissions)
    }

    public var isRunning: Bool { state == .running || state == .starting }
    public var hasExtras: Bool { extras != nil }

    /// Why Start is unavailable, or `nil` when it can start.
    public var startDisabledReason: String? {
        // `devices` also lists a saved-but-unplugged microphone, so ask the connected list (nil until the first read).
        if source.usesMicrophone, let connected = connectedDevices, connected.isEmpty { return "No input device available" }
        if source.usesMicrophone, connectedDevices == nil, devices.isEmpty { return "No input device available" }
        return nil
    }

    /// The preset editor is shown while captions can be styled (always, when the overlay is available).
    public var canEditPreset: Bool { extras != nil }

    // MARK: Following services

    /// Follows session state until cancelled.
    public func watchState() async {
        for await next in live.state() {
            state = next
            if !isRunning {
                level = 0
                isPaused = false
            }
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
            guard isRunning else {
                level = 0
                continue
            }
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
        let connected = await audioDevices.devices().filter(\.isInput)
        connectedDevices = connected
        devices = connected
        // A vanished device falls back to the system default for capture (MENU-AC-10) but the saved choice is kept, shown
        // as a disconnected entry, so it applies again when the device returns.
        if let uid = deviceUID, !connected.contains(where: { $0.id == uid }) {
            devices.append(AudioDevice(id: uid, name: "Disconnected device (using system default)", isInput: true, isOutput: false))
        }
    }

    /// The device capture will use: the chosen one while connected, else `nil` (the system default).
    var effectiveDeviceUID: String? { connectedDevices.map { MicrophonePreference.effective(deviceUID, connected: $0).uid } ?? deviceUID }

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
        await reloadLanguageChoices()
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
        let preferences = await LiveTranslationPreferences.load(settings: settings, legacyPreset: preset)
        translationEnabled = preferences.isEnabled
        translationTarget = preferences.target?.rawValue ?? ""
        translationEngine = preferences.engine
        let catalog = await models.catalog()
        var languages = Set(catalog.filter { $0.kind == .translation && $0.isRunnable }.flatMap(\.languages))
        if let target = preferences.target { languages.insert(target) }
        translationLanguages = languages.sorted { LiveLanguageChoice.name($0) < LiveLanguageChoice.name($1) }
    }

    /// Follows model availability and shared language preference changes while Live is open.
    public func watchLanguageChoices() async {
        let modelChanges = models.stateChanges()
        let languageChanges = settings.changes(for: SettingsKey.languageMode)
        let modelWatcher = Task { [weak self] in
            for await _ in modelChanges { await self?.reloadLanguageChoices() }
        }
        defer { modelWatcher.cancel() }
        for await _ in languageChanges {
            guard !Task.isCancelled else { return }
            let saved = await settings.value(for: SettingsKey.languageMode, as: LanguageMode.self)
            if !isRunning, let mode = saved {
                let wasLoading = isLoadingPreferences
                isLoadingPreferences = true
                language = LiveLanguageChoice(mode: mode)
                isLoadingPreferences = wasLoading
            }
            await reloadLanguageChoices()
        }
    }

    private func reloadLanguageChoices() async {
        languageChoices = LiveLanguageChoice.options(catalog: await models.catalog(), including: language.mode)
    }

    private func persistLanguage() {
        guard !isLoadingPreferences else { return }
        languageSaveTask?.cancel()
        let choice = language
        let models = models
        let settings = settings
        languageSaveTask = Task {
            let catalog = await models.catalog()
            guard !Task.isCancelled else { return }
            await choice.persist(to: settings, catalog: catalog)
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
        await translationSaveTask?.value
        let preferences = await LiveTranslationPreferences.load(settings: settings, legacyPreset: preset)
        let readiness = await preferences.readiness(languageMode: language.mode, using: translation)
        translationPreparation = readiness
        if let message = await LiveTranslationPreferences.setupMessage(readiness, models: models) {
            state = .failed(message)
            return
        }
        let target = preferences.isEnabled ? preferences.target : nil
        let config = LiveSessionConfig(
            source: source.captureSource(deviceUID: effectiveDeviceUID), languageMode: language.mode, diarize: source != .mic,
            translateTo: target, saveAsTranscript: saveAsTranscript, presetID: preset.id)
        do {
            try await live.start(config)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    /// Installs only the explicitly requested Apple translation pair through the system sheet.
    public func prepareTranslation() async {
        guard let translation, case .needsApplePack(let source, let target) = translationPreparation else { return }
        if await translation.prepareApplePack(source: source, target: target) {
            translationPreparation = await translation.readiness(source: source, target: target)
        }
    }

    private func saveTranslationPreferences() {
        guard !isLoadingPreferences else { return }
        translationPreparation = nil
        let prior = translationSaveTask
        let settings = settings
        let enabled = translationEnabled
        let target = translationTarget
        let engine = translationEngine
        translationSaveTask = Task {
            await prior?.value
            await settings.set(enabled, for: SettingsKey.liveTranslationEnabled)
            await settings.set(target, for: SettingsKey.translationTarget)
            await settings.set(engine, for: SettingsKey.translationEngine)
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
