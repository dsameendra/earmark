/// `SettingsStore` keys shared by the shell, menu bar and Settings scene.
public enum SettingsKey {
    /// `String` raw value of the last selected sidebar section (NAV-AC-15).
    public static let lastSection = "ui.lastSection"
    /// `Bool`; Dock icon visible (default `true`, MENU-AC-08).
    public static let showDockIcon = "general.showDockIcon"
    /// `Bool`; keep running in the menu bar after the main window closes (NAV-AC-16).
    public static let keepRunning = "general.keepRunning"
    /// `Bool`; menu bar item visible (default `true`).
    public static let showMenuBarIcon = "general.showMenuBarIcon"
    /// `Bool`; launch at login (mirrors `SMAppService`, default `false`).
    public static let launchAtLogin = "general.launchAtLogin"
    /// `Bool`; notifications enabled (default `true`).
    public static let notificationsEnabled = "general.notificationsEnabled"
    /// `Bool`; notify when a file job finishes (default `true`).
    public static let notifyJobCompleted = "general.notifyJobCompleted"
    /// `LanguageMode`; default for the next session (MENU-AC-09).
    public static let languageMode = "defaults.languageMode"
    /// `String`; chosen ASR model id; empty or absent means "Auto" (ADR-008).
    public static let preferredModel = "defaults.preferredModel"
    /// `String`; chosen input device UID (absent means system default).
    public static let inputDeviceUID = "audio.inputDeviceUID"
    /// `String`; per-feature input device overrides (empty means "use global").
    public static let liveInputDeviceUID = "audio.live.inputDeviceUID"
    public static let meetingsInputDeviceUID = "audio.meetings.inputDeviceUID"
    public static let dictationInputDeviceUID = "audio.dictation.inputDeviceUID"
    /// `Bool`; voice processing (echo cancellation / noise suppression) on the microphone.
    public static let voiceProcessing = "audio.voiceProcessing"
    /// `Bool`; auto-record meetings.
    public static let autoRecord = "meetings.autoRecord"
    /// `MeetingPolicy` for one app, e.g. `meetings.policy.zoom`.
    public static func meetingPolicy(_ appRawValue: String) -> String { "meetings.policy.\(appRawValue)" }
    /// `Bool`; show the one-time recording consent notice (default `true`).
    public static let meetingConsentNotice = "meetings.consentNotice"
    /// `String`; folder for meeting recordings (empty means the library default).
    public static let meetingStorageLocation = "meetings.storageLocation"
    /// `String` (UUID) of the active live-caption preset.
    public static let activeCaptionPreset = "liveCaptions.activePreset"
    /// `Bool`; show the floating caption overlay while a live session runs (default `true`).
    public static let liveOverlayEnabled = "liveCaptions.overlayEnabled"
    /// `Bool`; "Save as transcript" default for live sessions (default `false`).
    public static let liveSaveAsTranscript = "liveCaptions.saveAsTranscript"
    /// `String` raw value of the last live source (`mic`, `system`, `micAndSystem`).
    public static let liveSource = "liveCaptions.source"
    /// Dictation: `HotkeyMode`, `TextInsertionMethod`, `Bool`s and `Int`.
    public static let dictationMode = "dictation.mode"
    public static let dictationInsertion = "dictation.insertionMethod"
    public static let dictationRemoveFillers = "dictation.removeFillers"
    public static let dictationAutoPunctuate = "dictation.autoPunctuate"
    public static let dictationTranslateBeforeInsert = "dictation.translateBeforeInsert"
    public static let dictationHistorySize = "dictation.historySize"
    /// Transcript appearance.
    public static let appearanceFontSize = "appearance.fontSize"
    public static let appearanceLineSpacing = "appearance.lineSpacing"
    public static let appearanceShowTimestamps = "appearance.showTimestamps"
    public static let appearanceShowLanguageBadges = "appearance.showLanguageBadges"
    public static let appearanceShowIgnored = "appearance.showIgnored"
    /// Ignored segments: `Bool` seeded flag, hallucination toggle and thresholds.
    public static let ignoreRulesSeeded = "ignore.seeded"
    public static let hallucinationFilterEnabled = "ignore.hallucinationFilter"
    public static let lowConfidenceThreshold = "ignore.lowConfidenceThreshold"
    public static let noSpeechThreshold = "ignore.noSpeechThreshold"
    /// `[String]` custom vocabulary fed to engines (FR-AC-13).
    public static let customVocabulary = "replacements.customVocabulary"
    /// `Bool`; apply replacement rules to new jobs by default.
    public static let applyReplacementsByDefault = "replacements.applyByDefault"
    /// Translation defaults.
    public static let translationTarget = "translation.targetLanguage"
    public static let translationEngine = "translation.engine"
    public static let translationAllowNonCommercial = "translation.allowNonCommercial"
    public static let translationParallelTrack = "translation.parallelTrack"
    /// `ExportOptions`; default export options.
    public static let exportDefaultOptions = "export.defaultOptions"
    /// `String`; library folder path (empty means the default location).
    public static let libraryLocation = "storage.libraryLocation"
    /// `Int`; Recently Deleted retention in days (default 30).
    public static let recentlyDeletedRetentionDays = "storage.recentlyDeletedRetentionDays"
    /// `KeyCombo`-valued shortcut, e.g. `shortcuts.dictation`.
    public static func shortcut(_ actionRawValue: String) -> String { "shortcuts.\(actionRawValue)" }
    /// `String` ("grid" or "list"); Library layout (LIB-AC-04).
    public static let libraryLayout = "library.layout"
    /// `Int`; days soft-deleted items are kept before auto-purge (LIB-AC-08). 0 means never.
    public static let libraryRetentionDays = recentlyDeletedRetentionDays  // one shared setting (Settings > Storage and Library)
    /// `[LibraryFolder]`; Library folder names (folders have no repository, only `Transcript.folderID`).
    public static let libraryFolders = "library.folders"
    /// `Int`; maximum parallel jobs (FILE-AC-07).
    public static let queueMaxConcurrency = "queue.maxConcurrency"
}
