# 02 — Engines & Model Manager (ENG)

Status: DRAFT (Phase 4). Owners: Transcription, Models packages. Sources: ADR-004, ADR-007, ADR-008, `specs/research/asr-engines.md`, `benchmarks.md`, `sinhala-asr.md`; brief §5.4.

## Scope
`TranscriptionEngine` adapters (Apple SpeechAnalyzer, WhisperKit, Qwen3-ASR-Sinhala via MLX, optional Parakeet), the table-driven `EngineRouter` ("Auto"), and the Model Manager (catalog, on-demand download with progress, pause/resume, checksum, delete, custom import, LRU residency, memory pressure, hardware tiers).

## AppCore dependencies
`TranscriptionEngine`, `TranscriptionOptions`, `TranscriptionEvent`, `EngineRouter`, `RoutingRequest`, `EnginePlan`, `EngineAssignment`, `ModelManaging`, `ModelDescriptor`, `ModelState`, `ModelDownloadEvent`, `DiskUsage`, `HardwareTierProviding`, `HardwareTier`, `LanguageCapabilityTable`, `AppError`.

## Routing table (initial; must be unit-tested per row)
| Languages | Use case | Engine / model (tier16) | Notes |
|---|---|---|---|
| en (and Apple-supported locales) | live, dictation | Apple SpeechAnalyzer | falls back to WhisperKit if locale assets unavailable |
| en / multilingual (non-Sinhala) | file | WhisperKit large-v3-v20240930_626MB | Parakeet v3 optional for 25 European languages |
| si | live, file, dictation | Qwen3-ASR-0.6B-Sinhala 8-bit (MLX), experimental | stock Whisper turbo never routed for Sinhala |
| tier8 | any | smaller/quantized models, one heavy model resident | |
| model explicitly chosen | any | the chosen model if it covers the languages, else error `unsupportedLanguage` | |

## Acceptance criteria
| ID | Criterion | Test |
|---|---|---|
| ENG-AC-01 | WHEN "Auto (recommended)" is selected THE SYSTEM SHALL produce an `EnginePlan` solely from `RoutingRequest` (pure, no I/O), matching the routing table for every row. | unit |
| ENG-AC-02 | WHEN the routed model is not installed THE SYSTEM SHALL mark the assignment `requiresDownload` and the UI SHALL offer to download it. | unit |
| ENG-AC-03 | WHEN the user selects a model that is not downloaded THE SYSTEM SHALL call `ensureAvailable`, show inline progress (fraction, bytes, ETA) and continue the job automatically on completion. | integration / UI |
| ENG-AC-04 | WHEN a download is paused, cancelled, or the network drops THE SYSTEM SHALL keep partial data for resume (pause/drop) or remove it (cancel) and show a retry action. | integration |
| ENG-AC-05 | WHEN a download finishes THE SYSTEM SHALL verify the checksum and, on mismatch, delete the file and throw `AppError.checksumMismatch`. | unit |
| ENG-AC-06 | WHEN the user deletes a model in Settings → Models THE SYSTEM SHALL remove its files, update disk usage, and warn if it is the active default. | UI |
| ENG-AC-07 | WHEN the user imports a custom WhisperKit CoreML folder THE SYSTEM SHALL validate it, register a `ModelDescriptor` (`isCustom`) with chosen languages, and list it in the picker. | integration |
| ENG-AC-08 | WHEN the model list is shown THE SYSTEM SHALL display size, languages, speed/accuracy notes, licence (flagging CC-BY-NC) and experimental status per model. | UI |
| ENG-AC-09 | WHEN an engine throws THE SYSTEM SHALL map it to `AppError.engineFailure`, fail only that job with retry, and keep the app running. | unit (mock) |
| ENG-AC-10 | WHEN memory pressure is signalled THE SYSTEM SHALL unload the least-recently-used idle model within 2 s. | integration |
| ENG-AC-11 | WHEN `tier8` is detected THE SYSTEM SHALL keep at most one heavy model resident and serialize engine loading. | unit / integration |
| ENG-AC-12 | WHEN the app idles in the menu bar with no model loaded THE SYSTEM SHALL use < 150 MB RAM and < 1 % CPU. | perf |
| ENG-AC-13 | WHEN "prewarm on launch" is enabled THE SYSTEM SHALL load the selected live model in the background without blocking UI. | integration |
| ENG-AC-14 | WHEN the app makes network requests THE SYSTEM SHALL contact only allow-listed model hosts and only after a user-initiated download. | unit / manual |
| ENG-AC-15 | WHEN a file is transcribed with WhisperKit turbo on M1 Pro-class hardware THE SYSTEM SHOULD reach ≥ 10× real-time (measured 13–17× on M3 Pro). | perf |
| ENG-AC-16 | WHEN a live session starts THE SYSTEM SHALL emit the first partial in < 600 ms (Apple) or < 1.5 s (WhisperKit). | perf / manual |
| ENG-AC-17 | WHEN a job is cancelled THE SYSTEM SHALL stop the engine task within 1 s and release its buffers. | integration |
| ENG-AC-18 | WHEN a model's `minTier` exceeds the current tier THE SYSTEM SHALL warn before download/use. | unit |

## Edge cases
Download interrupted by sleep; disk full; HF host unreachable; partially imported folder; model deleted while loaded; two jobs needing different heavy models on tier8; first load after download is slow (115 s observed for turbo CoreML specialization: show "Optimizing model" state); Apple locale assets missing offline.

## Non-functional
Warm model load ≈ 1 s (turbo); first partial targets above; RAM tiers per ADR-007; no timers while idle.

## Unverified pending user run
Live latency end-to-end (needs mic); behaviour on macOS 26 locale list; MLX Qwen engine in Swift (Python reference only measured: 8.4× RTF, ~2.3 GB); Parakeet not run; M1/8 GB numbers are extrapolations.
