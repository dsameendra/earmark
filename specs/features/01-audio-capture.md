# 01 — Audio Capture (AUD)

Status: DRAFT (Phase 4). Owner: AudioCapture package. Sources: `specs/research/capture-meetings.md`, brief §5.10.

## Scope
Mic capture, device enumeration/selection, system and per-app audio (Core Audio process taps, ScreenCaptureKit fallback), file decoding to 16 kHz mono Float32, level meters, echo handling, voice-processing toggle, silent-denial detection.

## AppCore dependencies
`AudioSource`, `AudioChunk` (16 kHz mono Float32), `AudioSourceTag`, `AudioSourceHealth`, `AudioDevice`, `AudioDeviceProviding`, `AudioFileDecoder`, `VoiceActivityDetector`, `PermissionsServicing`, `PermissionKind`, `CaptureSource`, `AppError`, `SettingsStore`.

## Design constraints
- Real-time callbacks never allocate or lock; hand off through a lock-free SPSC ring buffer to a consumer task that resamples/mixes and yields `AudioChunk`.
- Live streams are bounded (`bufferingNewest`); overflow drops oldest and logs a metric; capture never blocks.
- Global default input device plus per-feature overrides (Live, Meetings, Dictation) stored in `SettingsStore`.

## Acceptance criteria
| ID | Criterion | Test |
|---|---|---|
| AUD-AC-01 | WHEN the user starts mic capture THE SYSTEM SHALL deliver `AudioChunk`s at 16 kHz mono Float32 with monotonically increasing `startSeconds`. | integration |
| AUD-AC-02 | WHEN the selected input device is unplugged THE SYSTEM SHALL fall back to the system default input, emit `.deviceChanged`, and post a notification, without ending the session. | manual |
| AUD-AC-03 | WHEN the default input changes (hot-plug / route change) AND capture follows the default THE SYSTEM SHALL restart the engine within 1 s and resume chunks. | manual |
| AUD-AC-04 | WHEN a tap or mic source delivers only all-zero buffers for 3 s THE SYSTEM SHALL emit `.silent` and surface a "check permission" recovery action. | integration (mock) / manual |
| AUD-AC-05 | WHEN microphone permission is not determined THE SYSTEM SHALL request it only at first use of a mic feature, after an explanation. | UI / manual |
| AUD-AC-06 | WHEN microphone permission is denied THE SYSTEM SHALL throw `AppError.permissionDenied(.microphone)` and show a deep link to System Settings. | unit (mock) / UI |
| AUD-AC-07 | WHEN system or app audio is requested THE SYSTEM SHALL use a Core Audio process tap (bundle-ID targeted for Zoom `us.zoom.xos`, Teams `com.microsoft.teams2`) and fall back to ScreenCaptureKit audio if the tap cannot be created. | manual |
| AUD-AC-08 | WHEN an input level meter is shown THE SYSTEM SHALL update it at ≥ 15 Hz from `AudioSource.levels` without blocking the main actor. | integration / perf |
| AUD-AC-09 | WHEN a file is decoded THE SYSTEM SHALL stream chunks of the requested length with bounded memory (≤ 2 chunks buffered) for any AVFoundation-readable format. | integration |
| AUD-AC-10 | WHEN a file has no audio track THE SYSTEM SHALL throw `AppError.unsupportedFormat`. | unit |
| AUD-AC-11 | WHEN voice processing is enabled THE SYSTEM SHALL enable noise suppression/echo cancellation on the mic path only and persist the choice per feature. | manual |
| AUD-AC-12 | WHEN the mic and system audio are captured together AND the output device is not headphones THE SYSTEM SHALL show a one-time headphone hint. | UI |
| AUD-AC-13 | WHEN the default mic is a Bluetooth device in call (HFP) mode THE SYSTEM SHALL suggest the built-in mic. | manual |
| AUD-AC-14 | WHEN capture is stopped THE SYSTEM SHALL release all audio resources and finish all streams within 500 ms. | integration |
| AUD-AC-15 | WHEN a mic and a remote chunk are mixed THE SYSTEM SHALL align them by host time within 20 ms. | unit |

## Edge cases
Sample-rate changes mid-session; aggregate-device creation failure; app not running when a tap targets it (wait/retry); multiple Zoom helper processes; sleep/wake; mono vs stereo devices; output device switching while tapping.

## Non-functional
Capture overhead < 3 % CPU on M1; idle (not capturing) zero audio threads; no unbounded buffers.

## Unverified pending user run
Process-tap capture, TCC silent denial, hot-plug fallback, voice-processing quality, Bluetooth HFP behaviour, ScreenCaptureKit fallback (spike PoC only compile-checked). Teams capture cannot be tested (Teams not installed).
