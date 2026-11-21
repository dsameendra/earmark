# 01 — Architecture Spec: Earmark

Status: **DRAFT — awaiting user sign-off (Phase 2 gate)**. Live-diarization section (§6.4) pending the streaming follow-up spike.
Inputs: `/specs/research/*.md`, `/specs/00-product.md`. Decisions: `/specs/decisions/ADR-*.md`.

## 1. Constraints recap
Local-only; Swift 6 strict concurrency; SwiftUI-first; non-sandboxed Developer ID + Sparkle (ADR-005); dev/perf machine M3 Pro 18 GB, **baseline target M1 / 16 GB, 8 GB degraded mode** ("runs properly on this Mac and similar").

## 2. Research-driven findings that shape the design
| Finding | Consequence |
|---|---|
| Apple SpeechTranscriber/DictationTranscriber have **no Sinhala** | Sinhala always goes through a non-Apple engine |
| Stock Whisper large-v3-turbo is **unusable for Sinhala** (>100 % CER, wrong scripts) | Never route Sinhala to stock Whisper |
| Best measured Sinhala: Qwen3-ASR-0.6B-Sinhala 8-bit MLX (6.2 % CER read, ~21 % conversation, ~27 % code-mixed); Whisper-small Sinhala fine-tune on par on read speech but contaminated eval | **Two runtimes**: CoreML (WhisperKit) and MLX (mlx-audio-swift). Engine protocol hides this |
| FluidAudio ≈ SpeakerKit DER; FluidAudio better speaker count, cleaner embeddings, has streaming | FluidAudio primary behind `Diarizer` protocol (ADR-002) |
| Apple Translation lacks Sinhala; NLLB is CC-BY-NC | Translation routing table + commercial-licence gate (ADR-003) |
| Process taps, hotkeys, CGEvent, Accessibility → non-sandboxed | ADR-005 |

## 3. Module graph (local Swift packages; app target is thin)
```
App ──▶ Features/* ──▶ AppCore ◀── (every package depends only on AppCore, never on siblings)
Persistence  AudioCapture  Transcription  Diarization  Translation
Processing   Meetings      LiveCaptions   Dictation    Export   Models   DesignSystem
```
- **AppCore**: domain models, protocols, DTOs, errors, logging. No UI, no third-party deps.
- Composition root in `App/` wires concrete implementations; features receive protocols via DI. Cross-package calls only through AppCore protocols (enforced by package manifests + a CI dependency check).
- Third-party deps are confined to one package each: WhisperKit/mlx-audio-swift/FluidAudio→adapters in `Transcription`/`Diarization`; GRDB→`Persistence`; ZIPFoundation→`Export`; Sparkle→`App`.

## 4. Concurrency model
- Actors: `JobQueue`, `ModelManager`, `Recorder`, `LiveSession`, `EngineHost` (one per engine; serialises model load/unload).
- `@MainActor` only in Features/DesignSystem/App UI types.
- Engines run in child `Task`s with cancellation; errors → `JobFailure` (retryable), never `fatalError`. Heavy engines may be isolated in an XPC helper in a later milestone if a crash is observed (decision deferred, ADR-007 risk).
- Real-time audio: IOProc/tap callback → **lock-free SPSC ring buffer** (no alloc/lock) → consumer task converts to 16 kHz mono Float32 → `AsyncStream<AudioChunk>`.
- Back-pressure: bounded streams (`bufferingNewest`) for live paths; drop-oldest with a metric, never block capture.

## 5. Data model & persistence (ADR-001: GRDB + FTS5)
- GRDB/SQLite (WAL), migrations via `DatabaseMigrator`; FTS5 virtual table over segment text (unicode61 + custom tokenizer settings checked with Sinhala); `deletedAt` on every user-facing table; revisions as new `Transcript` rows linked by `revisionOf`.
- Incremental writes: segments committed per chunk; `Job` row journals chunk checkpoint → crash resume.
- Media: security-scoped bookmarks; library-owned media under configurable library dir; recordings written as fragmented chunks.
- Words stored in a compact blob column per segment (JSON → later binary) to keep 5,000-transcript library load < 500 ms (list queries never touch words).

## 6. Subsystems
### 6.1 Transcription (engines + routing, ADR-004)
`TranscriptionEngine` adapters: `AppleSpeechEngine` (SpeechAnalyzer), `WhisperKitEngine` (CoreML), `QwenAsrEngine` (MLX, Sinhala), optional `ParakeetEngine` (FluidAudio). `EngineRouter` is a pure function `(languages, useCase, hardware, installedModels) → EnginePlan` with a table-driven unit test per row.

| Language / mode | Live | File | Dictation |
|---|---|---|---|
| English (+ other Apple locales) | SpeechAnalyzer | WhisperKit large-v3-v20240930_626MB (Parakeet optional for EU langs) | SpeechAnalyzer |
| Sinhala | Qwen3-ASR Sinhala (MLX) *experimental*, Whisper-small-si fallback | Qwen3-ASR Sinhala | Qwen3-ASR Sinhala |
| Multilingual / code-switch | per-VAD-segment LID restricted to the chosen set → per-language engine | same | same |
| Low-RAM (≤ 8 GB) | smaller models, serial engine loading | | |
Per-segment `languageCode` + confidence stored. Sinhala stays flagged "experimental, quality varies" in UI.

### 6.2 Chunking & long files
VAD-segmented chunks, bounded memory (stream decode via AVAssetReader → 16 kHz mono Float32), checkpoint after each chunk. Concurrency limited by hardware tier (memory-pressure aware).

### 6.3 Capture & meetings
- Mic: AVAudioEngine + Core Audio device enumeration, route-change restart (spike PoC).
- App audio: Core Audio process tap (bundleIDs targeting) + aggregate device; silent-denial detection via all-zero buffers; ScreenCaptureKit fallback.
- Detection: app's audio process has input **and** output active, debounced (primary); device-running flag corroborates; no Accessibility window titles in v1.
- Echo: default headphone hint + cross-track text dedupe; voice processing opt-in; avoid Bluetooth-HFP mic default (prefer built-in mic).
- Recording: separate AAC tracks + mixed track, fragment-safe writing; video via SCStream optional (v1: audio only unless approved).
- **Unverified pending user run** (see spike): tap path, TCC denial behavior, hot-plug, crash-safety.

### 6.4 Diarization (live in v1 — **user requirement**)
`Diarizer` protocol with `offline` and `streaming` variants. Offline: FluidAudio Community-1, SpeakerKit swappable fallback. **Live: FluidAudio LS-EEND `.ami` primary** (pooled strict DER 15.7 on 3 AMI headset meetings, best case since trained on AMI-style audio; ~1.1 s label latency; 43 MB, MIT; max 4 speakers), **Sortformer v2 fallback** (DER ~25, CC-BY weights only; v2.1 is NVIDIA Open Model License: revocable, avoid). Live DER numbers were measured on easy headset audio, so treat them as optimistic. No tested engine does live labels for >4 speakers (UI caps live labels at 4 and shows "More speakers" until the offline pass).
Meetings: mic track = "You", remote diarized live. Live labels are provisional: audio is recorded, the offline pass reruns on the remote track, and live slots map to offline speakers by maximum overlap (spike §11.5); a visible relabel at meeting end is expected (live vs offline disagree on 17-29% of audio). Dual-track bleed: a simple time-overlap gate falsely deletes real interruptions, so use echo cancellation + voice-profile check instead (unverified on real captures). Voice profiles: local embeddings; threshold needs more data.

### 6.5 Translation (ADR-003)
Apple Translation (headless `TranslationSession(installedSource:target:)`) default; Sinhala via MADLAD-3B (Apache-2.0, runtime TBD) in commercial builds or NLLB in non-commercial builds — gated by a build flag/licence decision; English→Sinhala labelled low-confidence; Whisper translate task not used with turbo.

### 6.6 Processing pipeline
`TranscriptPostProcessor` chain: ignore filter (flag, not delete) → hallucination filter (off by default, confidence-gated) → replacements → formatting. Same chain on file, live and dictation.

### 6.7 Overlay, Dictation, Menu bar
Non-activating NSPanel overlay; dictation via global hotkey + pasteboard-preserving ⌘V (AX insertion alternative); `MenuBarExtra(.window)`; app may run as accessory.

### 6.8 Export
Pure-Swift exporters with golden-file tests; DOCX via ZIPFoundation; PDF via WKWebView.createPDF with embedded Sinhala-capable font.

## 7. Performance & resource strategy (runs well on this Mac and similar)
- **Hardware tiers** detected at launch (chip family, RAM, ANE): `tier8`, `tier16`, `tier32+`. Router and `ModelManager` pick model size, concurrency and prewarm policy by tier.
- **One heavy model resident at a time by default** (LRU unload; memory-pressure source → unload); prewarm optional.
- Idle budget: menu-bar-only < 1 % CPU, < 150 MB RAM, no polling timers (event-driven detection; coalesced timers with tolerance).
- Live paths prefer ANE/CoreML where the engine allows; MLX (GPU) for Sinhala; avoid running GPU + ANE heavy engines concurrently on `tier8`.
- Battery: lower QoS / concurrency on battery (setting); thermal-state observer throttles.
- **Measured on M3 Pro 18 GB (serial, AC power; machine not fully idle, 5.5 GB swap in use; see `/specs/research/benchmarks.md`)**:
  - WhisperKit turbo-626MB files: 13–17x realtime; warm load ~1.1 s; first load after download 115 s (show progress). Live decode per window 0.74 s (3 s) to 1.15 s (10 s): meets the <1.5 s target (decode only; end-to-end needs mic run).
  - SpeechAnalyzer files 55–134x realtime.
  - Diarization 1049 s meeting: FluidAudio offline 264x (0.9 GB), SpeakerKit 101x, LS-EEND streaming 88x (138 MB, ~1% CPU), Sortformer 8–24x.
  - Sinhala (Python reference): Qwen 8.4x, whisper-small-si 11.3x, ~2.3 GB peak.
  - ASR + LS-EEND concurrently: ASR unaffected, diarization ~15% slower, so one-heavy-model residency is a **memory** rule (8 GB tier, Sinhala), not a compute rule.
  - **M1 extrapolation (unverified):** turbo files ~7–12x on M1 Pro, so the 10x target is not safe there; M1 8 GB is memory-bound. Real M1/8 GB hardware still needed (**open**).
- Perf regressions guarded by `XCTMetric`/Swift Testing perf tests in Phase 7.

## 8. UI architecture
SwiftUI `NavigationSplitView`, Liquid Glass chrome, solid content areas; `Features/*` per screen; `DesignSystem` owns glass components with automatic Reduce Transparency/Contrast fallback; Sinhala font fallback verified in transcript text views (TextKit 2).

## 9. Testing
Swift Testing unit suites (exporters golden, routing table, queue state machine, ignore filter, alignment); integration with `/fixtures` (English, 2-speaker, 4-speaker, music/silence, video; Sinhala from public sets, no redistributed licence-less audio); WER/CER/DER baselines recorded; XCUITest flows; manual QA scripts for permission-gated features.

## 10. Security & privacy
No telemetry; network only for user-initiated downloads (allow-listed hosts, checksum verification); hardened runtime; models never executed as code (no `trust_remote_code`; Python only used in dev tooling); transcripts and voice embeddings stored locally, deletable.

## 11. Licences & attribution (tracked in `/specs/decisions/ADR-006`)
WhisperKit MIT · FluidAudio Apache-2.0 (models CC-BY-4.0 attribution) · Qwen3-ASR Sinhala CC BY-SA 4.0 (share-alike implications to confirm) · MADLAD Apache-2.0 · NLLB CC-BY-NC (non-commercial only) · Sortformer licence unresolved.

## 12. Decisions (signed off by the user, 2026-11-21)
1. **Name / prefix:** Earmark, `lk.dumindu.earmark` (defaults, accepted).
2. **Minimum macOS:** 26; 27-only APIs behind `#available`.
3. **Signing:** no signing identity, Xcode account or provisioning profile exists on this Mac. Development uses ad-hoc / local signing. Developer ID + notarization (and Sparkle releases) need an Apple Developer Program membership: **pending, blocks only M7**. Note: with ad-hoc signing TCC grants follow the code hash, so rebuilds may re-prompt for Mic / System Audio / Accessibility; a free Personal Team (Xcode > Settings > Accounts) gives a stable Apple Development certificate and is recommended before M4.
4. **Licensing posture:** non-commercial. NLLB-600M allowed (CC-BY-NC binds any future monetisation). See ADR-003/006.
5. **Sinhala:** Qwen3-ASR-Sinhala (MLX) recommended default. **English is the default language.** Language and model selection is bidirectional (ADR-008).
6. **Distribution:** direct, non-sandboxed, Sparkle 2 with auto-updates (ADR-005). No Mac App Store.
7. **Models:** downloadable and manageable in Settings; selecting a not-yet-downloaded model triggers an in-place download with visible progress, then proceeds; users can delete/manage/import models.
8. **Scope:** everything in the brief is in v1, including Teams and video recording. Meeting capture **asks first by default**; users can switch to automatic transcribe / transcribe+record in Settings (per app).
9. **Test hardware:** only this M3 Pro 18 GB Mac; M1 / 8 GB behaviour stays extrapolated. Teams is not installed here: Teams detection is unverified until the free Teams client is installed (see `/specs/qa/manual.md`).
10. **Test data:** public datasets only (see `/fixtures/MANIFEST.md`); no user recordings.

**Status: FROZEN** (changes require an SCR in `/specs/changes/`).
