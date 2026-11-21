import Foundation

// MARK: - Permissions

public enum PermissionKind: String, Codable, Sendable, CaseIterable {
    case microphone, systemAudioRecording, screenRecording, accessibility, notifications
}
public enum PermissionStatus: String, Codable, Sendable { case notDetermined, granted, denied, restricted }

/// Status, just-in-time request and System Settings deep links (Privacy & Permissions, onboarding).
public protocol PermissionsServicing: Sendable {
    func status(_ kind: PermissionKind) async -> PermissionStatus
    /// Requests where the OS allows; otherwise returns the current status. Called only when a feature first needs it.
    func request(_ kind: PermissionKind) async -> PermissionStatus
    func settingsURL(for kind: PermissionKind) -> URL
    func changes() -> AsyncStream<(PermissionKind, PermissionStatus)>
}

// MARK: - Hotkeys and text insertion (Dictation)

public struct KeyCombo: Hashable, Codable, Sendable {
    public var keyCode: UInt16
    /// Raw `NSEvent.ModifierFlags`-style bitmask (kept as Int so AppCore stays AppKit-free).
    public var modifiers: Int
    public init(keyCode: UInt16, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum HotkeyMode: String, Codable, Sendable { case pushToTalk, toggle }
public enum HotkeyEvent: Sendable, Equatable { case pressed, released }

public enum HotkeyAction: String, Codable, Sendable, CaseIterable {
    case dictation, toggleLiveCaptions, toggleMeetingCapture, bookmarkMoment, toggleOverlayClickThrough
}

public protocol HotkeyServicing: Sendable {
    func register(_ action: HotkeyAction, combo: KeyCombo) async throws -> AsyncStream<HotkeyEvent>
    func unregister(_ action: HotkeyAction) async
}

public enum TextInsertionMethod: String, Codable, Sendable { case pasteboardPaste, accessibility }

public protocol TextInserting: Sendable {
    /// Inserts text into the focused app. Pasteboard method preserves and restores the user's pasteboard.
    func insert(_ text: String, method: TextInsertionMethod) async throws
}

// MARK: - Live captions & sessions

public enum CaptureSource: Hashable, Codable, Sendable {
    case mic(deviceUID: String?)
    case system
    case app(bundleID: String)
    /// Mic + system, shown as labelled lanes ("You" / "Them") or mixed.
    case micAndSystem(deviceUID: String?, lanes: Bool)
}

public struct LiveSessionConfig: Sendable {
    public var source: CaptureSource
    public var languageMode: LanguageMode
    public var diarize: Bool
    public var translateTo: LanguageCode?
    public var saveAsTranscript: Bool
    public var presetID: PresetID?
    public init(
        source: CaptureSource, languageMode: LanguageMode = .default, diarize: Bool = false,
        translateTo: LanguageCode? = nil, saveAsTranscript: Bool = false, presetID: PresetID? = nil
    ) {
        self.source = source
        self.languageMode = languageMode
        self.diarize = diarize
        self.translateTo = translateTo
        self.saveAsTranscript = saveAsTranscript
        self.presetID = presetID
    }
}

/// A line shown in the overlay / live view.
public struct CaptionLine: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var translation: String?
    public var speakerLabel: String?
    public var speakerSlot: Int?
    public var language: LanguageCode?
    public var isVolatile: Bool
    public init(
        id: UUID = UUID(), text: String, translation: String? = nil, speakerLabel: String? = nil,
        speakerSlot: Int? = nil, language: LanguageCode? = nil, isVolatile: Bool
    ) {
        self.id = id
        self.text = text
        self.translation = translation
        self.speakerLabel = speakerLabel
        self.speakerSlot = speakerSlot
        self.language = language
        self.isVolatile = isVolatile
    }
}

public enum LiveSessionState: Sendable, Equatable {
    case idle, starting, running, stopping
    case failed(String)
}

/// Orchestrates capture → engine → diarization → post-processing → overlay/view for live captions and meetings.
public protocol LiveSessionControlling: Sendable {
    func start(_ config: LiveSessionConfig) async throws
    func stop() async -> TranscriptID?
    func state() -> AsyncStream<LiveSessionState>
    /// Caption lines; volatile lines finalize in place (same `id`) without jitter.
    func lines() -> AsyncStream<[CaptionLine]>
}

public protocol OverlayControlling: Sendable {
    func show(preset: CaptionPreset) async
    func hide() async
    func setClickThrough(_ enabled: Bool) async
}
