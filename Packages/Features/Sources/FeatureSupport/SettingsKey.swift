import AppCore

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
    /// LEGACY single shared model key. Read only by the one-time migration and as the `.file` fallback (see
    /// ``PreferredModel/migrateLegacy(settings:)``); new code uses ``preferredModelKey(for:)``.
    public static let preferredModel = "defaults.preferredModel"
    /// `String`; chosen ASR model id for file transcription; empty or absent means "Auto" (ADR-008).
    public static let preferredModelFile = "defaults.preferredModel.file"
    /// `String`; chosen ASR model id for live captions (own key so a file-only model never reaches streaming).
    public static let preferredModelLive = "defaults.preferredModel.live"
    /// `String`; chosen ASR model id for dictation.
    public static let preferredModelDictation = "defaults.preferredModel.dictation"
    /// The preferred-model key for one use case.
    public static func preferredModelKey(for useCase: UseCase) -> String {
        switch useCase {
        case .file: preferredModelFile
        case .live: preferredModelLive
        case .dictation: preferredModelDictation
        }
    }
    /// `Bool`; show the Transcribe sheet before adding files (default `true`, SCR-013).
    public static let askBeforeAdding = "files.askBeforeAdding"
    /// `Bool`; "Identify speakers" as last chosen when adding files.
    public static let filesDiarize = "files.diarize"
    /// `String`; a `VoiceProcessingLevel` raw value: the voice-processing choice last made when adding files, which is also the
    /// "Voice processing default" in Settings (absent or unknown is off, SCR-014).
    public static let filesVoiceProcessing = "files.voiceProcessing"
    /// `Int`; expected speaker count as last chosen (0 or absent is automatic).
    public static let filesSpeakerCount = "files.speakerCount"
    /// `String`; model last picked in the add sheet (empty is Automatic). File-scoped: live captions never read it.
    public static let filesLastModel = "files.lastModel"
    /// `[String]`; recently used languages for files, most recent first (at most 5).
    public static let filesRecentLanguages = "files.recentLanguages"
    /// `String`; chosen input device UID (absent means system default).
    public static let inputDeviceUID = "audio.inputDeviceUID"
    /// `String`; per-feature input device overrides (empty means "use global").
    public static let liveInputDeviceUID = "audio.live.inputDeviceUID"
    public static let meetingsInputDeviceUID = "audio.meetings.inputDeviceUID"
    public static let dictationInputDeviceUID = "audio.dictation.inputDeviceUID"
    /// `[String: String]`; last known name per input device UID, so a disconnected choice is still shown by name.
    public static let knownInputDeviceNames = "audio.knownInputDeviceNames"
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
    /// `Bool`; caption overlay ignores the mouse (click-through, default `true`).
    public static let liveClickThrough = "liveCaptions.clickThrough"
    /// `String` (`main`, `follow` or `display:<id>`); which display the caption overlay appears on (default `main`).
    public static let liveOverlayDisplayChoice = "liveCaptions.overlayDisplayChoice"
    /// `String` raw `OverlayPosition` for "Main display" and "Follow the active window" (default `bottomCenter`).
    public static let liveOverlayPosition = "liveCaptions.overlayPosition"
    /// `String` raw `OverlayPosition` for one specific display.
    public static func liveOverlayPosition(display id: UInt32) -> String { "liveCaptions.overlayPosition.\(id)" }
    /// `StoredOverlayFrame`; dragged (Custom) frame for one display and caption preset, relative to the display origin.
    public static func liveOverlayCustomFrame(display id: UInt32, preset presetID: String) -> String {
        "liveCaptions.overlayCustomFrame.\(id).\(presetID)"
    }
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
    /// `String` (`LibrarySort` raw value); the Library's sort order, restored on launch.
    public static let librarySort = "library.sort"
    /// `Int`; days soft-deleted items are kept before auto-purge (LIB-AC-08). 0 means never.
    public static let libraryRetentionDays = recentlyDeletedRetentionDays  // one shared setting (Settings > Storage and Library)
    /// `[LibraryFolder]`; Library folder names (folders have no repository, only `Transcript.folderID`).
    public static let libraryFolders = "library.folders"
    /// `Bool`; first-run onboarding was completed or skipped (ONB-AC-01). Setting it to `false` shows the welcome flow again.
    public static let onboardingCompleted = "onboarding.completed"
    /// `Int`; raw index of the onboarding step to resume at (absent means the first step).
    public static let onboardingStep = "onboarding.step"
    /// `Int`; maximum parallel jobs (FILE-AC-07).
    public static let queueMaxConcurrency = "queue.maxConcurrency"
    /// `ReconciliationReport` for one transcript (live to offline speaker relabel, shown once).
    public static func speakerReconciliation(_ transcriptID: String) -> String { "speakers.reconciliation.\(transcriptID)" }
}
