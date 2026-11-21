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

    @ObservationIgnored private let provider: any AudioDeviceProviding

    public init(provider: any AudioDeviceProviding, store: any SettingsStore) {
        self.provider = provider
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

extension MeetingBehavior {
    public var title: String {
        switch self {
        case .doNothing: "Do nothing"
        case .askFirst: "Ask first"
        case .autoTranscribe: "Auto-transcribe"
        case .autoTranscribeAndRecord: "Auto-transcribe + record"
        }
    }
}

extension MeetingApp {
    public var title: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        }
    }
}
