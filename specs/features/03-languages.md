# 03 — Languages (LANG)

Status: DRAFT (Phase 4). Owners: Transcription (routing/LID), Features/Settings (pickers). Sources: ADR-004, ADR-008, `specs/research/sinhala-asr.md`; brief §5.5.

## Scope
Language modes (single / auto-detect / multilingual set), English default, linked language↔model pickers, per-segment language ID and badges, per-segment re-transcription, Sinhala rendering and export correctness.

## AppCore dependencies
`LanguageMode`, `LanguageCode`, `LanguageScore`, `LanguageIdentifier`, `VoiceActivityDetector`, `LanguageCapabilityTable`, `ModelDescriptor`, `Segment` (`languageCode`, `languageConfidence`), `EngineRouter`, `RoutingRequest`, `ExportOptions`.

## Behaviour summary
- Default `LanguageMode.single("en")` everywhere (global default, per job, per live session).
- Language-first: user picks languages → router picks engine/model ("Auto"). Advanced picker lists only models covering the chosen languages. Choosing a model first narrows the language list. Both directions come from `LanguageCapabilityTable` (ADR-008).
- Multilingual mode: VAD segments → `LanguageIdentifier` restricted to the chosen set → per-language engine/model; each `Segment` stores language + confidence.
- Sinhala is first-class but labelled "experimental" (measured CER ≈ 6 % read speech, ≈ 21 % conversation, ≈ 27 % code-mixed).

## Acceptance criteria
| ID | Criterion | Test |
|---|---|---|
| LANG-AC-01 | WHEN no language is configured THE SYSTEM SHALL use English as the default mode. | unit |
| LANG-AC-02 | WHEN the user chooses languages THE SYSTEM SHALL list only models whose `languages` cover all chosen languages. | unit / UI |
| LANG-AC-03 | WHEN the user chooses a model THE SYSTEM SHALL restrict the language list to that model's languages and keep the current selection if still valid, otherwise reset to the model's first language. | unit / UI |
| LANG-AC-04 | WHEN auto-detect is selected THE SYSTEM SHALL identify one language from the first ~30 s and apply it to the whole job. | integration |
| LANG-AC-05 | WHEN multilingual mode is selected THE SYSTEM SHALL run language ID per VAD segment limited to the chosen set and store `languageCode` and confidence on each segment. | integration |
| LANG-AC-06 | WHEN a segment's language ID confidence is below the threshold THE SYSTEM SHALL fall back to the previous segment's language and flag the segment as uncertain. | unit |
| LANG-AC-07 | WHEN segments are displayed THE SYSTEM SHALL show a language badge when more than one language is present or the setting is on. | UI |
| LANG-AC-08 | WHEN the user corrects a segment's language and chooses re-transcribe THE SYSTEM SHALL re-run only that segment's time range with the engine for the new language and replace its text and words, keeping a revision. | integration |
| LANG-AC-09 | WHEN Sinhala is selected THE SYSTEM SHALL route to the Sinhala model, never to stock Whisper turbo, and show an "experimental" badge. | unit |
| LANG-AC-10 | WHEN the Sinhala model is not installed THE SYSTEM SHALL prompt a download with size and licence (CC BY-SA 4.0) before use. | UI |
| LANG-AC-11 | WHEN Sinhala text is rendered in the editor, overlay, HUD or exports THE SYSTEM SHALL use a Sinhala-capable font fallback with correct shaping and line breaking. | UI / manual |
| LANG-AC-12 | WHEN a mixed-language transcript is exported to JSON, HTML or TTML THE SYSTEM SHALL include per-cue language (`lang` attributes). | unit (golden) |
| LANG-AC-13 | WHEN the engine for an Apple locale is not installed THE SYSTEM SHALL offer the Apple asset download via `ModelManaging`. | integration |
| LANG-AC-14 | WHEN a language has no installed or supported engine on this machine THE SYSTEM SHALL show it as unavailable with the reason rather than failing silently. | UI |
| LANG-AC-15 | WHEN the language set changes during a live session THE SYSTEM SHALL apply it to subsequent audio without restarting capture. | integration |

## Edge cases
Wrong script output (Devanagari/Gujarati from Whisper on Sinhala) → treated as engine error for that model; code-switching inside one sentence; very short segments (< 1 s) where LID is unreliable; locale variants (`en-US` vs `en`); Apple locale list on macOS 26 differs from 27.

## Non-functional
Per-segment LID overhead < 100 ms per segment; single-language mode skips LID entirely.

## Unverified pending user run
Sinhala quality is measured on small samples (n=40/60) with an unlicensed code-mixed set used for internal evaluation only; no licensed Sinhala+English set exists; user-supplied recordings optional. LID model choice for Sinhala vs English is not yet benchmarked.
