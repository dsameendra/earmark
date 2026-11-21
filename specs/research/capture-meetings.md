# Spike: audio capture, meeting detection, recording (Phase 0)

Status: research + compile-checked PoCs. Date 2026-11-21. Machine: M3 Pro, macOS 27.2.1, Xcode 27.2, SDK MacOSX27.2, Swift 6.4.2.
PoC: `spikes/capture/` (SwiftPM, builds clean: `cd spikes/capture && swift build`). Run steps in section 9.

Evidence legend: **[HDR]** read from installed SDK 27.2 headers (primary source, accessed 2026-11-21) / **[RAN]** executed here, no permissions needed / **[DOC]** web source / **[UNVERIFIED]** needs user run (permission-gated) or recalled knowledge not confirmed here.
Note: developer.apple.com doc pages are JS-rendered and WebFetch returned only titles, so Apple doc claims are anchored to SDK headers instead of doc URLs.

## 1. Microphone (AVAudioEngine + Core Audio)

- Enumeration/default/hot-plug: `kAudioHardwarePropertyDevices`, `...DefaultInputDevice`, `kAudioDevicePropertyDeviceUID`, StreamConfiguration for channel counts. [RAN] `capture-spike devices` listed AirPods (in+out, Bluetooth), built-in mic/speakers, iPhone Continuity mic (transport 'ccwd'), and Zoom's virtual `ZoomAudioDevice` (transport 'virt', 2in/2out). Filter virtual devices (transport `kAudioDeviceTransportTypeVirtual`/aggregate) out of the user-facing mic picker, and always exclude our own private aggregate.
- Selecting a device without touching system default: set `kAudioOutputUnitProperty_CurrentDevice` on `engine.inputNode.audioUnit` before reading the format. Persist the device by UID, not AudioObjectID (IDs change across reboots/replug).
- Route change: handle `AVAudioEngineConfigurationChange` (engine stops itself; remove tap, rebuild engine, reinstall tap with the new format). Also listen to Core Audio default-input and device-list changes to update UI. Implemented in `Mic.swift`; behavior on actual hot-plug [UNVERIFIED].
- 16 kHz mono Float32: tap at the hardware format, then `AVAudioConverter` -> 16k/1ch/Float32 (do NOT request 16k in `installTap`; format mismatch throws). Converter runs inside the tap callback here for simplicity; production should move conversion off the audio thread (see ring buffer) to avoid allocation (`AVAudioPCMBuffer` allocation in the tap is not RT-safe).
- Ring buffer: `RingBuffer.swift` is a single-producer/single-consumer lock-free Float ring using `Synchronization.Atomic` (acquire/release). Producer = audio thread, never blocks, counts drops on overflow; consumer = ASR feeder queue. Production tweak: preallocate converter output and use `memcpy` / power-of-two mask instead of `%`.
- Bluetooth caveat: with AirPods as the default input, macOS switches the headset to HFP/SCO (low-bandwidth 16k mic, degraded output quality). Observed environment has AirPods as default in+out. Recommend defaulting the mic picker to the built-in mic when the default input is Bluetooth, and telling the user.
- Permission: `NSMicrophoneUsageDescription`, `AVCaptureDevice.requestAccess(for: .audio)`. Non-sandboxed + hardened runtime needs `com.apple.security.device.audio-input` entitlement in the signed binary [UNVERIFIED for 27, standard practice; the entitlement doc page could not be fetched, a search-engine summary said it governs mic access under both sandbox and hardened runtime].

## 2. App audio via Core Audio process taps

API facts [HDR: CATapDescription.h, AudioHardwareTapping.h, AudioHardware.h]:
- `AudioHardwareCreateProcessTap` / `...DestroyProcessTap` macOS 14.2+. `CATapDescription` inits: stereo/mono mixdown of processes, global-except, device-stream variants. Properties: `processes` (AudioObjectIDs), **`bundleIDs` (macOS 26+)**, `processRestoreEnabled` (**macOS 26+**: tap remembers bundle IDs and re-attaches when the app relaunches), `muteBehavior` (`CATapUnmuted/Muted/MutedWhenTapped`), `isPrivate`, `isMono`, `isExclusive`.
- Tap is consumed via an aggregate device: `kAudioAggregateDeviceTapListKey` ("taps"), `kAudioAggregateDeviceTapAutoStartKey`, sub-tap keys (`kAudioSubTapUIDKey`, `kAudioSubTapDriftCompensationKey`). Tap format via `kAudioTapPropertyFormat`.
- Process objects: `kAudioHardwarePropertyProcessObjectList`, `kAudioHardwarePropertyTranslatePIDToProcessObject`, per-process `kAudioProcessPropertyPID/BundleID/IsRunning/IsRunningInput/IsRunningOutput`.
- Implementation: `Tap.swift` (private tap, `.unmuted`, private aggregate, IOProc block, peak/zero counters). Compiles on SDK 27 with the Swift-refined init `CATapDescription(stereoMixdownOfProcesses:)`. Runtime behavior [UNVERIFIED pending user run].
- With macOS 26 `bundleIDs` + `processRestoreEnabled` the app can create the tap once at record start for `us.zoom.xos` even before Zoom's audio process object exists. The PoC uses `processes` (works on 14.2+); try the bundleIDs path in the user run as an enhancement (not coded).
- Targets: Zoom `us.zoom.xos` (confirmed bundle id [RAN: `defaults read`], v7.1.9 (88375), notarized Developer ID, Team BJ4HAAB9B3). Teams (new) `com.microsoft.teams2`: not installed here, so helper-process bundle IDs are [UNVERIFIED]; per-process objects are per-PID with their own bundle id (e.g. a Discord helper on this machine appeared as `com.hnc.Discord.helper.Renderer` [RAN]), so match by **prefix** (`com.microsoft.teams2*`) and tap all matching process objects, not just the main bundle. Same applies to Zoom (main app process `us.zoom.xos` is expected to own the call audio; helpers listed below are not).
- Mixdown choice: stereo mixdown of Zoom's processes = "remote" track (Zoom plays remote participants only; the local mic is not in Zoom's output, so the remote track contains no own-voice unless the user enables Zoom "mic monitoring"/sidetone [UNVERIFIED]).
- Muting: keep `.unmuted`. Never use `.muted` (would silence the meeting for the user).

### Permission / TCC
- Key: `NSAudioCaptureUsageDescription` (Info.plist). Zoom itself ships this key ("Please allow access in order to capture audio from other apps.") [RAN: Info.plist read]. Pane: System Settings > Privacy & Security > "Screen & System Audio Recording" (system-audio-only sub-list) [UNVERIFIED on 27 UI; established since 14.2].
- No public preflight/request API for system-audio recording TCC is in the headers I inspected [HDR: none found for audio taps]; the prompt appears on first tap start. Community notes mention private TCC SPI (`TCCAccessPreflight` for `kTCCServiceAudioCapture`) which should NOT be used in a shipped app. [UNVERIFIED]
- **Silent denial**: widely reported that, when permission is missing/denied, tap creation and IO still succeed but buffers are all zeros [UNVERIFIED pending user run; this is the behavior the PoC detects]. Detection recipe (implemented): count frames and peak in the IOProc; if after ~2-3 s of IO the app is known to be audibly playing (process `IsRunningOutput == true`) and peak == 0 for all frames, show "System audio permission missing" with a deep link to the privacy pane. All-zero can also mean the meeting is simply silent, so gate on `IsRunningOutput` and a duration.
- CLI-run PoC: TCC attributes the request to the *responsible process* (the terminal), so grant it to Terminal/iTerm; the embedded Info.plist (`__TEXT,__info_plist`) provides the purpose strings. Verified the section embeds [RAN: otool].

### ScreenCaptureKit fallback
- `SCStreamConfiguration.capturesAudio` + `excludesCurrentProcessAudio`; per-app filter `SCContentFilter(display:including:[SCRunningApplication],exceptingWindows:)`. Needs Screen Recording TCC (scarier prompt, periodic re-approval nag on 15+ [UNVERIFIED on 27]). SDK 27 adds `SCStreamOutputTypeMicrophone` (macOS 15+) so SCK could deliver mic+app audio from one stream; `SCRecordingOutputConfiguration.mixesAudioWithMicrophone` (**macOS 27 only**, default YES = mixed; NO keeps separate tracks) [HDR]. Since app targets 26, not usable unconditionally.
- Recommend: taps primary; SCK only as fallback if taps fail/denied. PoC `SCK.swift` compiles; runtime [UNVERIFIED].

## 3. Echo / duplication when mic hears the speakers
- With speakers (no headphones), the mic track will contain remote voices, so the same speech is transcribed twice (once per track, with different timing).
- Options:
  1. Headphone hint (`CA.outputLooksLikeHeadphones`: transport Bluetooth, or built-in output data source `'hdpn'`). [RAN] returned true with AirPods. Bluetooth speakers also match (hint only). If not headphones, warn and enable mitigation 2/3.
  2. Voice Processing IO on the mic engine: `engine.inputNode.setVoiceProcessingEnabled(true)` [HDR: AVAudioIONode.h]. It applies AEC against system playback (reference is the output device, so it also cancels audio produced by Zoom). Side effects (known behavior, [UNVERIFIED here]): ducks other audio (mitigate with `voiceProcessingOtherAudioDuckingConfiguration` min ducking, macOS 14+ [HDR]), can change input format/channel count, interacts with the Zoom call's own VPIO, BT -> HFP. Toggle in PoC via `EARMARK_VPIO=1`. Needs A/B listening test by user.
  3. Cross-track dedupe post-ASR: drop mic-track segments whose time range overlaps a remote segment and whose text is highly similar (or whose mic energy is mostly explained by the remote track). Cheap, no audio side effects; recommended as the default fallback. This is a diarization/pipeline item to hand to the ASR owner.
- Recommendation: do not enable VPIO by default; headphone detection + dedupe, VPIO as an opt-in "I use speakers" setting.

## 4. Meeting detection (Zoom / Teams)
Signals, ordered by usefulness:
1. **Process running** (`NSWorkspace.runningApplications`, bundle id). Necessary, hugely false-positive (Zoom is a menu-bar app that stays resident).
2. **Per-process audio objects**: the app's audio process has `IsRunningInput` (mic open) and `IsRunningOutput` (audio playing). Best single signal for "in a call": input && output on the app's own process(es). Readable without any TCC permission [RAN: `capture-spike detect` read process objects with no prompt; it correctly reported that Discord's renderer helper was the mic user]. Property listeners available on the process object list and per-process properties for event-driven updates (PoC `watch` uses list listener + 2 s poll; per-process listeners to add in implementation).
3. **`kAudioDevicePropertyDeviceIsRunningSomewhere`** on the input device: says "some app uses the mic", not which one. [RAN] it was true for the built-in mic during the run (another app). Use only as a corroborating signal; cross-reference with #2.
4. **Zoom helpers** (bundle inspected read-only [RAN]): `Contents/Frameworks/CptHost.app` (`us.zoom.CptHost`, LSUIElement, hardened runtime) and `caphost.app` (`us.zoom.caphost`) are screen-share/capture hosts, not call-audio processes (naming-based inference [UNVERIFIED]). They appear while sharing a screen, not for every call, so they are a weak/optional signal for "sharing", not for "in a meeting". Also `ZoomAudioDevice.driver` and `ParrotAudioPlugin.driver` in /Library/Audio/Plug-Ins/HAL are installed (virtual device `zoom.us.zoomaudiodevice.001` exists always; its `IsRunningSomewhere` could be a call signal [UNVERIFIED]).
5. **Window title via Accessibility** (optional): Zoom's in-meeting window is titled "Zoom Meeting"; Teams titles contain meeting names. Requires Accessibility TCC; localized and fragile. Recommend skipping for v1 (use only to name the recording, if at all). [UNVERIFIED]
6. Calendar-based hints (EventKit) are an option outside this spike.

False positives/negatives: Zoom resident + mic used by a different app (signal 3 alone fails); Zoom preview/test-audio dialog opens mic+speaker without a meeting; Zoom "Join audio by computer" off, or user muted (mic may stay open, but if Zoom releases the input when muted the input flag drops [UNVERIFIED]); listen-only/webinar attendee has output but no input -> use output-only with a longer debounce as a weak "meeting" signal; Teams new client runs audio in helper processes (prefix match). Debounce start by 3-5 s, end by 10-15 s.
Proposed rule: `inCall = anyProc(prefix).IsRunningInput && anyProc(prefix).IsRunningOutput`, sustained 3 s; offer (not auto-start) recording by notification; user setting for auto-start.

## 5. Recording
- `Writer.swift`: `AVAssetWriter` + AAC input (`expectsMediaDataInRealTime = true`), PCM Float32 -> `CMSampleBuffer` via `CMAudioSampleBufferCreateWithPacketDescriptions` + `CMSampleBufferSetDataBufferFromAudioBufferList`.
- Crash safety: `movieFragmentInterval` is documented as "for file types that support movie fragments... a partially written asset whose writing is interrupted can be opened and played up to multiples of the interval" [HDR: AVAssetWriter.h]. PoC writes MPEG-4 (`.mp4`, audio only) with 5 s fragments (header recommends >=10 s for external storage). Whether `.m4a` file type supports fragments is [UNVERIFIED]; pick `.mp4`/`.mov` container for the live files and optionally rewrap to `.m4a` at finalize. Kill -9 mid-record test is in the manual steps.
- Layout: two separate live tracks (mic.mp4, remote.mp4), each its own file so a failure in one doesn't lose the other and ASR gets clean per-speaker channels, plus `mix.m4a` produced after stop with `AVMutableComposition` + `AVAssetExportSession` (`mixTracks`). Real-time mix isn't required for v1.
- Sync: remote is on the tap/aggregate clock, mic on engine clock; both started within ms but with independent PTS counters in the PoC (gap-free; not host-time-aligned). Production should stamp each buffer with `mHostTime` (IOProc `inTime`; engine tap `AVAudioTime.hostTime`) and align/insert silence for drops. Marked as design need.
- Video (optional): `SCStream` + `SCRecordingOutput` (macOS 15+) records H.264 (default) / HEVC straight to a file [HDR: SCRecordingOutput.h: `videoCodecType`, `outputFileType` default MPEG-4], avoiding a hand-rolled writer. Needs Screen Recording TCC. Not prototyped. Recommend video out of v1 scope.
- Encoding: AAC 64 kbps mono for mic, 96-128 kbps stereo for remote is a sensible default for speech [design suggestion, untested]. Also keep a 16 kHz float WAV/CAF scratch copy only if the ASR owner needs lossless re-processing.

## 6. Global hotkeys, CGEvent text insertion, Accessibility; sandbox evidence
- Global hotkey: Carbon `RegisterEventHotKey` (no permission, works sandboxed) or `CGEventTap`/NSEvent global monitor (Input Monitoring / Accessibility). Recommend Carbon hotkeys or the `KeyboardShortcuts` package for start/stop.
- Text insertion into other apps: `CGEvent.post` (needs "Post Event"/Accessibility trust) or AX `kAXSelectedTextAttribute` set (Accessibility). Reading focused element/window titles = Accessibility.
- Sandbox evidence [DOC, Apple Developer Forums via search 2026-11-21; threads: developer.apple.com/forums/thread/810677, /789896, /749494, /820594, /28605]: Apple DTS state it "is not possible for a sandboxed app to use the Accessibility privilege", even when the user grants it manually; AXIsProcessTrusted stays false and the app can't be added in the Accessibility list. `CGEventPost` reports are mixed; one clipboard manager was rejected from the Mac App Store under Guideline 2.4.5 for `CGEvent.post`. I could not retrieve the thread bodies, only search summaries, so treat the details as secondary.
- Sparkle: its official sandbox docs [DOC: https://sparkle-project.org/documentation/sandboxing/, accessed 2026-11-21] confirm Sparkle 2 works in a sandbox only via the Installer XPC service + mach-lookup temporary exception, which the Mac App Store does not allow; independent of that, update-by-Sparkle implies direct distribution.
- Process taps in a sandbox: Zoom's Info.plist shows the key; no sandbox entitlement for tapping other processes is present in the SDK headers I inspected [HDR: none]. App Store viability of taps is [UNVERIFIED].
- Conclusion: the combination (Accessibility/CGEvent text insertion into other apps + Sparkle + system audio taps of other apps) means **non-sandboxed, Developer ID signed, hardened runtime, notarized, Sparkle-updated direct distribution**. Needed entitlements/keys (non-sandboxed): `com.apple.security.device.audio-input`, plus Info.plist `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, (`NSScreenCaptureDescription` only if SCK used). Accessibility/Input Monitoring are TCC grants, not entitlements.

## 7. Installed-app read-only inspection summary [RAN]
zoom.us.app: id `us.zoom.xos`, v7.1.9, `LSMinimumSystemVersion` 11.0, notarized Developer ID, hardened runtime, has `NSAudioCaptureUsageDescription`, `NSMicrophoneUsageDescription`, Info.plist `NSAppleEventsUsageDescription`. Helpers: `CptHost.app` (`us.zoom.CptHost`, LSUIElement), `caphost.app` (`us.zoom.caphost`), `airhost.app`, `aomhost.app`, `Transcode.app`. Zoom was NOT running during inspection (no live-call signals could be observed), so all call-time property values are [UNVERIFIED pending user run]. Teams not installed.

## 8. Differences macOS 26 vs SDK 27 noted
- Taps: `bundleIDs`/`processRestoreEnabled` need macOS 26 (OK at the deployment floor). Header copyright still 2014-2022 (API stable).
- SCK: `mixesAudioWithMicrophone` is macOS 27 only; gate with `#available`.
- `SPM .macOS(.v26)` is not available in tools-version 6.0 manifests; used `.macOS("26.0")`.

## 9. Manual run steps (UNVERIFIED pending user run)
Build: `cd spikes/capture && swift build`; binary `.build/debug/capture-spike`. Run from Terminal (TCC attributes to Terminal).
1. No-permission: `capture-spike devices`, `capture-spike detect` (already run by me).
2. Mic: `capture-spike mic 8` -> grant Microphone to Terminal; speak; expect `rms` > 0.01. Try `capture-spike mic 20 <uid>` and unplug/plug AirPods or change Sound input mid-run: expect "[mic] AVAudioEngineConfigurationChange -> restarting" and samples to continue. `EARMARK_VPIO=1 capture-spike mic 8` to compare.
3. Detection: start `capture-spike watch 300`, then join a Zoom test meeting (zoom.us/test); expect Zoom audio processes with in/out flags flipping. Record the observed bundle IDs of Zoom's audio processes (confirm `us.zoom.xos` vs helpers) and what happens on mute, leave, and on the Zoom audio-test dialog.
4. Tap, permission denied: while Zoom test meeting plays sound, run `capture-spike tap zoom 10` BEFORE granting System Audio Recording permission (reset with `tccutil reset AudioCapture` if needed... service name [UNVERIFIED]; otherwise remove Terminal in the Settings pane). Expect either the prompt or VERDICT all-zero.
5. Tap, granted: grant, rerun, expect `peak` > 0 and VERDICT audio captured. Also verify Zoom volume unaffected (we use `.unmuted`).
6. SCK fallback: `capture-spike sck zoom 10` (Screen Recording permission), compare peak.
7. Record: `capture-spike record zoom 20 /tmp/out` then play `mic.mp4`, `remote.mp4`, `mix.m4a`; check duration/AV sync drift. Crash test: start record, `kill -9` the process after 12 s, open mic.mp4 in QuickTime: expect playable up to ~last fragment.
8. Echo: join test meeting on speakers (not headphones) and run `record`; inspect whether remote voices appear in mic.mp4; repeat with `EARMARK_VPIO=1` (note: VPIO is wired only in the `mic` path of MicCapture, which `record` uses too).

## Recommendation
- Architecture: Core Audio process taps (per-app, `.unmuted`, private) for remote audio; AVAudioEngine for mic; SCK audio only as fallback. Two files per session (mic, remote) + post-hoc m4a mix; fragmented MPEG-4 for crash safety. SPSC ring from audio threads to a 16 kHz mono Float32 feeder for ASR. Detection by per-process audio flags (input && output) with debounce; offer-to-record rather than silent auto-record. Skip Accessibility window titles and video in v1. Default: headphone hint + cross-track dedupe; VPIO opt-in. Ship non-sandboxed Developer ID + notarized + Sparkle.
- Before locking: user must run steps 3-5 and 7 (the whole tap path and silent-denial claim are unverified).

## Routing-table rows
| Concern | Decision / owner | Evidence |
|---|---|---|
| Remote/app audio capture | Core Audio process tap (macOS 26 `bundleIDs`), SCK fallback | HDR; run pending |
| Mic capture | AVAudioEngine + Core Audio device UID selection, 16k mono Float32 via ring buffer | HDR; run pending |
| Meeting detection | Process audio flags in && out, debounced; no AX in v1 | RAN (partial) |
| Echo | Headphone hint + cross-track text dedupe (ASR/diarization owner); VPIO opt-in | Partly UNVERIFIED |
| Recording | AVAssetWriter fragmented mp4 per track + m4a mix | HDR; kill test pending |
| Video | Out of v1; SCRecordingOutput if added | HDR |
| Distribution | Non-sandboxed Developer ID + notarization + Sparkle | DOC (forums, Sparkle) |

## Sandbox/distribution flags
- App Sandbox: incompatible with Accessibility-based text insertion (Apple DTS, forums), with Sparkle without temporary-exception entitlements, and App Store review risk for CGEvent posting and process taps. Mac App Store is out.
- Required: hardened runtime, notarization, `device.audio-input` entitlement, Info.plist usage strings (mic, audio capture), TCC grants (Mic, System Audio Recording, optional Accessibility/Input Monitoring/Screen Recording).
- Debug/dev: TCC attribution differs for CLI vs signed app; re-test with the signed app bundle (stable identity avoids repeated prompts).

## Open questions for the user
1. Do you accept non-sandboxed direct distribution (no Mac App Store)? This spike assumes yes.
2. Can you run the manual steps (mic, Zoom test meeting tap, denial test, kill -9 test) and report outputs? They gate every "UNVERIFIED" item.
3. Do you use speakers or headphones in meetings (AirPods is your current default in/out)? Affects echo default and the Bluetooth/HFP guidance.
4. Auto-start recording when a meeting is detected, or always ask first?
5. Is Teams support needed in v1 (it is not installed here, so its helper bundle IDs cannot be inspected)? Other apps (Meet in browser, Slack huddles, FaceTime)?
6. Is video/screen recording in scope, or audio only?
7. Is Accessibility (window titles, text insertion into other apps) wanted in v1, given the extra permission prompt?
