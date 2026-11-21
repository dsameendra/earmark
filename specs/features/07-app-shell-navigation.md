# 07 — App Shell & Navigation (NAV)
Status: Draft (Phase 4). Owner: UI engineers. Depends on: 00-product, 01-architecture, 02-contracts.

## Scope
`NavigationSplitView` with Liquid Glass sidebar; sections Home, Queue, Meetings, Live, Library, Recently Deleted; Settings is a separate scene. Global search (⌘F in transcript, ⌘K quick open). Keyboard navigation, VoiceOver, Dynamic Type-friendly layouts, Reduce Transparency / Increase Contrast / Reduce Motion.

## AppCore protocols used
`JobQueue`, `TranscriptRepository`, `MeetingRepository`, `ModelManaging`, `LiveSessionControlling`, `MeetingDetector`, `HardwareTierProviding`, `PermissionsServicing`, `SettingsStore`.

## Screens
- **Home:** quick actions (Transcribe File, Start Live Captions, Start Meeting Capture, Dictation status), drop zone, recent transcripts, active-jobs summary, model status.
- **Queue:** pending/running/paused/failed jobs; progress, ETA, engine, language; reorder; pause/resume/cancel/retry; concurrency setting.
- **Meetings:** detected/recorded meetings, auto-record status, per-meeting transcript + recordings, Zoom/Teams badges.
- **Live:** full-size live transcript mirroring the overlay; start/stop; source selection (Mic / System / App / Mic+System).
- **Library / Recently Deleted:** see 10-library.

## Acceptance criteria (EARS)
- NAV-AC-01 (UI) WHEN the app launches THE SYSTEM SHALL show the main window with the sidebar listing Home, Queue, Meetings, Live, Library and Recently Deleted, with Home selected on first launch and the last-used section thereafter.
- NAV-AC-02 (UI) WHEN the user presses ⌘1…⌘6 THE SYSTEM SHALL select the corresponding sidebar section.
- NAV-AC-03 (UI) WHEN the user presses ⌘K THE SYSTEM SHALL open a quick-open palette that searches transcript titles and full text across the library and opens the chosen result on Return.
- NAV-AC-04 (UI) WHEN the user presses ⌘F in a transcript THE SYSTEM SHALL focus the in-transcript find bar (see 11-editor-player).
- NAV-AC-05 (UI) WHEN the user drops audio/video files or folders on the Home drop zone or the main window THE SYSTEM SHALL enqueue them via `JobQueue.enqueue(files:settings:recursive:)` and navigate to Queue (see 09).
- NAV-AC-06 (UI) WHEN a job is running THE SYSTEM SHALL show an active-jobs summary on Home with aggregate progress that updates at least once per second.
- NAV-AC-07 (UI) WHEN the selected model for a quick action is not installed THE SYSTEM SHALL start `ModelManaging.ensureAvailable` and show inline download progress, then continue the action on completion (ADR-008).
- NAV-AC-08 (UI) WHEN Home has no transcripts THE SYSTEM SHALL show an empty state with "Transcribe a file" and "Start live captions" actions.
- NAV-AC-09 (UI) WHEN Reduce Transparency or Increase Contrast is enabled THE SYSTEM SHALL render sidebar, toolbars and floating controls with solid, higher-contrast backgrounds instead of glass.
- NAV-AC-10 (UI) WHEN Reduce Motion is enabled THE SYSTEM SHALL replace transitions and animated indicators with crossfades or static states.
- NAV-AC-11 (UI/manual) THE SYSTEM SHALL expose a VoiceOver label, role and value for every interactive control, and every sidebar section and list row SHALL be reachable by keyboard alone.
- NAV-AC-12 (UI) WHEN text size increases (Dynamic Type / larger text) THE SYSTEM SHALL reflow without clipped or overlapping controls at the largest size.
- NAV-AC-13 (UI) WHEN the Live section is opened with no session THE SYSTEM SHALL show source selection and a Start button; WHEN a session runs THE SYSTEM SHALL show lines from `LiveSessionControlling.lines()` with volatile text styled distinctly and finalizing in place.
- NAV-AC-14 (UI) WHEN a meeting is detected and the policy is `askFirst` THE SYSTEM SHALL present a notification/prompt with Transcribe, Record and Dismiss actions.
- NAV-AC-15 (unit) WHEN the last-selected section is persisted THE SYSTEM SHALL restore it through `SettingsStore` on next launch.
- NAV-AC-16 (UI) WHEN the main window is closed THE SYSTEM SHALL keep running as a menu bar app if a session or job is active or the user enabled "keep running" (see 08).

## Edge cases
Loading: skeleton rows for Library/Meetings lists. Error: engine/model failure shows an inline banner with Retry; permission denial shows a recovery action linking to System Settings. Empty: each section has an explanatory empty state.

## Non-functional
Section switch < 100 ms; main-actor work never blocks > 16 ms during scrolling; Library of 5,000 items loads < 500 ms; no polling timers while idle.
