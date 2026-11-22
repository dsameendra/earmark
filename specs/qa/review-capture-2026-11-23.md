# Capture / system domain review, 2026-11-23

Scope: everything since 84365c5 in Meetings, Permissions, AudioCapture, Dictation, LiveCaptions, App/, plus scripts/ release tooling.
Method: read the full diff and the surrounding code, then confirmed suspected bugs with a failing test where the code is testable.
The App target could not be built here (the shared build project points at the main checkout), so App changes were type-checked
in isolation only (see "Not verified").

## Fixed

| # | Severity | Finding | Fix | Test |
|---|----------|---------|-----|------|
| 1 | High | `ProcessNames.anyRunning` (Zoom `CptHost` call-helper signal) treated the return of `proc_listallpids` as a byte count. It is a pid count, so only the first quarter of the process table was scanned and recently spawned helpers (the ones that matter) were missed. The corroboration path for muted joins therefore mostly never fired. | Rewrote with `systemPIDs()` / `systemName()` and injectable seams. | `processNameLookupScansAllPids` (pid 1000 of 1000 found; verified on the real table that the count and the returned array agree: 775 / 756 / 755). |
| 2 | High | `MeetingSessionController.handle(.ended)` while `startSession` was suspended (start takes many awaits: recordings root, mic start, recorder start, live start). `active` was still nil so the end was dropped, and the session then started and recorded an ended meeting until the user noticed or quit. | Track `startingApp` / `endedWhileStarting`; after `sessionStarted` the controller stops the session immediately (finalization is queued as normal). | `endedWhileStarting` (fails with the fix disabled, passes with it). |
| 3 | Medium | Quitting during a meeting never called `MeetingSessionController.shutdown()` (nothing referenced it), so the recorder was killed mid-write, the live transcript was not saved and the meeting row had no end. Crash recovery repaired the files at next launch, but the transcript link and bookmarks were lost. | `applicationShouldTerminate` returns `.terminateLater` only while a meeting session exists, runs `shutdown()`, replies exactly once, with a 15 s cap so a stuck recorder cannot block quit. | App target; type-checked standalone with `-swift-version 6 -warnings-as-errors`. No unit test (AppKit delegate). |
| 4 | Medium | Re-prompt spam after "Ignore this meeting" / Dismiss. With the relaxed signals a listen-only call can fall silent past the 15 s end grace, emit `.ended`, then resume and emit `.started`; the model cleared the ignore on `.ended` and prompted again for the same call. | `MeetingsModel` keeps a 5 minute quiet period after a user-dismissed detection ends; a re-detection inside it is created already dismissed (no banner, no notification). A genuinely new meeting later still prompts. Never-ask-for-app (`doNothing`) is unaffected and already persisted. | `aCallDetectedAgainRightAfterBeingIgnoredDoesNotPromptAgain`; the existing "next meeting prompts again" test now uses a start time after the quiet period. |
| 5 | Low | Notification permission was requested at every launch before onboarding finished, so on first run the system dialog landed on top of the welcome flow. | Launch-time request only when `onboarding.completed` is true (the permissions step in onboarding asks; the prompter still asks lazily when a prompt is first needed). | App target. |
| 6 | Low | `release.sh` and `make-dmg.sh` tool check `command -v ... >/dev/null` under `set -e` exited silently with no message. | Names the missing tool, exit 69. | `bash -n`. |
| 7 | Low | `SystemMeetingPrompter.authorized()` did not treat `.ephemeral` as authorised while `SystemPermissionProbe` does. | Aligned. | n/a |

## Reviewed, no change needed (verified)

- Detector state machine: candidate to active to ending transitions are token-guarded and re-read the probe after each suspension; a
  pending start survives a gap shorter than `candidateGrace`; the candidate gives up after the last checkpoint (15 s) and reopens
  only on a probe change, so there is no timer churn when idle. Per-app identifiers use prefix + `.` for tap targets
  (`HAL.processObjects`), so Teams/Zoom helper processes are included in the tap.
- `MicrophonePreference`: override then global; empty string means system default; the stored UID is never erased; the fallback to the
  system default and return on reconnect live in `MicrophoneController.resolveTarget`/`reevaluate`. Meetings, Live and Dictation all go
  through it now.
- `PermissionsService`: `requestAgain` only re-prompts for Accessibility and Screen Recording after denial; for microphone,
  notifications and the audio tap it just re-reads. Microphone/notification "not determined" no longer degrades to "denied" through the
  requested-flag memory. `refresh()` on activation does not prompt (`rawState` is read-only; the tap preflight uses the TCC
  preflight, not a tap create). Overlapping refreshes are harmless.
- Dictation hotkey: release or Escape during the Accessibility check sets `stopRequestedWhileStarting`, handled once the check
  returns; the slot is claimed before the first suspension; a late `captureFailed` cannot leave `phase` wedged (flag is reset on the
  next begin).
- Privacy: no transcript text in logs (detector/prompter log app ids and booleans, privacy `.public` only for those). No network use
  outside ModelStore (`URLSession`) and Sparkle; `NWPathMonitor` in onboarding only reads path status.
- TCC strings and entitlements: `NSMicrophoneUsageDescription` and `NSAudioCaptureUsageDescription` present. Screen Recording,
  Accessibility, Input Monitoring and Notifications need no Info.plist string on macOS. No Apple Events, so no
  `NSAppleEventsUsageDescription` / automation entitlement is needed. `device.audio-input` is the only entitlement and is correct for
  the hardened-runtime distribution mode; the app is not sandboxed. The CGEvent tap uses `.listenOnly` without Accessibility and
  `.defaultTap` with it, matching the Input Monitoring / Accessibility split.
- SIGPIPE: the NLLB worker pipe sets `F_SETNOSIGPIPE` per descriptor (NLLB.swift).
- `AppEnvironment`: the activation observer and meeting tasks hold services, not `self`; no retain cycle found. Startup order is right
  (recovery completes before `detector.start()`).

## Open risks (not changed; need a product decision or a live call)

1. Medium: the output-plus-`deviceMicInUse` corroboration (5 s) is device-wide. When Zoom is running and producing any output
   (recording playback, a notification chime stream) while another app, including Earmark's own dictation or live captions, holds the
   default mic, a meeting is "detected". It is not the muted-join case it was added for (a muted Zoom does not make the device mic
   run). Consider dropping `deviceMicInUse` from `qualifies`, or requiring `helperPresent`. The helper names (`CptHost`, `caphost`)
   are still unverified against a live call (the code says so).
2. Medium: a meeting with transcription runs two voice-processing mic engines on the same device (recorder mic and the live mic
   lane) and the live system lane taps the whole system (`.system`), not the meeting app, so music or other apps are transcribed
   as "Them". `LiveSessionConfig` has no "mic + one app" source; adding one is the clean fix.
3. Low: `SystemAudioSource` waits up to `appWaitTimeout` for the app's audio process; a muted join may start remote capture late.
4. Low: `followActivation` registers a block observer that is never removed; harmless for the app lifetime but doubled after the
   library-recovery relaunch path (`environment = AppEnvironment()`).
5. Low: `stopSession` and a new `.started` for another app can interleave around `live.stop()` (only one `live` orchestrator).

## Release tooling under a self-signed identity

- `sign-bundle.py --self-signed` signs inside-out without hardened runtime and without a timestamp. That is deliberate and correct:
  hardened runtime enables library validation, which refuses to load Sparkle or the native helper unless they share the app's Team ID
  or are Apple-signed, and a self-signed certificate has no Team ID. Hardened runtime also buys nothing without notarization.
  Consequences to accept: Gatekeeper requires "Open Anyway" on first launch (already shown in the DMG artwork), the `device.audio-input`
  entitlement is harmless but inert, and `get-task-allow` is rejected by the script, so no debugger entitlement leaks.
- Distribution mode uses hardened runtime with the same identity on every nested binary, so library validation passes (same Team ID);
  no `disable-library-validation` entitlement is needed. Sparkle's XPC services keep their own entitlements through
  `--preserve-metadata=entitlements`.
- Designated requirement: codesign's default for a non-Apple-anchored certificate is `identifier "..." and certificate leaf =
  H"<sha1>"`. `verify-release.py` requires exactly that form (rejects `cdhash`) and requires the app and helper to pin the same leaf.
  TCC grants and Sparkle's same-publisher check therefore survive updates only while the same certificate is used. Losing the key
  breaks that continuity (documented in make-signing-identity.sh). Certificate expiry is 10 years; after that signing fails but
  installed copies keep working. Sparkle accepts updates by the EdDSA signature, which does not depend on the certificate.
- Keys: the signing key and EdDSA key stay in the login Keychain; the temporary PKCS#12 lives in a 0700 temp dir removed by a trap.
  The random export password is briefly visible in `security import -P` arguments to other local processes (no alternative exists in the
  tool); acceptable for a throwaway file but worth knowing. Nothing writes secrets into the repository; `verify-release.py` rejects
  key material inside the app.
- `make-appcast.sh`: `generate_appcast` with `EARMARK_PREVIOUS_APPCAST` keeps older items only if Sparkle's behaviour for archives
  missing from the staging directory retains them; this was not exercised here, so check the generated appcast lists prior versions.
- `security find-certificate -c NAME` in `verify-release.py` is a substring match; two certificates whose names contain the identity
  would make the self-signed check read the first one. Low risk with the single default name.
- DMG geometry (window 660x448 including the 28 pt title bar, icons at 180/480 x 190, icon size 112) is consistent across
  `settings.py`, `make-dmg.sh`, `verify-dmg.py` and `test_verification.py`.

## Not verified

- The App target was not built (disk and the shared generated project point at the main checkout). `EarmarkApp.swift`'s
  termination handler was compiled standalone under Swift 6 strict concurrency with warnings as errors; the AppEnvironment edit is a
  small closure over an actor. Build the app once before merging.
- Hardware paths (real Zoom/Teams call, helper names, voice processing with Zoom) were not exercised.
