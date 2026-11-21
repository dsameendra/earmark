# 14 — Export (EXP)
Status: DRAFT (Phase 4) · Owner: Export engineer · Package: `Export`

## Scope
Pure-Swift generation of document and subtitle formats from a `TranscriptDocument`; single, selection/range, per-speaker, batch (folder/.zip) and auto-export on job completion (watch folder); presets; clipboard/share.
Formats (`ExportFormat`): txt, markdown, docx, html, pdf, json, csv, srt, vtt, ass, sbv, ttml, lrc.

## AppCore contracts used
`Exporter`, `ExportOptions`, `ExportPreset`, `ExportArtifact`, `SubtitleConstraints`, `TimestampStyle`, `TranslationExportMode`, `TranscriptDocument`, `PresetRepository`, `JobSettings.autoExportPresetID`, `JobQueue` (auto-export hook), `AppError.exportFailed`.

## Acceptance criteria (EARS)
Test types: U=unit/golden, I=integration, UI=XCUITest, M=manual.
- EXP-AC-01 (U) WHEN a transcript is exported in any `ExportFormat` THE SYSTEM SHALL produce an `ExportArtifact` byte-identical to the committed golden file for the fixture transcript.
- EXP-AC-02 (U) WHEN `includeIgnored` is false THE SYSTEM SHALL omit segments with `isIgnored == true`; WHEN true it SHALL include them.
- EXP-AC-03 (U) WHEN `timestamps` is `.none/.perSegment/.perParagraph/.everyNSeconds(n)` THE SYSTEM SHALL emit timestamps at exactly that granularity in text-like formats.
- EXP-AC-04 (U) WHEN `includeSpeakers` is true THE SYSTEM SHALL label turns with speaker names (VTT: `<v Name>` tags; ASS: Name field; TTML: `ttm:agent`).
- EXP-AC-05 (U) WHEN `mergeSameSpeaker` is true THE SYSTEM SHALL merge consecutive same-speaker segments whose gap is <= 2 s.
- EXP-AC-06 (U) WHEN `translation` is `.replace` THE SYSTEM SHALL output only the translation track for `translationLanguage`; WHEN `.bilingual` it SHALL output original then translation (dual-line SRT/VTT); WHEN `.none` the original only. IF a segment lacks that translation THEN it SHALL fall back to the original text.
- EXP-AC-07 (U) WHEN a subtitle format is exported THE SYSTEM SHALL honor `SubtitleConstraints` (max chars/line, max lines/cue, min/max cue duration, min gap, split on punctuation) and SHALL NOT emit overlapping cues.
- EXP-AC-08 (U) WHEN `timeOffset` is set THE SYSTEM SHALL shift all timestamps by it, clamping at 0; WHEN `timeRange` is set it SHALL export only segments intersecting it, re-based to range start.
- EXP-AC-09 (U) WHEN JSON is exported THE SYSTEM SHALL include segments, words, timings, speakers, per-segment `languageCode`, confidence and all translation tracks, and SHALL round-trip through `JSONDecoder` to an equal `TranscriptDocument`.
- EXP-AC-10 (U) WHEN HTML or TTML is exported for mixed-language content THE SYSTEM SHALL set per-cue/segment `lang` (`xml:lang` in TTML).
- EXP-AC-11 (U) WHEN DOCX is exported THE SYSTEM SHALL produce valid OOXML (zip with `[Content_Types].xml`, `word/document.xml`) that opens without repair in Pages/Word and declares a Sinhala-capable font for `si` runs (complex-script `w:rFonts cs`, `w:lang w:bidi`/`w:val`).
- EXP-AC-12 (I) WHEN PDF is exported THE SYSTEM SHALL render Sinhala text with correct shaping using an embedded Sinhala-capable font and SHALL paginate long transcripts without clipping.
- EXP-AC-13 (U) WHEN CSV is exported THE SYSTEM SHALL RFC-4180-quote fields containing commas, quotes or newlines and write UTF-8 with BOM-less output.
- EXP-AC-14 (U) WHEN per-speaker export is chosen THE SYSTEM SHALL produce one artifact per speaker containing only that speaker's segments.
- EXP-AC-15 (I) WHEN batch export targets a folder or .zip THE SYSTEM SHALL write one file per transcript with collision-free names (` (2)` suffix) and a valid .zip (ZIPFoundation).
- EXP-AC-16 (I) WHEN a job with `autoExportPresetID` completes THE SYSTEM SHALL write the export to the configured watch folder within 5 s and SHALL log failures without failing the job.
- EXP-AC-17 (U) WHEN a preset is saved THE SYSTEM SHALL persist it and WHEN the export sheet reopens THE SYSTEM SHALL preselect the last-used preset.
- EXP-AC-18 (UI) WHEN the user chooses Copy as Plain Text/Markdown THE SYSTEM SHALL place it on the pasteboard; Share SHALL invoke the system share sheet.
- EXP-AC-19 (U) WHEN options are invalid (e.g. bilingual without `translationLanguage`) THE SYSTEM SHALL throw `AppError.exportFailed` with a user-readable reason.

## Format notes
SRT `HH:MM:SS,mmm`; VTT with header + optional `STYLE`; ASS with `[Script Info]/[V4+ Styles]/[Events]`, one style per speaker colour; SBV `H:MM:SS.mmm`; LRC `[mm:ss.xx]`, audio sources only; TTML/DFXP 1.0 namespaces; Markdown uses `**Speaker** [00:01:02]`.

## Edge cases
Empty transcript (valid empty artifact), segment with no words, Sinhala combining marks must not be split across cue lines, RTL absent, very long (>10 h) transcripts stream-built, filenames sanitized, illegal XML characters stripped.

## NFR
10 000 segments export < 2 s for text formats, < 8 s for PDF; peak memory < 200 MB; deterministic output (sorted keys, fixed locale `en_US_POSIX`).

## Fixtures / golden files
`/fixtures` English single speaker, AMI 4-speaker (speakers), synthetic bilingual en+si transcript (hand-authored, no licence issue), ignored-segment sample. Goldens in `Packages/Export/Tests/Golden/<format>/<case>.golden`; regeneration requires explicit `UPDATE_GOLDENS=1`.
