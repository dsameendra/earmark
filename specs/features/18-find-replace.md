# 18 — Find & Replace (FR)
Status: DRAFT (Phase 4) · Owner: UI engineer (editor) + Processing · Packages: `Features/Editor`, `Processing`

## Scope
(a) In-transcript find (⌘F) and replace (⌥⌘F) with scopes, preview and undo. (b) Global replacement rules (Settings → Replacements) applied automatically after transcription, to live captions and to dictation. (c) Optional custom-vocabulary feeding to engines.

## AppCore contracts used
`ReplacementRule`, `RuleRepository`, `TranscriptPostProcessor`, `PostProcessingContext.applyReplacements`, `TranscriptionOptions.vocabulary`, `TranscriptRepository` (`replaceSegments`, `upsertSegments`), `JobSettings.applyReplacements`, `Segment/Word`, `LanguageCode`, `SpeakerID`.

## Acceptance criteria (EARS)
- FR-AC-01 (UI) WHEN the user presses ⌘F in a transcript THE SYSTEM SHALL open the find bar, highlight all matches, show "n of m" and step with ⏎/⇧⏎; ⌥⌘F SHALL reveal the replace field.
- FR-AC-02 (U) WHEN options are match case, whole word or regex THE SYSTEM SHALL honour each independently; an invalid regex SHALL show an inline error and perform no search.
- FR-AC-03 (U) WHEN scope is all, selection, a speaker, or a language THE SYSTEM SHALL restrict matches to that set of segments.
- FR-AC-04 (UI) WHEN the user chooses Replace All THE SYSTEM SHALL first show a preview list (before → after, per segment) and apply only on confirm; Replace (one) SHALL replace the current match and advance.
- FR-AC-05 (U) WHEN a replacement changes text length THE SYSTEM SHALL preserve word timings by re-aligning edited words via interpolation within the segment and SHALL keep segment start/end unchanged.
- FR-AC-06 (U) WHEN a replace is applied THE SYSTEM SHALL register a single undo step (per Replace All); undo/redo SHALL restore text, words and flags exactly.
- FR-AC-07 (U) WHEN a match spans multiple words THE SYSTEM SHALL merge or split `Word` entries consistently so click-to-seek still works.
- FR-AC-08 (U) WHEN a regex replacement uses capture groups (`$1`) THE SYSTEM SHALL expand them; literal mode SHALL treat `$` literally.
- FR-AC-09 (UI) WHEN find text changes THE SYSTEM SHALL update highlights in < 100 ms for 10 000 segments (debounced 150 ms) and respect the "Show ignored" toggle (ignored segments excluded unless shown).
- FR-AC-10 (U) WHEN a global replacement rule exists (e.g. "Doomindu" → "Dumindu") AND `applyReplacements` is true for the job THE SYSTEM SHALL apply it automatically after transcription, after ignore filtering, in rule order.
- FR-AC-11 (U) WHEN a rule is disabled, removed (soft delete) or the job disables replacements THE SYSTEM SHALL not apply it.
- FR-AC-12 (I) WHEN live captions or dictation produce finalized text THE SYSTEM SHALL apply global replacements before display/insertion; volatile text MAY be left unreplaced.
- FR-AC-13 (UI) WHEN Settings → Replacements is open THE SYSTEM SHALL provide add/edit/remove/enable, per-rule match case/whole word/regex, search, import/export JSON, and a "Test rule" field.
- FR-AC-14 (U) WHEN rules conflict or chain THE SYSTEM SHALL apply once in list order (no recursive re-application) and SHALL warn on rules that would loop (replacement contains its own pattern).
- FR-AC-15 (I) WHERE an engine supports prompting or contextual strings THE SYSTEM SHALL pass user vocabulary (replacement targets + custom vocabulary list, capped e.g. 100 terms / 224 tokens for Whisper prompt) via `TranscriptionOptions.vocabulary`; engines without support SHALL ignore it silently.
- FR-AC-16 (U) WHEN text includes Sinhala THE SYSTEM SHALL match on NFC-normalized text, and whole-word boundaries SHALL use Unicode word segmentation (not ASCII `\b`).
- FR-AC-17 (U) WHEN a transcript is persisted after replace THE SYSTEM SHALL update the FTS index so search reflects the new text.
- FR-AC-18 (UI) WHEN the transcript is read-only (e.g. a revision locked) THE SYSTEM SHALL disable replace but keep find.

## Edge cases
Replacing across speaker boundaries (not allowed: matches never span segments), empty replacement (deletes text), replacing inside translation tracks (scope option "Translation" off by default), overlapping matches, case-preserving replace option (title/upper/lower mirroring) as optional.

## NFR
Find over 10 000 segments < 100 ms; Replace All on 10 000 matches < 1 s; no main-actor stall > 16 ms (matching on a background actor).

## Fixtures
Unit tables for match options × scope; alignment tests on words with known timings (growing, shrinking, merged words); Sinhala NFC cases; global-rule pipeline test with scripted segments; undo/redo property test (apply+undo == original).
