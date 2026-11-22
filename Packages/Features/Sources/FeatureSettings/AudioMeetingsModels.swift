import AppCore
import FeatureSupport
import Foundation
import Observation

/// Audio: global input device with per-feature overrides, voice processing (SET-AC-09).
@MainActor @Observable
public final class AudioSettingsModel {
    public private(set) var inputs: [AudioDevice] = []
    public private(set) var systemDefaultName: String?
    /// Empty string means "System Default" (global) or "Use global" (overrides).
    public let globalDevice: Pref<String>
    public let liveDevice: Pref<String>
    public let meetingsDevice: Pref<String>
    public let dictationDevice: Pref<String>
    public let voiceProcessing: Pref<Bool>
    public private(set) var inputLevel: Float = 0
    public private(set) var isTestingMicrophone = false
    public private(set) var meterError: String?
    public let microphoneSettingsURL: URL?
    public var canTestMicrophone: Bool { microphonePreview != nil }

    @ObservationIgnored private let provider: any AudioDeviceProviding
    @ObservationIgnored private let microphonePreview: (@Sendable (String?) -> any AudioSource)?
    @ObservationIgnored private let sourceErrors: (@Sendable (any AudioSource) -> AsyncStream<AppError>)?
    @ObservationIgnored private var meterSource: (any AudioSource)?
    @ObservationIgnored private var meterTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var meterGeneration = 0

    public init(
        provider: any AudioDeviceProviding, store: any SettingsStore, microphonePreview: (@Sendable (String?) -> any AudioSource)? = nil,
        microphoneSettingsURL: URL? = nil, sourceErrors: (@Sendable (any AudioSource) -> AsyncStream<AppError>)? = nil
    ) {
        self.provider = provider
        self.microphonePreview = microphonePreview
        self.microphoneSettingsURL = microphoneSettingsURL
        self.sourceErrors = sourceErrors
        globalDevice = Pref(SettingsKey.inputDeviceUID, default: "", store: store)
        liveDevice = Pref(SettingsKey.liveInputDeviceUID, default: "", store: store)
        meetingsDevice = Pref(SettingsKey.meetingsInputDeviceUID, default: "", store: store)
        dictationDevice = Pref(SettingsKey.dictationInputDeviceUID, default: "", store: store)
        voiceProcessing = Pref(SettingsKey.voiceProcessing, default: false, store: store)
    }

    public func load() async {
        await globalDevice.load()
        await liveDevice.load()
        await meetingsDevice.load()
        await dictationDevice.load()
        await voiceProcessing.load()
        await refreshDevices()
    }

    /// Follows device hot-plug until cancelled.
    public func observe() async {
        for await _ in provider.changes() { await refreshDevices() }
    }

    private func refreshDevices() async {
        inputs = await provider.devices().filter(\.isInput)
        systemDefaultName = await provider.defaultInput()?.name
    }

    /// Effective device UID for a feature override (`nil` means the system default).
    public func effectiveDevice(override: Pref<String>) -> String? {
        let chosen = override.value.isEmpty ? globalDevice.value : override.value
        return chosen.isEmpty ? nil : chosen
    }

    /// True when a stored UID no longer matches any connected input (device unplugged).
    public func isMissing(_ uid: String) -> Bool { !uid.isEmpty && !inputs.contains { $0.id == uid } }

    /// Starts an explicit microphone test. Closing the pane or pressing Stop releases capture.
    public func startMicrophoneTest() async {
        guard !isTestingMicrophone, let microphonePreview else { return }
        meterGeneration += 1
        let generation = meterGeneration
        isTestingMicrophone = true
        meterError = nil
        let source = microphonePreview(globalDevice.value.isEmpty ? nil : globalDevice.value)
        meterSource = source
        let levels = source.levels
        let health = source.health
        let errors = sourceErrors?(source)
        do {
            let chunks = try await source.start()
            guard generation == meterGeneration else {
                await source.stop()
                return
            }
            observeMeter(chunks: chunks, levels: levels, health: health, errors: errors, generation: generation)
        } catch {
            await source.stop()
            guard generation == meterGeneration else { return }
            meterSource = nil
            isTestingMicrophone = false
            meterError = "Microphone test could not start. Check microphone access in System Settings. \(error.localizedDescription)"
        }
    }

    private func observeMeter(
        chunks: AsyncStream<AudioChunk>, levels: AsyncStream<Float>, health: AsyncStream<AudioSourceHealth>,
        errors: AsyncStream<AppError>?, generation: Int
    ) {
        meterTasks = [
            Task { [weak self] in
                for await _ in chunks { guard !Task.isCancelled else { return } }
                guard !Task.isCancelled else { return }
                await self?.finishMicrophoneTest(
                    generation: generation, message: "The microphone test stopped. Check the input device.")
            },
            Task { [weak self] in
                for await level in levels {
                    guard !Task.isCancelled else { return }
                    self?.inputLevel = min(1, max(0, level))
                }
                guard !Task.isCancelled else { return }
                await self?.finishMicrophoneTest(generation: generation, message: "The microphone stopped providing input levels.")
            },
            Task { [weak self] in
                for await status in health {
                    guard !Task.isCancelled else { return }
                    switch status {
                    case .silent:
                        await self?.finishMicrophoneTest(
                            generation: generation, message: "No audio was received. Check microphone access and the selected input.")
                        return
                    case .stopped:
                        await self?.finishMicrophoneTest(generation: generation, message: "The microphone test stopped.")
                        return
                    case .running, .deviceChanged: break
                    }
                }
            },
        ]
        if let errors {
            meterTasks.append(
                Task { [weak self] in
                    for await error in errors {
                        guard !Task.isCancelled else { return }
                        await self?.finishMicrophoneTest(generation: generation, message: "The microphone test stopped: \(error)")
                        return
                    }
                })
        }
    }

    isolated deinit {
        for task in meterTasks { task.cancel() }
    }

    public func stopMicrophoneTest() async {
        meterGeneration += 1
        for task in meterTasks { task.cancel() }
        meterTasks = []
        let source = meterSource
        meterSource = nil
        isTestingMicrophone = false
        inputLevel = 0
        await source?.stop()
    }

    private func finishMicrophoneTest(generation: Int, message: String) async {
        guard generation == meterGeneration else { return }
        meterError = message
        await stopMicrophoneTest()
    }
}

/// Meetings: per-app behavior (default Ask first), grace period, quiet hours, exclusions, consent notice (SET-AC-10).
@MainActor @Observable
public final class MeetingsSettingsModel {
    public private(set) var policies: [MeetingApp: MeetingPolicy] = [:]
    public let consentNotice: Pref<Bool>
    public let storageLocation: Pref<String>

    @ObservationIgnored private let store: any SettingsStore

    public init(store: any SettingsStore) {
        self.store = store
        consentNotice = Pref(SettingsKey.meetingConsentNotice, default: true, store: store)
        storageLocation = Pref(SettingsKey.meetingStorageLocation, default: "", store: store)
        for app in MeetingApp.allCases { policies[app] = MeetingPolicy(app: app) }
    }

    public func load() async {
        for app in MeetingApp.allCases {
            policies[app] =
                await store.value(for: SettingsKey.meetingPolicy(app.rawValue), as: MeetingPolicy.self) ?? MeetingPolicy(app: app)
        }
        await consentNotice.load()
        await storageLocation.load()
    }

    public func policy(for app: MeetingApp) -> MeetingPolicy { policies[app] ?? MeetingPolicy(app: app) }

    public func update(_ app: MeetingApp, _ change: (inout MeetingPolicy) -> Void) async {
        var policy = policy(for: app)
        change(&policy)
        policy.autoStopGraceSeconds = min(max(policy.autoStopGraceSeconds, 0), 300)
        policies[app] = policy
        await store.set(policy, for: SettingsKey.meetingPolicy(app.rawValue))
    }

    public func setBehavior(_ behavior: MeetingBehavior, for app: MeetingApp) async {
        await update(app) { $0.behavior = behavior }
    }

    public func setQuietHours(_ range: ClosedRange<Int>?, for app: MeetingApp) async {
        await update(app) { $0.quietHours = range.map { max(0, $0.lowerBound)...min(24, $0.upperBound) } }
    }

    /// Adds a keyword (case-insensitive de-duplicated) to the exclusion list.
    public func addExclusion(_ keyword: String, for app: MeetingApp) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await update(app) { policy in
            if !policy.excludedKeywords.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                policy.excludedKeywords.append(trimmed)
            }
        }
    }

    public func removeExclusion(_ keyword: String, for app: MeetingApp) async {
        await update(app) { $0.excludedKeywords.removeAll { $0 == keyword } }
    }
}
