# 00 — Product Spec: Earmark

Status: **FROZEN (signed off 2026-11-21)**
Working name: Earmark · Bundle prefix (placeholder): `lk.dumindu.earmark`

## 1. Vision
A privacy-first native macOS app that turns speech into accurate, editable, exportable transcripts, **entirely on-device**. English is the default; Sinhala is first-class; multiple languages may appear in one transcript.

## 2. Principles (non-negotiable)
- **P1 Local only.** No cloud ASR/translation, telemetry or analytics. The only network use is user-initiated model downloads (Hugging Face / Apple asset catalogs).
- **P2 Native.** Swift 6 strict concurrency, SwiftUI first; AppKit only for non-activating panels, global hotkeys, Core Audio.
- **P3 HIG + Liquid Glass.** Glass for chrome (sidebar, toolbars, overlay, HUD, menu bar popover); solid backgrounds for transcript content. Reduce Transparency / Reduce Motion / Increase Contrast honored.
- **P4 Resilient.** Engine failures become job failures with retry, never crashes. Crash-safe journaling; no user data loss.
- **P5 Non-destructive.** Ignore filters, replacements, soft delete and revisions never destroy source data.

## 3. Personas
| ID | Persona | Needs |
|----|---------|-------|
| PER-1 | **Remote worker / manager** | Auto-transcribe + record Zoom/Teams meetings, speaker labels, post-meeting summary-ready transcript |
| PER-2 | **Journalist / researcher** | Batch-transcribe interviews, edit with synced playback, export DOCX/SRT |
| PER-3 | **Sinhala/English bilingual creator** | Code-switched transcripts, Sinhala rendering, subtitles, translation |
| PER-4 | **Accessibility user** | Live captions overlay for any audio, dictation into any app |

## 4. Scope
### In scope (v1)
Files & batch transcription · Meetings (Zoom, Teams) · Live Captions overlay · Dictation · diarization · multilingual/code-switching · translation · ignored segments · find/replace & global replacements · synced player/editor · rich export · Library with soft delete · menu bar app · Model Manager · onboarding · Developer ID distribution with Sparkle.

### Out of scope (v1)
Mac App Store (non-sandboxed by necessity); cloud sync; iOS/iPadOS; Google Meet/Webex detection (architecture should allow later); LLM summarization; collaborative editing; voice cloning.

## 5. Feature areas and user stories
(Detailed EARS criteria live in `/specs/features/NN-*.md`, Phase 4. IDs below reserve the prefixes.)

| Prefix | Area | Representative stories |
|--------|------|------------------------|
| `NAV` | App shell & navigation | As a user I navigate Home/Queue/Meetings/Live/Library/Recently Deleted via a glass sidebar; ⌘K quick open; full keyboard + VoiceOver |
| `MENU` | Menu bar | I start/stop captions or meeting capture in one click and see state + last 2–3 caption lines |
| `FILE` | File & batch | I drop files/folders, tune per-batch settings, and the queue survives restarts and resumes after a crash |
| `ENG` | Engines & models | "Auto" picks the right engine per language/use case; I download, verify, delete, import custom CoreML models |
| `LANG` | Languages | I pick single / auto-detect / multilingual sets; segments carry language badges and can be re-transcribed |
| `DIA` | Diarization | I toggle speaker labels, rename/merge/reassign speakers, optionally save local voice profiles |
| `MTG` | Meetings | Zoom/Teams detection → notify / auto-transcribe / auto-record; dual-track; finalization pass |
| `LIVE` | Live captions | A click-through, non-activating glass overlay captions mic, system audio, or both |
| `DICT` | Dictation | Hold/toggle a global hotkey, see a HUD, text is inserted into the focused app |
| `AUD` | Audio input | I pick devices per feature with level meters; unplug falls back gracefully |
| `EDIT` | Editor & player | Click a word to seek; karaoke highlight; inline edit preserving timings; undo/redo |
| `IGN` | Ignored segments | Defaults + custom rules (exact/contains/regex), hallucination filter (off by default), non-destructive |
| `FR` | Find & replace | In-transcript ⌘F / ⌥⌘F; global replacement rules applied automatically |
| `TRN` | Translation | Parallel translation track; original / translated / bilingual views and exports |
| `EXP` | Export | TXT, MD, DOCX, HTML, PDF, JSON, CSV; SRT, VTT, ASS, SBV, TTML, LRC; presets; batch/zip/watch folder |
| `LIB` | Library & data | Full-text search, folders/tags, soft delete (30 d default), revisions, relink missing media |
| `SET` | Settings | All sections in the brief, incl. Privacy & Permissions deep links |
| `ONB` | Onboarding | Welcome → languages → recommended model → just-in-time permissions → menu bar tour |

## 6. Headline acceptance criteria (EARS, product level)
- **PROD-AC-01** WHEN the app runs THE SYSTEM SHALL make no network request except user-initiated model downloads.
- **PROD-AC-02** WHEN a file transcription engine fails THE SYSTEM SHALL mark the job failed with a retry action and SHALL NOT terminate the app.
- **PROD-AC-03** WHEN the app is force-quit during a job THE SYSTEM SHALL resume from the last checkpointed chunk on next launch.
- **PROD-AC-04** WHEN Reduce Transparency is enabled THE SYSTEM SHALL render glass surfaces as solid.
- **PROD-AC-05** WHEN Sinhala text is displayed or exported THE SYSTEM SHALL render it with correct shaping and a Sinhala-capable font.
- **PROD-AC-06** WHEN a segment matches an ignore rule THE SYSTEM SHALL flag it hidden rather than delete it.
- **PROD-AC-07** WHEN recording is active THE SYSTEM SHALL show a persistent recording indicator.
- **PROD-AC-08** WHEN an item is soft-deleted THE SYSTEM SHALL keep it restorable until the retention period elapses.

## 7. Performance targets (verified in Phase 7, M1-class baseline; dev machine is M3 Pro 18 GB)
- Live first partial < 600 ms (SpeechAnalyzer) / < 1.5 s (WhisperKit); finalized < 2 s.
- File transcription ≥ 10× real-time with large-v3 turbo on M1 Pro class.
- Idle (menu bar only) CPU < 1 %, RAM < 150 MB with no model loaded.
- Click word → seek < 100 ms; 5,000-transcript library loads < 500 ms.

## 8. Platform & distribution
macOS 26+ (min version pending sign-off; dev machine runs 27), Apple Silicon only. Non-sandboxed, Developer ID, hardened runtime, notarized, Sparkle 2 (process taps, global hotkeys, CGEvent insertion and Accessibility make the Mac App Store unsuitable — to be confirmed by research, ADR-005).

## 9. Legal / consent
One-time recording-consent notice; user is responsible for informing participants. Third-party model licenses surfaced in Model Manager (flag CC-BY-NC models).

## 10. Sign-off amendments (2026-11-21)
- Non-commercial app. English is the default language; language and model pickers are linked both ways (ADR-008).
- Teams and meeting video recording are in v1. Meeting detection prompts ("ask first") by default; automatic transcribe / transcribe+record is a per-app Settings option.
- Models are downloadable on demand: choosing an undownloaded model downloads it with visible progress; Settings manages/deletes/imports models.
- Live speaker labels are in v1 (max 4 live speakers; offline pass reconciles).
- Direct distribution with Sparkle auto-update; no Mac App Store.
Decision record: `01-architecture.md` §12.
