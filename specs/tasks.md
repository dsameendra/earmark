# Task Plan (Phase 5) — DAG with owners, deps, Definition of Done

Status: FROZEN at Phase 5 gate. Milestones follow the brief (M1–M7). All tasks code against frozen AppCore contracts (`/specs/02-contracts.md`) and use `AppCoreTesting` mocks until real implementations land.

**Definition of Done (every task):** compiles under Swift 6 strict concurrency with zero warnings; unit tests pass; AC IDs covered are listed in the PR; swiftlint + swift-format clean; public API has DocC comments; code reviewer approves (HIG reviewer too for UI); merged to `main` only via orchestrator review with full `swift test` + `xcodebuild` run.

**Isolation:** each task touches only its owned package + tests. Cross-package changes go through an SCR.

## M1 Foundation
| ID | Task | Owner | Deps | Covers |
|---|---|---|---|---|
| T01 | Xcode project via XcodeGen (`project.yml`), thin app target, local-package wiring, entitlements/Info.plist keys, ad-hoc signing config | Orchestrator | — | PROD |
| T02 | `Persistence`: GRDB schema, migrator, repositories, FTS5 (Sinhala tokenization test), soft delete + purge, perf test (5,000 transcripts <500 ms) | Persistence eng | T01 | LIB, EDIT, IGN, FR, SET |
| T03 | `DesignSystem`: Liquid Glass components, glass→solid fallbacks, typography, colors, Sinhala font fallback | UI eng 1 | T01 | NAV, PROD-AC-04/05 |
| T04 | HIG/UX wireframes for every screen (`/specs/design/`) | HIG reviewer | — | all UI |
| T05 | App shell + sidebar + MenuBarExtra skeleton + DI composition root | UI eng 1 | T03, T04, mocks | NAV, MENU |
| T06 | `Models` package: catalog, download manager (pause/resume, checksum), delete, import, disk usage, LRU/memory pressure, `HardwareTierProvider` | Models eng | T01 | ENG |
| T07 | CI-style local script: build + test + lint + dependency-direction check | Test eng | T01 | — |

## M2 File transcription
| T08 | `AudioCapture`: AVAssetReader file decoder → 16 kHz mono Float32, bounded memory; VAD | Audio eng | T01 | FILE, AUD |
| T09 | `Transcription`: WhisperKit engine, Apple SpeechAnalyzer engine, `EngineRouter` (table tests), chunking + checkpoints | ASR eng | T06, T08 | ENG, LANG, FILE |
| T10 | `JobQueue` actor: persistence, resume, priorities, concurrency, battery/thermal policy, auto-export hook | ASR eng | T02, T09 | FILE |
| T11 | Home, Queue, Library views | UI eng 1 | T05, T02, T10 | NAV, FILE, LIB |
| T12 | Transcript editor + AVKit player (click-to-seek, karaoke, edit, undo/redo, bookmarks, waveform) | UI eng 2 | T05, T02 | EDIT |
| T13 | Settings: Models manager UI incl. inline download progress when selecting an undownloaded model, language/model linked pickers (ADR-008) | UI eng 2 | T06, T05 | SET, ENG, LANG |

## M3 Processing & export
| T14 | `Processing`: ignore filter (+hallucination gate), replacements, formatting; Settings UIs | Export eng | T02 | IGN, FR |
| T15 | `Export`: all exporters, golden files, presets, batch/zip/watch folder | Export eng | T02 | EXP |
| T16 | In-transcript find/replace UI | UI eng 2 | T12, T14 | FR |

## M4 Live & dictation
| T17 | `AudioCapture`: mic, device hot-plug, process tap (+SCK fallback), silent-denial detection, ring buffer | Audio eng | T08 | AUD |
| T18 | `LiveCaptions`: NSPanel overlay, presets, per-display memory, click-through; live session orchestrator (App) | Overlay eng | T09, T17 | LIVE |
| T19 | `Dictation`: hotkeys, HUD, insertion (paste + AX), history, permissions flow | Overlay eng | T09, T17 | DICT |
| T20 | `PermissionsService` + Privacy & Permissions UI | UI eng 2 | T05 | SET, ONB |
| T21 | Live view + menu bar actions + mini preview | UI eng 1 | T18 | LIVE, MENU |

## M5 Meetings
| T22 | `Diarization`: FluidAudio offline + LS-EEND live + Sortformer fallback + SpeakerKit adapter; voice profiles | Diarization eng | T08 | DIA |
| T23 | `Meetings`: detector, policies (ask-first default), recorder (tracks + mix + video), finalization pass | Meetings eng | T17, T22, T09 | MTG |
| T24 | Meetings view + notification prompts + consent notice + speaker editing UI | UI eng 1 | T23 | MTG, DIA |

## M6 Languages & translation
| T25 | Multilingual per-segment LID routing; Qwen3-ASR Sinhala MLX engine (mlx-audio-swift pinned); re-transcribe segment | ASR eng | T09 | LANG |
| T26 | `Translation`: Apple Translation + NLLB (non-commercial) engines, router, parallel track UI hooks | Translation eng | T06 | TRN |

## M7 Polish & release
| T27 | Onboarding | UI eng 2 | T13, T20 | ONB |
| T28 | Perf pass vs targets (serial benchmarks), accessibility audit, HIG review | Test eng + HIG | all | NFR |
| T29 | Sparkle 2 integration (EdDSA key generated at release, never committed), signing/notarization **(needs Apple Developer Program)**, docs | Orchestrator | T28 | PROD |
| T30 | XCUITest flows + manual QA scripts (`/specs/qa/manual.md`) | Test eng | M2+ | all |

## Critical path
T01 → T06/T08 → T09 → T10 → T11/T12 → (T14/T15) → T17 → T18/T19 → T22 → T23 → T25/T26 → T28 → T29.

## Risks tracked
Permission-gated paths unverified (taps, hot-plug, AX); Teams unavailable on dev Mac; ad-hoc signing re-prompts (recommend Personal Team before T17); MLX second runtime pinning; NLLB/MADLAD Swift runtime open; live DER numbers optimistic (easy headset audio).
