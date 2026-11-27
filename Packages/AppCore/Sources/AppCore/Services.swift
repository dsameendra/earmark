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
    /// The "Request access" action after an earlier answer: prompts when the OS has not been asked, raises the prompts that
    /// can reappear (Accessibility, Screen Recording) after a denial, and otherwise re-reads the state. Defaults to `request`.
    func requestAgain(_ kind: PermissionKind) async -> PermissionStatus
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

extension KeyCombo {
    /// Default dictation shortcut, Control-Option-D: needs no Fn/Globe configuration, produces no character in a text
    /// field and is not a system shortcut (unlike Option-Space, which types a non-breaking space).
    public static let defaultDictation = KeyCombo(keyCode: 2, modifiers: 0x40000 | 0x80000)
    /// The Fn / Globe key on its own (modifier-only, reported through `flagsChanged`).
    public static let functionKey = KeyCombo(keyCode: 63, modifiers: 0x800000)
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

/// How the global hotkey source can see (and consume) key events right now.
public enum HotkeyCapture: String, Sendable, Equatable {
    /// Active event tap: matched shortcut keys are swallowed so they never reach the focused app.
    case swallowing
    /// Listen-only: the shortcut works but the key press still reaches the focused app (Accessibility not granted).
    case listenOnly
    /// No event source could be started.
    case unavailable
}

/// What the Globe/Fn key does system-wide (System Settings > Keyboard > "Press Globe key to").
public enum GlobeKeyAction: Sendable, Equatable {
    case doNothing, changeInputSource, showEmojiAndSymbols, startDictation
    /// The preference is absent, so macOS uses its default (Show Emoji & Symbols on current Macs).
    case systemDefault

    /// Decodes `AppleFnUsageType` from `com.apple.HIToolbox` (0 Do Nothing, 1 Change Input Source, 2 Emoji, 3 Dictation).
    public init(appleFnUsageType: Int?) {
        switch appleFnUsageType {
        case 0: self = .doNothing
        case 1: self = .changeInputSource
        case 2: self = .showEmojiAndSymbols
        case 3: self = .startDictation
        default: self = .systemDefault
        }
    }

    /// True when macOS will also act on the Globe key, so Earmark cannot rely on it.
    public var competesWithEarmark: Bool { self != .doNothing }

    public var summary: String {
        switch self {
        case .doNothing: "Do Nothing"
        case .changeInputSource: "Change Input Source"
        case .showEmojiAndSymbols: "Show Emoji & Symbols"
        case .startDictation: "Start Dictation"
        case .systemDefault: "the macOS default (Show Emoji & Symbols)"
        }
    }
}

/// A snapshot of global hotkey health, surfaced in Settings > Shortcuts.
public struct HotkeyDiagnostics: Sendable, Equatable {
    public var capture: HotkeyCapture
    public var accessibilityTrusted: Bool
    public var inputMonitoringGranted: Bool
    public var globeKeyAction: GlobeKeyAction
    /// Actions whose registration failed, with a user-facing reason.
    public var failures: [HotkeyAction: String]

    public init(
        capture: HotkeyCapture, accessibilityTrusted: Bool, inputMonitoringGranted: Bool, globeKeyAction: GlobeKeyAction,
        failures: [HotkeyAction: String] = [:]
    ) {
        self.capture = capture
        self.accessibilityTrusted = accessibilityTrusted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.globeKeyAction = globeKeyAction
        self.failures = failures
    }
}

/// Reports (and re-checks) global hotkey health. Implemented by the hotkey service.
public protocol HotkeyDiagnosing: Sendable {
    /// Re-checks permissions, upgrades a listen-only source to a swallowing one when Accessibility was just granted,
    /// and returns the current state.
    func refreshDiagnostics() async -> HotkeyDiagnostics
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
    /// The transcript the running session is writing, or nil when none is running (SCR-021: the workspace opens next to it).
    func activeTranscriptID() async -> TranscriptID?
}

extension LiveSessionControlling {
    public func activeTranscriptID() async -> TranscriptID? { nil }
}

public protocol OverlayControlling: Sendable {
    func show(preset: CaptionPreset) async
    func hide() async
    func setClickThrough(_ enabled: Bool) async
}
