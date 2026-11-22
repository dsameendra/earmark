import AppCore
import Foundation

/// How the microphone preferences resolve, in one place, so Live, Meetings, Dictation, the menu bar and the Settings
/// "Test microphone" all agree.
///
/// - The global device (Settings > Audio > Microphone) applies to every feature that has no override.
/// - An empty UID means "System default": capture follows whatever macOS currently uses as its default input.
/// - A stored UID is never erased when its device disappears. While the device is unplugged capture falls back to the
///   system default (`effective`), and the original choice takes effect again when it returns.
public enum MicrophonePreference {
    public enum Feature: Sendable, CaseIterable {
        case live, meetings, dictation

        public var overrideKey: String {
            switch self {
            case .live: SettingsKey.liveInputDeviceUID
            case .meetings: SettingsKey.meetingsInputDeviceUID
            case .dictation: SettingsKey.dictationInputDeviceUID
            }
        }

        public var title: String {
            switch self {
            case .live: "Live captions"
            case .meetings: "Meetings"
            case .dictation: "Dictation"
            }
        }
    }

    /// Override first, then the global choice; `nil` means the system default.
    public static func resolve(override: String?, global: String?) -> String? {
        for candidate in [override, global] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    public static func deviceUID(for feature: Feature, store: any SettingsStore) async -> String? {
        let override = await store.value(for: feature.overrideKey, as: String.self)
        let global = await store.value(for: SettingsKey.inputDeviceUID, as: String.self)
        return resolve(override: override, global: global)
    }

    public static func voiceProcessing(store: any SettingsStore) async -> Bool {
        await store.value(for: SettingsKey.voiceProcessing, as: Bool.self) ?? false
    }

    /// The device capture will really use: the chosen one while it is connected, otherwise the system default (`nil`).
    public static func effective(_ uid: String?, connected: [AudioDevice]) -> (uid: String?, fellBack: Bool) {
        guard let uid, !uid.isEmpty else { return (nil, false) }
        return connected.contains { $0.id == uid && $0.isInput } ? (uid, false) : (nil, true)
    }
}
