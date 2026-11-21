# 16 — Dictation (DICT)
Status: DRAFT (Phase 4) · Owner: Overlay & Dictation engineer · Package: `Dictation`

## Scope
Global hotkey (push-to-talk or toggle), glass HUD with partial text and input level, insertion into the focused app, replacement/ignore processing, optional punctuation cleanup and translate-before-insert, searchable local history, Accessibility onboarding.

## AppCore contracts used
`HotkeyServicing`, `HotkeyAction.dictation`, `HotkeyMode`, `KeyCombo`, `TextInserting`, `TextInsertionMethod`, `PermissionsServicing`, `TranscriptionEngine.stream`, `EngineRouter` (`UseCase.dictation`), `AudioSource`, `AudioDeviceProviding`, `TranscriptPostProcessor`, `PostProcessingContext`, `TranslationRouter`, `DictationHistoryRepository`, `DictationEntry`, `SettingsStore`.

## Acceptance criteria (EARS)
- DICT-AC-01 (U) WHEN mode is push-to-talk and the hotkey is pressed THE SYSTEM SHALL begin capture and, on release, finalize and insert; WHEN mode is toggle the first press SHALL start and the second SHALL stop.
- DICT-AC-02 (UI) WHEN the user records a new hotkey THE SYSTEM SHALL reject combos that conflict with another Earmark action and warn on common system shortcuts.
- DICT-AC-03 (UI/M) WHEN dictation is active THE SYSTEM SHALL show a glass HUD (non-activating panel) near the text cursor or bottom-centre (configurable) with live partial text and an input level meter; the HUD SHALL NOT take focus.
- DICT-AC-04 (I/M) WHEN dictation finishes THE SYSTEM SHALL insert via pasteboard method: save pasteboard contents → set text → synthesize ⌘V → restore the previous pasteboard within 500 ms, preserving all item types.
- DICT-AC-05 (I/M) WHERE the AX method is selected and the focused element supports it THE SYSTEM SHALL insert via Accessibility; IF unsupported THEN it SHALL fall back to the pasteboard method.
- DICT-AC-06 (UI) WHEN Accessibility is not granted at first use THE SYSTEM SHALL show an explanatory onboarding sheet with a deep link to System Settings, SHALL detect the grant without restart, and SHALL NOT insert text silently.
- DICT-AC-07 (U) WHEN text is finalized THE SYSTEM SHALL apply ignore rules then replacement rules (then optional auto-punctuation/capitalization) before insertion; text that becomes empty SHALL NOT be inserted.
- DICT-AC-08 (I) WHEN "translate before insert" is on THE SYSTEM SHALL translate via `TranslationRouter` and insert the translation; on translation failure it SHALL insert the original and notify.
- DICT-AC-09 (U) WHEN the language is English (or another Apple-supported locale) THE SYSTEM SHALL route to SpeechAnalyzer; WHEN Sinhala THE SYSTEM SHALL route to the Sinhala engine (flagged experimental); per `EngineRouter`.
- DICT-AC-10 (P) WHEN speech begins THE SYSTEM SHALL show the first partial within 600 ms (SpeechAnalyzer) / 1.5 s (others) and insert within 400 ms of release for utterances < 10 s.
- DICT-AC-11 (U) WHEN an entry is inserted THE SYSTEM SHALL save a `DictationEntry` (unless history is disabled); history SHALL be searchable, limited to last N (default 200), clearable.
- DICT-AC-12 (UI) WHEN the dictation device (per-feature override) is unplugged THE SYSTEM SHALL fall back to default input and notify.
- DICT-AC-13 (U) WHEN the hotkey is released < 250 ms after press (accidental tap) THE SYSTEM SHALL cancel without inserting.
- DICT-AC-14 (U) WHEN an engine fails THE SYSTEM SHALL dismiss the HUD with an error toast and SHALL NOT insert partial text.
- DICT-AC-15 (U) WHEN secure input is active (password fields) THE SYSTEM SHALL refuse insertion and say why.
- DICT-AC-16 (UI) WHEN Reduce Transparency/Motion are on THE SYSTEM SHALL use a solid HUD and no animated transitions.

## Edge cases
Target app switches mid-dictation (insert into the app focused at finalize time), apps that intercept ⌘V, clipboard managers (use concealed/transient pasteboard type), very long dictation (> 2 min segments in chunks), RTL/Sinhala text insertion, sandboxed target apps.

## NFR
Idle cost zero (hotkey monitor only); HUD updates ≤ 30 Hz; end-to-end hotkey-to-capture start < 150 ms with warmed engine.

## Test notes
Unit: hotkey state machine, post-processing order, pasteboard save/restore using an injected pasteboard abstraction. Insertion into real apps and Accessibility are manual (unverified pending user run).
