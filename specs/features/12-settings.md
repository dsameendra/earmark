# 12 — Settings (SET)
Status: Draft. Owners: UI engineers; Models UI with Models engineer. Separate Settings scene.

## Sections
General · Models · Languages · Audio · Meetings · Live Captions · Dictation · Transcript Appearance · Ignored Segments · Replacements · Translation · Export defaults · Storage · Keyboard Shortcuts · Privacy & Permissions.

## AppCore protocols used
`SettingsStore`, `ModelManaging`, `LanguageCapabilityTable`, `HardwareTierProviding`, `AudioDeviceProviding`, `PermissionsServicing`, `HotkeyServicing`, `RuleRepository`, `PresetRepository`, `MeetingPolicy`, `TranscriptRepository` (retention).

## Acceptance criteria (EARS)
- SET-AC-01 (UI) THE SYSTEM SHALL present all listed sections in a Settings window and persist changes immediately via `SettingsStore`.
- SET-AC-02 (UI) General: THE SYSTEM SHALL provide launch at login, Dock/menu-bar visibility, default language mode (default English), notifications.
- SET-AC-03 (UI) Models: THE SYSTEM SHALL list catalog models with size, languages, speed/accuracy notes, licence (flagging CC-BY-NC / CC BY-SA) and state (not installed / downloading / paused / installed / failed).
- SET-AC-04 (UI/integration) WHEN the user downloads a model THE SYSTEM SHALL show progress, support pause/resume/cancel, verify the checksum, and show "verifying" then installed.
- SET-AC-05 (UI) THE SYSTEM SHALL let the user delete models, show disk usage per model and total, and import a custom WhisperKit CoreML folder as a custom model with chosen languages.
- SET-AC-06 (UI) WHEN a language is chosen THE SYSTEM SHALL filter the model picker via `LanguageCapabilityTable.models(coveringAll:)`; WHEN a model is chosen THE SYSTEM SHALL restrict languages to `languages(forModel:)` (ADR-008).
- SET-AC-07 (UI) WHEN the user selects a model that is not installed THE SYSTEM SHALL download it with visible progress and then apply the selection.
- SET-AC-08 (UI) Languages: THE SYSTEM SHALL offer single / auto-detect / multilingual set; English is preselected; Sinhala is marked experimental.
- SET-AC-09 (UI) Audio: THE SYSTEM SHALL provide global input device with per-feature overrides (Live, Meetings, Dictation), live level meters, and a voice-processing toggle.
- SET-AC-10 (UI) Meetings: per app (Zoom, Teams) THE SYSTEM SHALL offer Do nothing / Ask first / Auto-transcribe / Auto-transcribe + record, with **Ask first as default**; plus auto-stop grace period, quiet hours, exclusions, storage location, optional video, and a one-time consent notice setting.
- SET-AC-11 (UI) Live Captions: THE SYSTEM SHALL edit appearance options and manage built-in/user presets (Subtle, Presentation, High contrast).
- SET-AC-12 (UI) Dictation: THE SYSTEM SHALL configure hotkey (push-to-talk/toggle), insertion method, cleanup options, translate-before-insert and history size.
- SET-AC-13 (UI) Ignored Segments: THE SYSTEM SHALL provide a table (Segment column, remove, add, search, Restore defaults, JSON import/export) with match mode and scope per rule, shipping the default list and a separate off-by-default hallucination list.
- SET-AC-14 (UI) Replacements: THE SYSTEM SHALL manage find→replace rules (case, whole word, regex), toggleable per job.
- SET-AC-15 (UI) Translation/Export/Storage: THE SYSTEM SHALL configure translation defaults and models, export presets, library location, Recently Deleted retention (default 30 days), cache clearing.
- SET-AC-16 (UI) Keyboard Shortcuts: THE SYSTEM SHALL let users record, change and clear global and in-app shortcuts and SHALL warn on conflicts.
- SET-AC-17 (UI) Privacy & Permissions: THE SYSTEM SHALL show status for Microphone, System Audio Recording, Screen Recording, Accessibility and Notifications with a deep link to System Settings for each.
- SET-AC-18 (unit) THE SYSTEM SHALL validate imported JSON rule files and reject malformed input without changing existing rules.
- SET-AC-19 (integration) THE SYSTEM SHALL make no network request except user-initiated model downloads (PROD-AC-01).

## Edge cases
Download failure with Retry; checksum mismatch deletes partial and reports; low disk space warning before download; model in use cannot be deleted without confirmation; non-commercial licence notice shown before download.

## Non-functional
Settings open < 200 ms; downloads resumable across relaunch.
