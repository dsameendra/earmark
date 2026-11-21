# 06 — Translation (TRN)

Status: DRAFT (Phase 4). Owner: Translation package. Sources: ADR-003, ADR-006, `specs/research/translation.md`; brief §5.14. Posture: non-commercial app (user sign-off 2026-11-21).

## Scope
Whole-transcript and selected-segment translation stored as a parallel track per segment, view modes (original / translation / side-by-side), live translation line (best effort, throttled), engine routing, translation model management, export options.

## AppCore dependencies
`TranslationEngine`, `TranslationRouter`, `LanguagePair`, `TranslationItem`, `TranslatedSegment` (`isLowConfidence`), `SegmentTranslation`, `Segment.translations`, `ModelManaging`, `ModelKind.translation`, `CaptionLine.translation`, `ExportOptions` (`translation`, `translationLanguage`), `JobQueue` (`.translate`), `AppError`.

## Routing
| Pair | Engine | Notes |
|---|---|---|
| Apple-supported pairs (47 languages; no Sinhala) | Apple Translation (`TranslationSession`) | headless `TranslationSession(installedSource:target:)`; models managed by the OS |
| si ↔ en | NLLB-200 distilled 600M (CC-BY-NC-4.0) | primary because the app is non-commercial; card says "not for production" — shown in UI |
| si ↔ en (alternative) | MADLAD-400 3B (Apache-2.0) | optional download; Swift runtime unresolved (ADR-003) |
| any → en | Whisper translate task | fallback only; never with turbo (use large-v3) |
| en → si | any of the above | always labelled low-confidence |

## Acceptance criteria
| ID | Criterion | Test |
|---|---|---|
| TRN-AC-01 | WHEN a pair is requested THE SYSTEM SHALL choose the engine from the routing table via `TranslationRouter` (pure for a given set of installed models). | unit |
| TRN-AC-02 | WHEN the pair involves Sinhala THE SYSTEM SHALL route to NLLB (or an installed alternative) and never to Apple Translation. | unit |
| TRN-AC-03 | WHEN the needed translation model is not installed THE SYSTEM SHALL offer a download with size and licence and show progress via `ModelManaging.ensureAvailable`. | UI / integration |
| TRN-AC-04 | WHEN the user translates a transcript or a selection THE SYSTEM SHALL store results as `SegmentTranslation` per segment without altering the original text. | unit |
| TRN-AC-05 | WHEN translation runs as a job THE SYSTEM SHALL show progress, support cancel/retry, and persist partial results per segment. | integration |
| TRN-AC-06 | WHEN the source and target languages are identical or the source is unknown THE SYSTEM SHALL skip with a clear message. | unit |
| TRN-AC-07 | WHEN a result is `isLowConfidence` (e.g. English → Sinhala) THE SYSTEM SHALL show a "low confidence" label in the editor, overlay and exports where supported. | UI |
| TRN-AC-08 | WHEN the view mode is original, translation, or side-by-side THE SYSTEM SHALL render accordingly and persist the choice per transcript. | UI |
| TRN-AC-09 | WHEN live translation is on THE SYSTEM SHALL translate finalized lines at most once per second (throttled), show the translation line beneath the original, and drop stale requests under load. | integration |
| TRN-AC-10 | WHEN a segment is edited THE SYSTEM SHALL mark its translation stale and offer re-translate. | unit / UI |
| TRN-AC-11 | WHEN exporting THE SYSTEM SHALL support none / replace / bilingual (e.g. dual-line SRT) using the chosen target language. | unit (golden) |
| TRN-AC-12 | WHEN "translate before insert" is enabled in dictation THE SYSTEM SHALL translate the final text before insertion and fall back to the original if translation fails or exceeds a timeout. | integration |
| TRN-AC-13 | WHEN an engine fails THE SYSTEM SHALL surface a retryable error without losing existing translations. | unit (mock) |
| TRN-AC-14 | WHEN a non-commercial model (CC-BY-NC) is listed THE SYSTEM SHALL flag it with its licence and attribution in Model Manager. | UI |
| TRN-AC-15 | WHEN Apple Translation languages are not installed THE SYSTEM SHALL trigger the system download flow and report status. | manual |
| TRN-AC-16 | WHEN translating long transcripts THE SYSTEM SHALL batch segments with bounded memory and cancel within 1 s. | integration |

## Edge cases
Mixed-language segments; very long segments; empty or ignored segments (skipped); numbers/names preservation; pivot via English for non-English pairs without direct support; model licence changes if the app is ever monetised (NLLB must then be removed).

## Non-functional
Translation never blocks the main actor; NLLB 600M footprint on tier8 requires unloading ASR first (one heavy model resident).

## Unverified pending user run
Headless `TranslationSession` triggering downloads (untested; every language reported installed on the dev Mac); offline behaviour with Wi-Fi off; Sinhala model spot-checks (no Sinhala test sentences with references; scripts in `spikes/translation/scripts/`); NLLB/MADLAD runtime in Swift (MLX/CoreML conversion not done).
