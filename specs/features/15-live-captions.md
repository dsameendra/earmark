# 15 — Live Captions overlay (LIVE)
Status: DRAFT (Phase 4) · Owner: Overlay & Dictation engineer · Packages: `LiveCaptions` (+ orchestrator in App)

## Scope
Floating, non-obstructing caption overlay captioning mic, system audio, a specific app, or mic+system; the full-size Live view mirrors it. Customization, presets, volatile text, live speaker labels, optional translation line, optional save as transcript.

## AppCore contracts used
`LiveSessionControlling`, `LiveSessionConfig`, `CaptureSource`, `CaptionLine`, `OverlayControlling`, `CaptionPreset`, `PresetRepository`, `AudioSource` (+`health`), `TranscriptionEngine.stream`, `StreamingDiarizer`/`LiveDiarizationEvent` (`maxLiveSpeakers = 4`), `TranslationEngine`, `TranscriptPostProcessor`, `HotkeyServicing`, `PermissionsServicing`, `EngineRouter`.

## Acceptance criteria (EARS)
- LIVE-AC-01 (UI/M) WHEN live captions start THE SYSTEM SHALL show an `NSPanel` with `.nonactivatingPanel`, floating level, `canJoinAllSpaces` and `fullScreenAuxiliary` that never becomes key or steals focus from the frontmost app.
- LIVE-AC-02 (UI) WHEN click-through is enabled THE SYSTEM SHALL set `ignoresMouseEvents` so clicks pass to underlying windows; the toggle SHALL work via hotkey and via modifier-key hover.
- LIVE-AC-03 (UI) WHEN the user drags or resizes the overlay THE SYSTEM SHALL snap to screen edges within 12 pt and SHALL restore position/size per display (keyed by display ID) on next show.
- LIVE-AC-04 (I) WHEN the source is Mic THE SYSTEM SHALL capture the selected input device; System SHALL capture all system audio; App SHALL capture only that bundle ID; Mic+System SHALL show mixed text or labelled lanes "You"/"Them" per config.
- LIVE-AC-05 (I) WHEN only all-zero buffers arrive for 3 s from a tap THE SYSTEM SHALL report `AppError.captureSilent` and show a permission recovery action.
- LIVE-AC-06 (P) WHEN speech starts with SpeechAnalyzer THE SYSTEM SHALL show the first partial in < 600 ms; with WhisperKit/Qwen in < 1.5 s; finalized text in < 2 s.
- LIVE-AC-07 (U) WHEN a volatile `CaptionLine` is finalized THE SYSTEM SHALL update it in place (same `id`) without reflowing prior lines or visible jitter; volatile text SHALL be styled distinctly (reduced opacity/italic).
- LIVE-AC-08 (UI) WHEN the preset changes THE SYSTEM SHALL apply font family/size/weight, colour, background (Liquid Glass/solid/none), opacity, corner radius, 1–6 lines, max width, alignment, outline/shadow, speaker labels, language badge, translation line (original+translated or translated-only).
- LIVE-AC-09 (U) WHEN silence exceeds `autoHideAfterSilence` THE SYSTEM SHALL fade the overlay out and fade in on next speech; WHEN Reduce Motion is on it SHALL cut instead of animate.
- LIVE-AC-10 (UI) WHEN Reduce Transparency or Increase Contrast is on THE SYSTEM SHALL render glass as solid with high-contrast text.
- LIVE-AC-11 (U) WHEN built-in presets ("Subtle", "Presentation", "High contrast") exist THE SYSTEM SHALL prevent their deletion and allow Save As user presets.
- LIVE-AC-12 (I) WHEN diarization is enabled THE SYSTEM SHALL label lines with provisional speakers (max 4) within ~1.1 s; WHEN more than 4 speakers appear THE SYSTEM SHALL label extras "More speakers" until the offline pass.
- LIVE-AC-13 (I) WHEN a translation target is set THE SYSTEM SHALL show a throttled translation line (best effort, <= 1 update/s); English→Sinhala SHALL display a low-confidence marker.
- LIVE-AC-14 (I) WHEN "Save as transcript" is on and the session stops THE SYSTEM SHALL persist a transcript (`source = .liveCaptions`) and return its `TranscriptID`.
- LIVE-AC-15 (U) WHEN the active input device is unplugged THE SYSTEM SHALL fall back to the system default and post a notification; the session SHALL continue.
- LIVE-AC-16 (U) WHEN an engine throws THE SYSTEM SHALL end the session in `.failed(reason)` with Retry, not crash.
- LIVE-AC-17 (UI) WHEN the Dock is hidden or the main window closed THE SYSTEM SHALL keep the overlay and menu bar controls functional.
- LIVE-AC-18 (UI) WHEN recording/captioning is active THE SYSTEM SHALL display a persistent indicator (menu bar icon + overlay dot).
- LIVE-AC-19 (U) WHEN replacement rules or ignore rules apply THE SYSTEM SHALL run the post-processor chain on finalized lines (ignored lines hidden, not deleted).
- LIVE-AC-20 (M) WHEN the overlay is above a fullscreen app or another Space THE SYSTEM SHALL remain visible.

## Added acceptance criteria: overlay display and position (added 2026-11-22 by user request)
Additive; LIVE-AC-01 to LIVE-AC-20 are unchanged. Packages: `LiveCaptions` (`OverlayLayout.swift`, `CaptionOverlayController`), `FeatureSettings` (Live Captions: Display and Position). Settings keys are listed in `FeatureSupport.SettingsKey` (`liveOverlayDisplayChoice`, `liveOverlayPosition`, `liveOverlayCustomFrame`, `liveClickThrough`).
- LIVE-AC-21 (UI) WHEN the user opens Settings > Live Captions THE SYSTEM SHALL offer "Show captions on" with "Main display", "Follow the active window or mouse" and every connected display by name (duplicate names numbered), SHALL remember the choice across launches, and SHALL place the overlay on that display when captions show.
- LIVE-AC-22 (U) WHEN the chosen display is unplugged (or "Follow" has no active display) THE SYSTEM SHALL show the overlay on the main display without losing the saved choice, SHALL move a visible overlay there at once (never saving AppKit's own repositioning as a user drag), and SHALL return to the chosen display when it is plugged in again; WHEN "Follow the active window or mouse" is chosen THE SYSTEM SHALL move a visible overlay to the display of the frontmost other app's window (else the mouse) within about 1 s of a change.
- LIVE-AC-23 (UI) WHEN the user picks a cell of the 3x3 position grid (top/middle/bottom by left/centre/right) THE SYSTEM SHALL place the overlay in that cell of the display's visible frame (below the menu bar and notch area, clear of the Dock), inset 24 pt from the edges (48 pt for the bottom row, matching the previous default), SHALL never place it partly off screen, and SHALL remember the position per display; bottom centre is the default.
- LIVE-AC-24 (UI) WHEN the position is left centre or right centre THE SYSTEM SHALL wrap lines in a narrower column (at most 340 pt, at most 30 % of the display width) and allow twice the visible lines in height; corner positions SHALL use at most half the display width.
- LIVE-AC-25 (UI) WHEN the user drags or resizes the overlay (always possible while click-through is off, or while holding Option) THE SYSTEM SHALL show a drag handle on the overlay, snap to edges within 12 pt (LIVE-AC-03), switch the position to "Custom", persist that frame per display and per caption preset, and make the display it was dropped on the chosen display; a frame saved by an earlier version SHALL still be honoured as Custom.
- LIVE-AC-26 (UI) WHEN the user selects "Reset position" THE SYSTEM SHALL restore bottom centre and forget the dragged frames for the display captions are on.
- LIVE-AC-27 (UI) WHEN any display or position setting changes THE SYSTEM SHALL move the live overlay immediately, or, with no live session, show a test caption (also via "Show test caption") that follows further changes and hides itself after 8 s idle or when leaving the section; a live session SHALL replace the test caption, and a test SHALL never show the recording indicator or hide a live overlay.
- LIVE-AC-28 (UI) WHEN rendered THE SYSTEM SHALL give every control a stable accessibility identifier (`liveCaptions.placement.display`, `.cell.<position>`, `.custom`, `.drag`, `.testCaption`, `.reset`, `.grid`; overlay `liveCaptions.overlay.dragHandle`) and use DesignSystem tokens only.

Tests: `OverlayLayoutTests` (nine positions on primary, negative-origin, above-left, below-left and left-Dock geometries, menu bar and Dock insets, side-column sizing, unplug fallback, controller placement, per-preset Custom, test caption), `OverlayPlacementSettingsTests` (settings model persistence, per-display positions, reset, key parity). Manual (unverified until run): real multi-display placement, Follow while switching apps across displays, Option-drag onto another display, display hot-plug on hardware.

## Edge cases
Multi-display hot-plug (saved display absent → primary), notch/menu bar safe area, very long unpunctuated speech (rolling window), Sinhala shaping/line breaking in the overlay (CoreText), mixed Sinhala+English lines, source switch mid-session.

## NFR
Overlay render < 4 ms per update; idle (no speech) CPU < 2 %; overlay memory < 40 MB; no main-actor blocking > 8 ms; bounded `bufferingNewest` streams.

## Test notes
Unit: line state machine (volatile→final), preset codec, snap math, per-display store. Integration: `MockAudioSource`+`MockTranscriptionEngine`. Permission-gated parts (taps, mic) are manual per `specs/qa/manual.md` (unverified until run).
