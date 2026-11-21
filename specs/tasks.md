# Task Plan (Phase 5) — DAG with owners, deps, Definition of Done

Status: FROZEN at Phase 5 gate. Milestones follow the brief (M1–M7), plus M8 UI/UX overhaul (appended, runs last). All tasks code against frozen AppCore contracts (`/specs/02-contracts.md`) and use `AppCoreTesting` mocks until real implementations land.

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

## M8 UI/UX overhaul and visual identity (last milestone; starts only after M7 is complete)
**KICKOFF GATE (mandatory, before T31): ask the user for the Claude Design canvas link.** The final design lives in a Claude Design canvas: https://claude.ai/artifact/FzAtjj7ZdYAkp1WHPeFSVF (final v1, published version id `1795296177-4e67`; private to the user, so access must be re-confirmed in the session that starts M8). Steps: (1) ask the user for the link and confirm it matches; (2) read it with the Artifact tool (`action: "read"`); (3) compare with the repo copy `/specs/design/m8-mockups/`; if they differ, ask which is authoritative; (4) read `/specs/design/m8-handoff.md` and `/specs/design/m8-ui-overhaul.md` in full. Do not start building from memory or from the archive boards.
Source of truth: `/specs/design/m8-handoff.md` (how to build it), `/specs/design/m8-ui-overhaul.md` (locked decisions), `/specs/design/m8-mockups/` (canvas sources; `archive/` holds rejected options, never reintroduce them). Constraint on every task: Apple HIG for macOS 26, glass budget of three layers per screen, Reduce Transparency / Reduce Motion / Increase Contrast honoured, UI layer only (behaviour or contract changes go through an SCR). Each task's Definition of Done is the global DoD plus its acceptance criteria in `m8-handoff.md` section 7, plus side-by-side screenshots against the matching mockup artboard in both appearances.
| ID | Task | Owner | Deps | Covers |
|----|------|-------|------|--------|
| T31 | Kickoff gate, then spike (glass APIs, SF Symbols weight matching, Icon Composer) written to `/specs/design/m8-spike.md`; `DesignSystem` v2: Ember/paper/ink/night tokens (+ recording/success/danger, speaker palette), Sheet/Inset solid tiers, glass policy (3-layer budget, Clear/Regular/Prominent + solid twins), New York + SF Pro type scale, motion tokens (settle/glide/exit/reduce); migrate `GlassCard`/`GlassPanel` | UI eng 1 | T30 | NAV, PROD-AC-04 |
| T32 | Brand assets: Icon Composer app icon (squircle, ear, arc, 28% curl, ear offset left 2.5%, default/dark/tinted/clear), menu bar template glyph (idle, recording), AccentColor asset, About/DMG art | Brand/UI eng | T31 | PROD |
| T33 | Custom duotone symbol set (24 in the mockups plus the ear glyph) on the SF Symbols template, Ultralight-Black, 3 scales, palette/hierarchical rendering, accessibility labels, stock SF Symbol fallbacks; weight-match review gate | Brand/UI eng | T31 | NAV |
| T34 | App shell: glass sidebar (system material, custom rows), floating toolbar groups (no full-width bar), window chrome, selection glide, min window size behaviours | UI eng 1 | T31, T33 | NAV |
| T35 | Home (Workbench layout), Queue, Library restyle, plus derived Recently Deleted and empty/error states | UI eng 1 | T34 | NAV, FILE, LIB |
| T36 | Editor + player restyle (light and dark), floating player dock, speakers/earmarks/hidden inspector, karaoke highlight, derived find/replace bar and speaker popover | UI eng 2 | T34 | EDIT, FR, DIA |
| T37 | Meetings, Live view, floating surfaces (menu bar popover, live overlay, dictation HUD, meeting prompt) restyle | UI eng 2 | T34 | MTG, LIVE, DICT, MENU |
| T38 | Settings (toolbar tabs) + Models and derived tabs, Onboarding (all 5 steps), Export sheet restyle | UI eng 1 | T34 | SET, ONB, EXP |
| T39 | Motion pass per `m8-mockups/Motion.dc.html`; Reduce Motion crossfade variants | UI eng 2 | T35-T38 | NAV |
| T40 | Final HIG + accessibility audit (contrast AA both appearances, Increase Contrast, Reduce Transparency, VoiceOver, Dynamic Type), re-run T28 perf checks and T30 XCUITests, snapshot tests, glass-cost profiling | Test eng + HIG | T39 | NFR |

Release note: T29 (Sparkle, signing, notarization) can be prepared earlier, but the first public release build is cut after T40.

## Critical path
T01 → T06/T08 → T09 → T10 → T11/T12 → (T14/T15) → T17 → T18/T19 → T22 → T23 → T25/T26 → T28 → T29 → (after M7) T31 → T34 → T35/T36/T37/T38 → T39 → T40.

## Risks tracked
Permission-gated paths unverified (taps, hot-plug, AX); Teams unavailable on dev Mac; ad-hoc signing re-prompts (recommend Personal Team before T17); MLX second runtime pinning; NLLB/MADLAD Swift runtime open; live DER numbers optimistic (easy headset audio).
