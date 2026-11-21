# 17 — Ignored Segments (IGN)
Status: DRAFT (Phase 4) · Owner: Processing (+ Settings UI engineer) · Package: `Processing`, `Features/Settings`

## Scope
Rule-based hiding of non-speech markers and optional gated hallucination filtering. Filtering is **non-destructive**: segments are flagged `isIgnored`, never deleted. Applies to file jobs, live captions, meetings and dictation; exports respect it.

## AppCore contracts used
`IgnoreRule` (`RuleMatch`, `RuleScope`, `isHallucinationRule`), `TranscriptPostProcessor`, `PostProcessingContext`, `RuleRepository`, `Segment.isIgnored/confidence/noSpeechProbability`, `ExportOptions.includeIgnored`.

## Default rules (exact, whole-segment, enabled)
`[BLANK_AUDIO]`, `[ BLANK_AUDIO ]`, `[Music]`, `[music]`, `[MUSIC PLAYING]`, `[MUSIC]`, `(music)`, `[no audio]`, `[ Silence ]`, `[silence]`, `[inaudible]`, `[GASP]`, `[ Pause ]`, `( retirement bell rang )`, `( silence )`, `(crunching)`, `(door slams)`, `(silence)`, `[Pause]`, `[Silencio]`, `(scissors snipping)`, `(Applause.)`, `(Pause)`, `[APPLAUSE]`, `[LAUGHTER]`, `(laughs)`, `[NOISE]`, `*music*`, `♪`, `♪♪`.
Hallucination list (**off by default**, `isHallucinationRule = true`): "Thank you for watching.", "Subtitles by the Amara.org community" (+ user additions).

## Acceptance criteria (EARS)
- IGN-AC-01 (U) WHEN the app first launches THE SYSTEM SHALL seed exactly the default list above and "Restore defaults" SHALL restore it without removing user-added rules unless the user chooses "Reset all".
- IGN-AC-02 (U) WHEN match is `exact` THE SYSTEM SHALL compare after trimming, collapsing internal whitespace and case-folding (so `[ music ]`-style variants listed separately still match their own rule; normalization never strips brackets).
- IGN-AC-03 (U) WHEN match is `contains` THE SYSTEM SHALL flag a segment containing the pattern (normalized); WHEN `regex` it SHALL evaluate an `NSRegularExpression`; an invalid regex SHALL be rejected at save time with an inline error and never crash processing.
- IGN-AC-04 (U) WHEN scope is `wholeSegment` and the segment matches THE SYSTEM SHALL set `isIgnored = true`; WHEN `inline` THE SYSTEM SHALL remove the matched span from the text (keeping word timings of the remainder) and flag the segment ignored only if it becomes empty.
- IGN-AC-05 (U) WHEN a rule is disabled or soft-deleted THE SYSTEM SHALL stop applying it, and re-processing SHALL un-ignore segments that no longer match (flags are derived, not permanent) unless the user manually set the flag.
- IGN-AC-06 (U) WHEN the hallucination filter is on AND text matches a hallucination rule THE SYSTEM SHALL flag the segment only IF `confidence < lowConfidenceThreshold` OR `noSpeechProbability >= noSpeechThreshold`; otherwise it SHALL keep it (these phrases can be real speech).
- IGN-AC-07 (UI) WHEN "Show ignored" is off in the editor THE SYSTEM SHALL hide flagged segments; WHEN on it SHALL show them dimmed with an "Ignored" badge and a per-segment "Stop ignoring" action.
- IGN-AC-08 (U) WHEN exporting with `includeIgnored == false` THE SYSTEM SHALL omit flagged segments from every format, and timestamps/cues SHALL not be re-based by their removal.
- IGN-AC-09 (UI) WHEN Settings → Ignored Segments is open THE SYSTEM SHALL provide a table (Segment, match, scope columns), per-row remove, add, search, Restore defaults, and JSON import/export.
- IGN-AC-10 (U) WHEN importing JSON THE SYSTEM SHALL validate the schema, report counts of added/skipped/invalid, and be undoable; export SHALL write the same schema (round-trip equal).
- IGN-AC-11 (U) WHEN a duplicate pattern+match+scope is added THE SYSTEM SHALL refuse it with a message.
- IGN-AC-12 (I) WHEN live captions or dictation produce text THE SYSTEM SHALL apply the same filter chain (ignored live lines are not shown/inserted).
- IGN-AC-13 (U) WHEN rule CRUD occurs THE SYSTEM SHALL persist via `RuleRepository` and soft-delete (`deletedAt`) rather than hard delete.
- IGN-AC-14 (UI) WHEN the table has 1 000+ rules THE SYSTEM SHALL remain responsive (search < 100 ms).

## Edge cases
Rule order independence (any match flags), Unicode normalization (NFC) for Sinhala, `♪` repeated inside longer text (contains), regex catastrophic backtracking (evaluation timeout 50 ms → treat as non-match + warn), empty pattern rejected, multi-line segments.

## NFR
Filtering 10 000 segments × 100 rules < 200 ms; deterministic and side-effect free.

## Fixtures
Table-driven unit cases: every default rule positive; near-miss negatives (`[Music] and talk`); hallucination gating matrix (confidence × noSpeech × list on/off); mixed English+Sinhala segment; music/silence fixture from `/fixtures` for an integration run (no Whisper output asserted verbatim; use scripted segments).
