# Task Plan (Phase 5) — DAG with owners, deps, Definition of Done

Status: FROZEN at Phase 5 gate. Milestones follow the brief (M1–M7), plus M8 UI/UX overhaul (runs BEFORE M7; reordered 2026-11-22 by user decision: brand and final UI ship in the first release). All tasks code against frozen AppCore contracts (`/specs/02-contracts.md`) and use `AppCoreTesting` mocks until real implementations land.

**Definition of Done (every task):** compiles under Swift 6 strict concurrency with zero warnings; unit tests pass; AC IDs covered are listed in the PR; swiftlint + swift-format clean; public API has DocC comments; code reviewer approves (HIG reviewer too for UI); merged to `main` only via orchestrator review with full `swift test` + `xcodebuild` run.

**Isolation:** each task touches only its owned package + tests. Cross-package changes go through an SCR.

## Execution record (Codex handover, 2026-11-22)

The subsequent real-app refinement pass is tracked in [SCR-007](changes/SCR-007-cohesive-ui-refinement.md) and [its QA record](qa/ui-refinement-2026-11-22.md). It supersedes the older toolbar-tab Settings layout and global workspace cap, adds queue removal and shared playback shortcuts, corrects icon geometry, and expands visual checks to compact/expanded windows, menu-bar controls and accessibility fallbacks. The historical implementation and test counts below describe the earlier handover build; use the refinement record for the current UI.

The owner approved completion of M8 followed by M7, recovery of interrupted T34, correction of the identified feature gaps, and a bundled CTranslate2/SentencePiece runtime for ADR-009. The local final-v1 boards remain authoritative; the private canvas could not be independently fetched during handover.

- Preserved pre-handover `main` as `backup/pre-codex-handover`; an external snapshot contains the Git bundle, complete T34 edits, untracked files and the duplicate remote-ref file. The original Claude worktree is retained.
- T31/T32/T33 and Features subscription-wait fixes were on local `main`, ten commits ahead of the verified remote. T34 was uncommitted in `agent-af4277854b2ef2466` and is recovered on `codex/complete-m8-release`.
- Handover baseline: committed DesignSystem 64 tests, Features 271; recovered T34 DesignSystem 71, Features 291. Committed app Debug build passed without signing. These are not real capture/permission or visual acceptance results.
- The original generated Xcode project stalls in file coordination; a temporary generated-project copy referencing the same sources builds. Developer ID distribution is pending; two Apple Development identities are available.
- T34 recovery is integrated with the M8 implementation: responsive shell and inspector; Workbench Home, Queue and Library; solid Editor/inspector with floating transport; Meetings/Live/floating surfaces; toolbar Settings; five-step Onboarding and Export preview. Motion/token/icon changes are implemented. Review fixes preserve visible missing-media state and video resizing, react to model changes, release failed microphone preview capture and honour Reduce Motion. SCR-005 records the approved behaviour/integration additions.
- M8 **implementation is complete; acceptance is pending**. T35-T38 still need reviewed light/dark screenshots against the local boards. T39/T40 need real Reduce Motion/Transparency/Increase Contrast, VoiceOver, large-text and Sinhala shaping checks, plus glass/scroll profiling on target hardware. No screen or audit task meets its full Definition of Done merely because source or unit tests pass.
- ADR-009 is implemented: the bundled arm64 macOS 26+ CTranslate2/SentencePiece helper replaces the interpreter requirement. Model weights remain separate downloads; Python is a Debug development/reference override only. Native token/translation parity and cancellation/restart checks exist and require explicit real-model inputs; see `NativeRuntime/README.md`.
- M7 implementation includes Sparkle configuration/opt-in controls, dependency-direction checks, serial package checks, deterministic mock XCUITests, notices, nested signing and app/DMG verification tooling. Developer ID/notarization, the real HTTPS feed and Ed25519 key, update installation and public distribution remain gated. `specs/qa/release.md` describes the inputs and boundaries.
- Current validation: all 18 serial package suites passed (1,063 reported tests; real-model-only tests require their explicit environment). The final DesignSystem recheck passed 72 tests, including all 25 symbols in both appearances. Native parity with the real NLLB model and native-worker cancellation/restart passed separately. All four final mock XCUITests passed with zero failures; 29 window screenshots and [the validation record](qa/completion-2026-11-22.md) are saved. A real-services development build has been opened for manual review; this does not establish permission-gated hardware or screenshot acceptance. Implementation commit: `c2f0792`; the final real-services app build is performed from the updated `main` after the validation commit.
- Use `scripts/project.sh` for the cache-hosted generated project and `scripts/check.sh unit`, `build`, `ui` for repeatable checks. `Config/Package.resolved` pins the reviewed Xcode graph. The user approved committing/pushing verified completion work to `main`, then building/running for testing; publication/signing credentials are not implied by that approval.

## Design alignment for tasks before M8 (non-blocking; read before starting any UI task)
The final UI/UX and brand design exists (`/specs/design/m8-mockups/`, index `README.md`, gallery `index.html`; locked decisions `/specs/design/m8-ui-overhaul.md`; build guide `/specs/design/m8-handoff.md`) and is implemented last, in M8 (T31-T40). It is a restyle of the UI layer, so everything built now should make that restyle cheap. M8 relies on, and will not rework, the following. Do not add scope for the overhaul in M2-M7; just follow these rules.
**Rules for all UI code written before M8**
- A1 Use `DesignSystem` tokens and components only (`DSColor`, `DSSpacing`, `DSRadius`, `DSTypography`, `StatusPill`, `LanguageBadge`, `ProgressRow`, `EmptyState`, `ErrorState`, `Skeleton`, `SpeakerChip`, `RecordingIndicator`). No literal colours or fixed font sizes. M8 changes their internals and values, not their names, so call sites need no edits.
- A2 No new `GlassCard`/`GlassPanel` on content. Use `DSColor.contentBackground` surfaces. Glass only for the sidebar, toolbar controls, and one transient floater (player dock, overlay, HUD, prompt, popover). The two existing `GlassCard` uses in `FeatureHome/HomeView.swift` are migrated in T35.
- A3 Symbols: give every symbol name to the view through a model/enum property (as `AppSection.systemImage` does), never as an inline string in a view body. T33 introduces `DSSymbol` and swaps the glyphs it covers with a mechanical codemod; generic chrome glyphs (chevrons, xmark, checkmark, ellipsis) stay stock SF Symbols.
- A4 Accent only through `DSColor.accent`; recording only through `DSColor.recording`/`RecordingIndicator`; destructive through `DSColor.danger`. M8 sets the accent to Ember and never reuses it for recording or errors.
- A5 Toolbars use `ToolbarItem`/`ToolbarItemGroup` (they float as glass natively on macOS 26). No custom full-width bars.
- A6 Give every interactive control a stable `accessibilityIdentifier` (none exist yet). T30 XCUITests and the M8 snapshot tests key on identifiers, so M8 can restyle without touching tests.
- A7 Keep behaviour in models and layout in views; do not encode appearance in models. M8 changes views only.
- A8 Follow the mockup for new surfaces so M8 only restyles them (table below).
**Per-task pointers (mockup boards are in `m8-mockups/static/<Board>.html`)**
| Task | Follow these boards now | Note |
|------|--------------------------|------|
| T16 find/replace UI | Components | `FindBarView` exists in `FeatureEditor`; match the solid capsule bar under the toolbar, Ember tint matches |
| T18 live overlay | Floating, Components (presets) | Click-through non-activating NSPanel; presets change size, lines (1-3), opacity; build the structure now, M8 restyles |
| T19 dictation HUD | Floating | Capsule with listening bars and "Release Fn to insert"; recording red, never Ember |
| T20 permissions UI | SettingsTabs (Privacy), Flow (step 3) | Rows with status chip and a System Settings link; denied never blocks the app |
| T21 Live view, menu bar | Live, Floating (popover) | `FeatureMenuBar/MenuBarContentView.swift` already exists; keep its structure |
| T24 Meetings, prompts, consent | Meetings, Floating (prompt), Flow (step 5 consent) | Detection banner is solid and inline; consent shown once |
| T25/T26 translation UI hooks | Components (translation views) | Original / Translated / Bilingual segmented control in the Editor toolbar group; see `FeatureEditor/ViewOptions.swift` |
| T27 Onboarding | Flow (all 5 steps), Onboarding | Build the five-step structure and copy now; T38 then restyles only |
| T28 perf and a11y audit | Handoff1 (tokens), Responsive | Record baseline perf numbers and a contrast report; T40 diffs against them |
| T29 release | Main (icon), Handoff2 (asset spec) | Needs the T32 icon, AccentColor and menu bar glyph; ship a placeholder icon if cut before M8. There is no asset catalog in the project today. |
**Already built (M2) that M8 restyles in place:** shell (`FeatureShell/ShellView.swift`, `AppSection.swift`), Home/Queue/Library, Editor and player, Settings and Models, menu bar. Keep their public interfaces stable; tests that render views (`FeaturesTests/EditorRenderTests.swift`, `ImageRenderer` based) assert on content, so expect only snapshot-style updates in T36/T40.

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


## Onboarding build (moved out of M7, precedes M8)
| ID | Task | Owner | Deps | Covers |
|---|---|---|---|---|
| T27 | Onboarding | UI eng 2 | T13, T20 | ONB |

## M8 UI/UX overhaul and visual identity (runs after M6 and the onboarding build T27, before M7)
**KICKOFF GATE (mandatory, before T31): ask the user for the Claude Design canvas link.** The final design lives in a Claude Design canvas: https://claude.ai/artifact/FzAtjj7ZdYAkp1WHPeFSVF (final v1, published version id `1795296776-319f`; private to the user, so access must be re-confirmed in the session that starts M8). Steps: (1) ask the user for the link and confirm it matches; (2) read it with the Artifact tool (`action: "read"`); (3) compare with the repo copy `/specs/design/m8-mockups/`; if they differ, ask which is authoritative; (4) read `/specs/design/m8-handoff.md` and `/specs/design/m8-ui-overhaul.md` in full; (5) open `/specs/design/m8-mockups/index.html`. Do not start building from memory or from the archive boards.
**Source of truth:** `/specs/design/m8-handoff.md` (how to build it, existing-code map, acceptance criteria), `/specs/design/m8-ui-overhaul.md` (locked decisions), `/specs/design/m8-mockups/` (local copy: `static/` HTML snapshots, `png/` previews, `source/` Claude Design sources, `archive/` rejected options never to be reintroduced; `README.md` has the full board index). Constraint on every task: Apple HIG for macOS 26, glass budget of three layers per screen, Reduce Transparency / Reduce Motion / Increase Contrast honoured, UI layer only (behaviour or contract changes go through an SCR). Each task's Definition of Done is the global DoD plus its acceptance criteria in `m8-handoff.md` section 7, plus side-by-side screenshots against the matching mockup in both appearances.
**Reuse, do not rework:** component names (`StatusPill`, `LanguageBadge`, `ProgressRow`, `EmptyState`, `ErrorState`, `Skeleton`, `SpeakerChip`, `RecordingIndicator`) and token names (`DSColor.*`, `DSSpacing`, `DSRadius`, `DSTypography`) stay; their values and internals change. 227 call sites already use tokens; no view should need more than a style edit. Models, services and tests are untouched.
| ID | Task | Mockups (`m8-mockups/static/`) | Existing code to restyle or extend | Owner | Deps | Covers |
|----|------|-------------------------------|------------------------------------|-------|------|--------|
| T31 | Kickoff gate, then spike (glass APIs, SF Symbols weight matching, Icon Composer) written to `/specs/design/m8-spike.md`; `DesignSystem` v2: Ember/paper/ink/night tokens (+ recording/success/danger), Sheet/Inset solid tiers, glass policy (3-layer budget, Clear/Regular/Prominent + solid twins), New York + SF Pro type scale, motion tokens (settle/glide/exit/reduce); migrate `GlassCard`/`GlassPanel`; retune `SpeakerPalette` only where its contrast tests still pass | Handoff1, Glass, Main | `Packages/DesignSystem/Sources/DesignSystem/{Tokens,GlassPolicy,Components,SpeakerPalette,SinhalaFont}.swift`; `HomeView.swift` (2 GlassCard uses) | UI eng 1 | T26, T27 | NAV, PROD-AC-04 |
| T32 | Brand assets: Icon Composer app icon (squircle, ear, arc, 28% curl, ear offset left 2.5%, default/dark/tinted/clear), menu bar template glyph (idle, recording), AccentColor asset, About/DMG art | Main, Handoff2 | New: no asset catalog exists; add to `project.yml`; `App/EarmarkApp.swift` (menu bar item label) | Brand/UI eng | T31 | PROD |
| T33 | `DSSymbol` seam plus custom duotone symbol set (24 in the mockups plus the ear glyph) on the SF Symbols template, Ultralight-Black, 3 scales, palette/hierarchical rendering, accessibility labels, stock fallbacks; codemod of the covered glyphs (about 143 `systemImage`/`systemName` uses today, only the 24 covered glyphs change); weight-match review gate | Icons | `FeatureShell/AppSection.swift` and the `systemImage:` call sites in Library, Settings, Queue, MenuBar, Home, Editor | Brand/UI eng | T31 | NAV |
| T34 | App shell: glass sidebar (system material, custom rows), floating toolbar groups (no full-width bar), window chrome, selection glide, min window size and responsive behaviours | Sidebar, Responsive, Glass | `FeatureShell/{ShellView,AppSection,QuickOpen}.swift`; `FeatureSupport/Placeholders.swift` | UI eng 1 | T31, T33 | NAV |
| T35 | Home (Workbench layout), Queue, Library restyle; Recently Deleted, empty, error and loading states | Home, Queue, Library, States | `FeatureHome/HomeView.swift` (QuickActionButton), `FeatureQueue/{QueueView,BatchSettingsSheet}.swift`, `FeatureLibrary/{LibraryView,LibraryItemViews,LibraryFilterBar}.swift` | UI eng 1 | T34 | NAV, FILE, LIB |
| T36 | Editor + player restyle (light and dark), floating player dock, speakers/earmarks/hidden inspector, karaoke highlight, find/replace bar, speaker popover, translation view control | Editor, Components | `FeatureEditor/{TranscriptEditorView,TranscriptListView,PlayerViews,Waveform,FindBarView,EditorPanels,ViewOptions}.swift` | UI eng 2 | T34 | EDIT, FR, DIA |
| T37 | Meetings, Live view, floating surfaces (menu bar popover, live overlay, dictation HUD, meeting prompt) restyle | Meetings, Live, Floating, Components (presets) | `FeatureMeetings/MeetingsView.swift`, `FeatureLive/LiveView.swift`, `FeatureMenuBar/MenuBarContentView.swift`; overlay and HUD panels from T18/T19 | UI eng 2 | T34 | MTG, LIVE, DICT, MENU |
| T38 | Settings (toolbar tabs) with Models, General, Privacy and the other tabs; Onboarding (all 5 steps); Export sheet restyle | Settings, SettingsTabs, Onboarding, Flow, Export | `FeatureSettings/{SettingsRootView,SettingsSection,ModelsViews,PreferenceViews,RulesViews,ShortcutsView}.swift`; export UI in `FeatureEditor` (`EditorExportModel`); onboarding from T27 | UI eng 1 | T34 | SET, ONB, EXP |
| T39 | Motion pass per the motion spec; Reduce Motion crossfade variants | Motion, Glass | All feature views; `DSMotion` from T31 | UI eng 2 | T35-T38 | NAV |
| T40 | Final HIG + accessibility audit (contrast AA both appearances, Increase Contrast, Reduce Transparency, VoiceOver, Dynamic Type), snapshot tests, glass-cost profiling | all | `FeaturesTests/EditorRenderTests.swift` and new snapshot tests | Test eng + HIG | T39 | NFR |

Release note: M7 (T28 perf and a11y baseline, T29 Sparkle/signing/notarization, T30 XCUITest and manual QA) now runs after T40 and uses the T32 assets; there is no placeholder-icon release. The `m8-mockups` note that T28 records a baseline for T40 to diff against is superseded: T40 captures before/after itself, T28 then audits the final UI.

## M7 Polish & release (runs AFTER M8: T28 baseline and audit, T29 release, T30 QA all run against the final UI)
| T28 | Perf pass vs targets (serial benchmarks), accessibility audit, HIG review | Test eng + HIG | all | NFR |
| T29 | Sparkle 2 integration (EdDSA key generated at release, never committed), signing/notarization **(needs Apple Developer Program)**, docs | Orchestrator | T28 | PROD |
| T30 | XCUITest flows + manual QA scripts (`/specs/qa/manual.md`) | Test eng | M2+ | all |

## Critical path
T01 → T06/T08 → T09 → T10 → T11/T12 → (T14/T15) → T17 → T18/T19 → T22 → T23 → T25/T26 → T27 → T31 → T34 → T35/T36/T37/T38 → T39 → T40 → (M7) T28 → T29 → T30.

## Risks tracked
Permission-gated paths unverified (taps, hot-plug, AX); Teams unavailable on dev Mac; ad-hoc signing re-prompts (recommend Personal Team before T17); MLX second runtime pinning; native NLLB packaged-app/hardware QA pending; live DER numbers optimistic (easy headset audio).
