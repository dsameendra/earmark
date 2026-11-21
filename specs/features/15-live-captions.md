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

## Edge cases
Multi-display hot-plug (saved display absent → primary), notch/menu bar safe area, very long unpunctuated speech (rolling window), Sinhala shaping/line breaking in the overlay (CoreText), mixed Sinhala+English lines, source switch mid-session.

## NFR
Overlay render < 4 ms per update; idle (no speech) CPU < 2 %; overlay memory < 40 MB; no main-actor blocking > 8 ms; bounded `bufferingNewest` streams.

## Test notes
Unit: line state machine (volatile→final), preset codec, snap math, per-display store. Integration: `MockAudioSource`+`MockTranscriptionEngine`. Permission-gated parts (taps, mic) are manual per `specs/qa/manual.md` (unverified until run).
