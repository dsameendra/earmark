import AppCore
import Foundation

/// Where the dictation HUD appears (DICT-AC-03).
public enum DictationHUDPosition: String, Codable, Sendable, CaseIterable {
    case nearCursor, bottomCenter
    /// Model-owned label so views never encode copy for enum cases.
    public var title: String {
        switch self {
        case .nearCursor: "Near the text cursor"
        case .bottomCenter: "Bottom centre of the screen"
        }
    }
}

/// User-configurable dictation settings, stored as one Codable value under ``DictationSettings/storageKey``.
public struct DictationSettings: Codable, Sendable, Equatable {
    public static let storageKey = "dictation.settings"

    public var mode: HotkeyMode = .pushToTalk
    public var combo: KeyCombo = .fn
    public var insertionMethod: TextInsertionMethod = .pasteboardPaste
    public var hudPosition: DictationHUDPosition = .nearCursor
    public var languageMode: LanguageMode = .default
    /// Explicit model override; `nil` is Auto (EngineRouter).
    public var modelID: ModelID?
    public var vocabulary: [String] = []
    public var translateBeforeInsert = false
    public var translationTarget: LanguageCode?
    /// Optional punctuation and capitalization cleanup (applied after ignore and replacement rules).
    public var autoPunctuation = false
    public var historyEnabled = true
    public var historyLimit = 200
    /// Per-feature input device override (Core Audio UID); `nil` follows the system default.
    public var deviceUID: String?

    public init() {}

    /// Loads from a ``SettingsStore``, falling back to defaults.
    public static func load(from store: any SettingsStore) async -> DictationSettings {
        await store.value(for: storageKey, as: DictationSettings.self) ?? DictationSettings()
    }

    public func save(to store: any SettingsStore) async { await store.set(self, for: Self.storageKey) }
}
