# 11 — Transcript Editor & Player (EDIT)
Status: Draft. Owners: UI engineers; text/timing helpers in Processing.

## Scope
Segment/paragraph transcript view on solid background; docked AVKit player (resizable/detachable); click-to-seek; karaoke highlighting; inline editing with word-timing preservation; split/merge; speaker/language changes; bookmarks; find/replace; waveform scrubber; view options; undo/redo.

## AppCore protocols used
`TranscriptRepository`, `MediaRepository`, `TranscriptPostProcessor`, `TranscriptionEngine` (segment re-transcribe), `JobQueue`, `LanguageIdentifier`, `Diarizer` data (`SpeakerReconciler`), `SettingsStore`.

## Acceptance criteria (EARS)
- EDIT-AC-01 (UI) THE SYSTEM SHALL show per segment: speaker, timestamp, language badge and text, with word-level timing retained.
- EDIT-AC-02 (integration) WHEN the user clicks a word THE SYSTEM SHALL seek playback to that word's start in < 100 ms.
- EDIT-AC-03 (UI) WHEN the user double-clicks a segment THE SYSTEM SHALL play from the segment start.
- EDIT-AC-04 (UI) WHILE playing THE SYSTEM SHALL highlight the current word and auto-scroll; WHEN the user scrolls manually THE SYSTEM SHALL pause auto-scroll and show "Return to playhead".
- EDIT-AC-05 (UI) THE SYSTEM SHALL support playback speeds 0.5×–3×, skip ±5/15 s, and shortcuts Space, J/K/L, ←/→.
- EDIT-AC-06 (unit) WHEN text of a segment is edited THE SYSTEM SHALL re-align word timings by interpolation within the segment's range, preserving unchanged words' timings.
- EDIT-AC-07 (unit) WHEN segments are split or merged THE SYSTEM SHALL partition/concatenate words, keep timings monotonic, and keep speaker/language consistent.
- EDIT-AC-08 (UI) THE SYSTEM SHALL allow changing speaker or language for a segment or selection; WHEN speaker is renamed THE SYSTEM SHALL apply it across the transcript; speakers can be merged and colours chosen.
- EDIT-AC-09 (integration) WHEN the user corrects a segment's language and chooses re-transcribe THE SYSTEM SHALL re-run only that segment with the chosen language and replace its text/words.
- EDIT-AC-10 (UI) WHEN "Show ignored" is off THE SYSTEM SHALL hide segments with `isIgnored`; WHEN on THE SYSTEM SHALL show them dimmed.
- EDIT-AC-11 (UI) WHEN the user presses ⌘F / ⌥⌘F THE SYSTEM SHALL open find / replace with match case, whole word, regex and scope (all, selection, speaker, language), preview of replacements, replace one/all (see FR spec).
- EDIT-AC-12 (unit) THE SYSTEM SHALL support full undo/redo for text, speaker, language, split/merge and replace operations.
- EDIT-AC-13 (UI) THE SYSTEM SHALL allow bookmarks/highlights with notes at a time or selection, listed and navigable.
- EDIT-AC-14 (UI) THE SYSTEM SHALL provide view options (font family/size, line spacing, timestamps, speakers, density, paragraph vs segment view) as global defaults with per-transcript overrides.
- EDIT-AC-15 (manual) WHEN Sinhala text is displayed THE SYSTEM SHALL render correct shaping, font fallback and line breaking (PROD-AC-05).
- EDIT-AC-16 (UI) THE SYSTEM SHALL show an optional waveform scrubber with speaker-coloured regions.
- EDIT-AC-17 (UI) WHEN the player is detached THE SYSTEM SHALL keep word click/seek and highlighting in sync across windows.
- EDIT-AC-18 (integration) WHEN edits are made THE SYSTEM SHALL persist them incrementally without blocking typing (> 60 fps input).
- EDIT-AC-19 (UI) WHEN media is missing THE SYSTEM SHALL disable player controls and offer Relink while keeping the text editable.

## Edge cases
Audio-only (no video): show waveform instead of video. Very long transcripts: virtualised list. Empty transcript: explain silence/ignored. Low-confidence words optionally underlined.

## Non-functional
Click→seek < 100 ms; typing latency < 16 ms; scrolling 60 fps with 10,000 segments.
