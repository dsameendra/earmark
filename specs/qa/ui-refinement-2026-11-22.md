# UI refinement validation — 2026-11-22

This pass follows the owner's real-app review of the earlier M8 build. Scope is authorized by [SCR-007](../changes/SCR-007-cohesive-ui-refinement.md). The local final-v1 Main, Icons, Home, Live, Settings, Onboarding, States, Motion and Responsive boards are the reference; the private Claude artifact was not independently accessible during this pass.

## Delivered changes

- Full-width painted workspace surfaces and adaptive Home cards/columns, queue rows and Live panes. Native toolbar items replace the overlapping Live control stack. Explicit split-view viewport bounds prevent fixed headers from extending under window controls or navigation from claiming an oversized scroll area.
- A grouped vertical Settings navigator with all fifteen sections, keyboard selection and automatic scrolling. Native window surfaces use the app's paper colour. Onboarding retains its five steps, with titleless, edge-filling artwork; explicit reopening is available only in Settings and Help, including exclusion from the dynamic Window list.
- Resting queue states show truthful status instead of indeterminate loading. Remove, Clear Finished and confirmed Clear Queue cancel/join work where necessary, persist removal before publishing success, retain failed rows on storage errors, and preserve library transcripts/media.
- Shared playback shortcuts in docked and detached windows: Space/K toggle playback, arrows skip five seconds, Shift/Option arrows and J/L skip fifteen seconds. Editable text and native menus retain their own keys; modal sheets suppress transport shortcuts.
- One native title/text search on Library screens, anchored Quick Open elsewhere, and outside-click dismissal. Search, Find and Replace have distinct duotone symbols with system fallbacks. The custom set now has 27 symbols.
- Dynamic, hardware-aware file-model status; catalog-backed language controls preserving regional/multilingual selections; saved file import defaults matching the displayed preferences. Onboarding and demo copy treat supported languages consistently.
- Structured menu-bar status, capture actions, input controls and navigation. State follows actual live, dictation and meeting capture services. No microphone is required to choose system audio.
- Correct triangular 28% icon curl and exact three-stop Ember tile in Icon Composer; six appearance families regenerated. Shared entrance/exit transitions, sidebar glide, drop-target feedback, completion settling and new-item tint have reduced-motion variants and no idle loops.

## Validation

Host: Apple silicon, macOS 27.2.1, Xcode 27.2. Deployment remains macOS 26; this is not evidence of a run on macOS 26.

Features: 323 tests passed in 39 suites in the serial verification run. Playback p95 was below 100 ms for WAV, AAC and H.264 fixtures. Earlier concurrent compiler/UI load caused the existing latency thresholds to fail; thresholds were not relaxed. Jobs: 42 tests passed in seven suites, including durable removal, cancellation cleanup, persistence-error retry and the available local Whisper integration. DesignSystem: 72 tests passed, including all 54 light/dark symbol raster cases, contrast and glass policy checks.

`check-brand.py` verifies curl geometry directly against Main, exact gradient stops and native layer order. `check-dependencies.py` verifies the 18-package graph. Changed app/package/UI-test Swift files pass scoped SwiftLint. Repository-wide lint still reports pre-existing violations outside this change, including long fixture/generator tables; this pass does not claim the entire repository is lint-clean.

The full ten-flow UI run passed with zero failures (`/tmp/earmark-polish-ui-9.xcresult`). Final sidebar compositing and native-chrome cleanup passed the three-flow follow-up (`/tmp/earmark-polish-ui-10.xcresult`); the remaining seven flows, with additional pixel checks for every sidebar label after route changes, passed in `/tmp/earmark-polish-ui-11.xcresult`. Both follow-up runs had zero failures and cover the complete ten-flow suite against implementation `b17595c`. Screenshots wait for the specified M8 entrance duration before capture, so they represent resting layouts.

Coverage includes all six main screens in light/dark, 1720 × 970 expanded workspaces, 960 × 600 editor layout, non-overlapping Live controls, search-button minimum height and separation, whole-window empty-state painting, all fifteen Settings sections with keyboard scrolling, all five onboarding steps, Window-menu exclusion, actual menu-bar panel opening, outside-click search dismissal, queue clearing without library loss, docked/detached playback keys, and reduced motion/transparency/increased contrast policy rendering. The [screenshot gallery](../design/m8-shots/polish/README.md) contains fifty captures and per-image result provenance.

The QA host has a separate bundle identity and in-memory services, a silent local playback fixture and deterministic queue states. It does not access the user's library, download models or request capture permissions. Visual review caught and corrected titlebar underlap and missing sidebar label painting that ordinary existence assertions did not detect. The final Settings surface has no contrasting preferences-toolbar strip; onboarding's Ember panel reaches both window edges.

The real-services Debug app builds with signing disabled. This is a development build for local testing, not a signed distribution artifact.

## Acceptance boundary

The earlier package/native/release-tooling checks are retained in [the handover record](completion-2026-11-22.md). This pass does not re-establish real Zoom/Teams recording, TCC denial/retry, microphone/system-audio hot-plug, dictation insertion, VoiceOver speech output, or target-hardware glass/memory profiling. Those remain explicit checks in [manual.md](manual.md). Real-model accuracy is unchanged by this UI pass. Developer ID signing, notarization, Gatekeeper and update installation remain gated by [release.md](release.md).
