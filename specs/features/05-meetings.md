# 05 — Meetings: Zoom and Teams (MTG)

Status: DRAFT (Phase 4). Owner: Meetings package. Sources: `specs/research/capture-meetings.md`, ADR-005, brief §5.7; user sign-off 2026-11-21 (ask-first default; Teams and video in v1).

## Scope
Meeting detection (Zoom, Teams), behaviour policy per app, live meeting view, dual-track capture, recording (separate tracks + mix, optional video), bookmark hotkeys, finalization pass, consent notice, Meetings section.

## AppCore dependencies
`MeetingDetector`, `MeetingEvent`, `MeetingApp`, `MeetingPolicy`, `MeetingBehavior`, `Meeting`, `Recorder`, `RecordingConfig`, `Recording`, `LiveSessionControlling`, `CaptureSource`, `AudioSource`, `StreamingDiarizer`, `Diarizer`, `TranscriptionEngine`, `JobQueue` (`.finalizeMeeting`), `MeetingRepository`, `HotkeyServicing` (`.bookmarkMoment`), `PermissionsServicing`, `SettingsStore`.

## Detection design (research)
Primary signal: the app's own audio process has input **and** output running at once, debounced; device `IsRunningSomewhere` is corroborating only; Accessibility window titles excluded in v1. Zoom bundle `us.zoom.xos` (7.1.9 inspected); Teams `com.microsoft.teams2`.

## Acceptance criteria
| ID | Criterion | Test |
|---|---|---|
| MTG-AC-01 | WHEN a Zoom or Teams meeting becomes active (debounced) THE SYSTEM SHALL emit `MeetingEvent.started` once per meeting. | unit (mock) / manual |
| MTG-AC-02 | WHEN the meeting ends THE SYSTEM SHALL emit `.ended` after the configured grace period without audio activity. | unit / manual |
| MTG-AC-03 | WHEN no policy has been customised THE SYSTEM SHALL use `MeetingBehavior.askFirst` for both apps. | unit |
| MTG-AC-04 | WHEN behaviour is `askFirst` and a meeting starts THE SYSTEM SHALL show a notification "Zoom meeting detected — Transcribe? Record?" with actions. | UI / manual |
| MTG-AC-05 | WHEN behaviour is `autoTranscribe` or `autoTranscribeAndRecord` THE SYSTEM SHALL start without prompting, subject to exclusions, and still show the recording indicator and consent reminder (once). | integration |
| MTG-AC-06 | WHEN the current time is inside quiet hours or a title/keyword exclusion matches THE SYSTEM SHALL NOT auto-start and SHALL fall back to `askFirst`. | unit |
| MTG-AC-07 | WHEN auto-stop is enabled and the meeting ends THE SYSTEM SHALL stop capture after the grace period (default 15 s) and finalize the transcript. | integration |
| MTG-AC-08 | WHEN capture starts THE SYSTEM SHALL record the mic and remote tracks separately and produce a mixed m4a/AAC track in the library. | integration |
| MTG-AC-09 | WHEN video recording is enabled THE SYSTEM SHALL capture the meeting window/screen via ScreenCaptureKit to H.264/HEVC `.mov`, requiring Screen Recording permission only at that moment. | manual |
| MTG-AC-10 | WHEN recording is active THE SYSTEM SHALL show a persistent indicator in the menu bar and live view (animated icon respects Reduce Motion). | UI |
| MTG-AC-11 | WHEN recording is first enabled THE SYSTEM SHALL show a one-time legal/consent notice that the user must inform participants. | UI |
| MTG-AC-12 | WHEN the app crashes or is killed during recording THE SYSTEM SHALL leave playable audio from fragmented writes and the meeting SHALL be recoverable on next launch. | integration / manual |
| MTG-AC-13 | WHEN a live meeting runs THE SYSTEM SHALL show a rolling transcript with speaker labels (mic = "You", remote = provisional Speaker N) and a mini preview in the menu bar. | UI / integration |
| MTG-AC-14 | WHEN the bookmark hotkey is pressed during a meeting THE SYSTEM SHALL add a bookmark at the current time with an optional note. | integration |
| MTG-AC-15 | WHEN the meeting ends and finalization is enabled THE SYSTEM SHALL enqueue a higher-accuracy re-transcription (larger model), then offline diarization, then save under Meetings; the user can edit before and after. | integration |
| MTG-AC-16 | WHEN System Audio Recording permission is denied or silently blocked THE SYSTEM SHALL show recovery steps and continue mic-only capture. | integration / manual |
| MTG-AC-17 | WHEN the user selects "Toggle auto-record" in the menu bar THE SYSTEM SHALL flip the policy for the detected app and show state. | UI |
| MTG-AC-18 | WHEN the meetings list is shown THE SYSTEM SHALL display Zoom/Teams badges, recordings, transcript links and the auto-record status. | UI |
| MTG-AC-19 | WHEN the mic and speakers are used together THE SYSTEM SHALL de-duplicate cross-track text (echo) after transcription and show the headphone hint. | integration |
| MTG-AC-20 | WHEN idle with no meeting THE SYSTEM SHALL use no polling timers for detection (event-driven, coalesced). | perf |

## Edge cases
Two meetings in different apps; muted mic with remote audio only; Zoom helper processes; waiting rooms (no audio); app updates changing helper names; user joins by phone; Bluetooth HFP mic; sleep during meeting.

## Non-functional
Detection latency ≤ 5 s after audio starts; recording continues if transcription engine fails; disk space check before recording; recordings stored in library location.

## Unverified pending user run
All Zoom detection signals during a real call (Zoom not in a call during research); process-tap capture and TCC behaviour; ScreenCaptureKit video; `kill -9` crash safety and whether `.m4a` fragments; **Teams cannot be verified (not installed on dev Mac; install the free client)**.
